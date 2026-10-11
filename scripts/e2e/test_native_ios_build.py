"""Original private files; model Xcode/Flutter transport and signed captures."""
from pathlib import Path
import contextlib
import json
import os
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_runtime as runtime
import native_ios_build as BUILD
from native_case_lifecycle import NativeCaseLifecycle
from native_workspace import prepare_native_case_workspace
from test_native_macos_build import CHECKOUT, covered, dart_import_closure


class BuildTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="ios-build-model-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.source = self.root/"source"
        self.source.mkdir(mode=0o700)
        for name in ("lib/app.dart", "ios/Runner.xcodeproj/project.pbxproj",
                     "test/support/legacy_payment_link.dart", ".dart_tool/package_config.json", "bin/flutter"):
            path = self.source/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("model source")
            path.chmod(0o700)
        self.case = NativeCaseLifecycle(prepare_native_case_workspace(self.root,
            platform="ios", scenario_id="flutter.ios.native-build", run_id="abcdef0123",
            worker_id=0, case_index=0, ports={"rpc":28232,"lwd":29067,"proxy":29068}, activation_height=1))
        self.commands = []
        self.change_source = False
        self.change_test_support = False
        self.installed_targets = {"aarch64-apple-ios-sim"}
        self.installed_toolchains = {"stable"}
        self.installed_components = set()
        self.configured_toolchain = "stable"
        self.leases, self.published, self.entry_state = [], set(), None

    def model_inputs(self, *args, **kwargs):
        """Model collector: Pod sandbox presence plus one checked wallet source."""
        return {"pods":(self.source/"ios/Pods").is_dir(), "app":(self.source/"lib/app.dart").read_text()}

    @contextlib.contextmanager
    def modeled_cache(self, *published):
        test = self
        test.published.update(json.dumps(item, sort_keys=True) for item in published)
        class Lease:
            def __init__(self, root, inputs, **options):
                test.assertEqual(options["roles"], ("cohort",))
                self.root, self.inputs, self.exited = root, inputs, False
                self.key = str(len(test.leases)).rjust(64, "0")
                test.leases.append(self)
            def __enter__(self):
                return self
            def __exit__(self, *_):
                self.exited = True
            def load(self):
                if test.entry_state == "corrupt":
                    raise BUILD.cache.NativeBuildCacheError("native cache attachment/inventory changed")
                if json.dumps(self.inputs, sort_keys=True) not in test.published:
                    return None
                return {"cohort":self.root/"cohort.app"}
            def materialize(self, case, paths):
                if test.entry_state == "changed-during-reuse":
                    (test.source/"lib/app.dart").write_text("changed while copying")
                return {role:case.workspace.root/"native-publication"/(role+".app") for role in paths}
            def publish(self, producer):
                test.published.add(json.dumps(self.inputs, sort_keys=True))
        with patch.object(BUILD.cache, "collect_native_cache_inputs", side_effect=self.model_inputs) as collect, \
             patch.object(BUILD.cache, "NativeCohortCacheLease", Lease), \
             patch.object(BUILD.cache, "ProducedNativeCohort", lambda case, captured, inputs, token: inputs):
            yield collect

    def configurations(self):
        return [args for args in self.commands if "--config-only" in args]

    def app_builds(self):
        return [args for args in self.commands if "/usr/bin/xcodebuild" in args]

    def command(self, arguments, **kwargs):
        self.commands.append(arguments)
        if "--config-only" in arguments:
            self.assertTrue(all(lease.exited for lease in self.leases), "a key lease is held during configuration")
        actual = arguments[4:] if arguments[0] == sys.executable else arguments
        if len(actual) == 4 and Path(actual[2]).name == "cargokit_toolchain.dart":
            return runtime.CommandResult(0,('{"toolchain":"'+self.configured_toolchain+'"}\n',))
        if actual[:3] == ["rustup", "toolchain", "list"]:
            return runtime.CommandResult(0,tuple(name+"\n" for name in sorted(self.installed_toolchains)))
        if actual[:3] == ["rustup", "toolchain", "install"]:
            self.installed_toolchains.add(actual[-1])
        if actual[:3] == ["rustup", "component", "list"]:
            return runtime.CommandResult(0,tuple(name+"\n" for name in sorted(self.installed_components)))
        if actual[:3] == ["rustup", "component", "add"]:
            self.installed_components.add(actual[3])
        if actual[:3] == ["rustup", "target", "list"]:
            if actual[-1] not in self.installed_toolchains:
                return runtime.CommandResult(1,("selected toolchain is not installed\n",))
            return runtime.CommandResult(0,tuple(name+"\n" for name in sorted(self.installed_targets)))
        if actual[:3] == ["rustup", "target", "add"]:
            self.installed_targets.add(actual[-1])
        if "ls-files" in arguments:
            requested = arguments[arguments.index("--")+1:]
            files = ("lib/app.dart", "ios/Runner.xcodeproj/project.pbxproj", "test/support/legacy_payment_link.dart")
            return runtime.CommandResult(0,("\0".join(name for name in files if covered(name, requested))+"\0",))
        if "--config-only" in arguments:
            (self.source/"ios/Pods").mkdir(exist_ok=True)
            project = self.source/"ios/Runner.xcodeproj/project.pbxproj"
            stamp = project.stat().st_mtime_ns + 1_000_000
            os.utime(project, ns=(stamp,stamp))
            if self.change_source:
                (self.source/"lib/app.dart").write_text("changed")
            if self.change_test_support:
                (self.source/"test/support/legacy_payment_link.dart").write_text("changed imported test support")
        return runtime.CommandResult(0,())

    def build(self, **options):
        captured = SimpleNamespace(architecture="arm64",verify_unchanged=lambda:None)
        with patch.object(self.case,"run_command",side_effect=self.command), \
             patch.object(BUILD.platform,"machine",return_value="arm64"), \
             patch.object(BUILD,"capture_ios_cohort",return_value=captured) as capture:
            self.capture = capture
            return BUILD.build_native_ios_cohort(self.case, source_root=self.source, flutter=self.source/"bin/flutter", **options)

    def test_checkout_lock_covers_preparation_and_releases_after_failure(self):
        self.change_source = True
        original = self.command
        def command(arguments, **options):
            if "--config-only" in arguments:
                with self.assertRaisesRegex(BUILD.cache.FunderCacheError,"deadline"):
                    with BUILD.cache.NativeCheckoutBuildLease(self.source,
                            timeout=0.05,cancel_event=threading.Event()):
                        pass
            return original(arguments, **options)
        with patch.object(self,"command",side_effect=command), self.modeled_cache():
            with self.assertRaisesRegex(BUILD.NativeIosBuildError,"lib/app.dart"):
                self.build(cache_root=self.root/"cache")
        with BUILD.cache.NativeCheckoutBuildLease(self.source,
                timeout=0.1,cancel_event=threading.Event()):
            pass

    def test_unproven_join_retains_the_checkout_without_authorizing_next_build(self):
        self.change_source = True
        with patch.object(self.case,"close",side_effect=RuntimeError("unproven original join")), \
             self.modeled_cache():
            with self.assertRaisesRegex(BUILD.NativeIosBuildError,"lib/app.dart"):
                self.build(cache_root=self.root/"cache")
        with self.assertRaisesRegex(BUILD.cache.NativeBuildCacheError,"unjoined retained"):
            with BUILD.cache.NativeCheckoutBuildLease(self.source,
                    timeout=0.1,cancel_event=threading.Event()):
                pass
        self.case.close()

    def test_pods_are_prepared_without_app_compilation_only_after_an_early_miss(self):
        def inputs(*args, **kwargs):
            configured = bool(self.configurations())
            self.assertEqual((self.source/"ios/Pods").is_dir(), configured)
            self.assertFalse(any("add" in args for args in self.commands))
            self.assertFalse(any("install" in args for args in self.commands))
            self.assertFalse(any("xcodebuild" in args for args in self.commands))
            if configured:
                raise RuntimeError("cache lookup boundary")
            return self.model_inputs()
        with self.modeled_cache(), patch.object(BUILD.cache, "collect_native_cache_inputs", side_effect=inputs):
            with self.assertRaisesRegex(RuntimeError, "cache lookup boundary"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual(len(self.configurations()), 1)
        self.assertTrue(self.leases[0].exited)

    def test_early_hit_skips_configuration_and_checkout_writes(self):
        project = self.source/"ios/Runner.xcodeproj/project.pbxproj"
        stamp = project.stat().st_mtime_ns
        with self.modeled_cache({"pods":False, "app":"model source"}) as collect:
            _, proof = self.build(cache_root=self.root/"cache")
        self.assertEqual((self.configurations(), self.app_builds()), ([], []))
        self.assertFalse((self.source/"ios/Pods").exists())
        self.assertEqual(project.stat().st_mtime_ns, stamp)
        self.assertEqual((proof["cache_hit"], proof["ios_app_build_count"], proof["early_lookup"]), (True, 0, "hit"))
        self.capture.assert_called_once_with(self.case.workspace.root/"native-publication/cohort.app")
        self.assertEqual(collect.call_count, 2)  # The early lookup and the recheck after copying.

    def test_early_miss_configures_once_then_reuses_the_configured_entry(self):
        with self.modeled_cache({"pods":True, "app":"model source"}) as collect:
            _, proof = self.build(cache_root=self.root/"cache")
        self.assertEqual((len(self.configurations()), self.app_builds()), (1, []))
        self.assertTrue(self.leases[0].exited)
        self.assertEqual([lease.inputs["pods"] for lease in self.leases], [False, True])
        self.assertEqual((proof["cache_hit"], proof["early_lookup"], proof["early_lookup_changed_inputs"]),
                         (True, "miss", ["pods"]))
        self.assertEqual(collect.call_count, 3)  # Early, configured and the recheck after copying.

    def test_cache_miss_configures_once_before_one_simulator_build(self):
        with self.modeled_cache():
            _, proof = self.build(cache_root=self.root/"cache")
        self.assertEqual((len(self.configurations()), len(self.app_builds())), (1, 1))
        self.assertLess(self.commands.index(self.configurations()[0]), self.commands.index(self.app_builds()[0]))
        self.assertEqual(self.published, {json.dumps({"app":"model source", "pods":True}, sort_keys=True)})
        self.assertEqual((proof["cache_hit"], proof["ios_app_build_count"], proof["early_lookup"]), (False, 1, "miss"))

    def test_missing_pre_configuration_state_falls_back_to_configuration(self):
        def inputs(*args, **kwargs):
            if not (self.source/"ios/Pods").is_dir():
                raise FileNotFoundError("bin/cache/artifacts/engine/ios")
            return self.model_inputs()
        with self.modeled_cache({"pods":True, "app":"model source"}), \
             patch.object(BUILD.cache, "collect_native_cache_inputs", side_effect=inputs):
            _, proof = self.build(cache_root=self.root/"cache")
        self.assertEqual(len(self.configurations()), 1)
        self.assertEqual((proof["cache_hit"], proof["early_lookup"], proof["early_lookup_error"]),
                         (True, "unavailable", "FileNotFoundError"))

    def test_unparsable_first_flutter_output_falls_back_to_configuration(self):
        # A Flutter that bootstraps on its first command prints progress before
        # its --version JSON; configuration used to absorb that first run.
        def inputs(*args, **kwargs):
            if not self.configurations():
                raise json.JSONDecodeError("Expecting value", "Building flutter tool...", 0)
            return self.model_inputs()
        with self.modeled_cache({"pods":True, "app":"model source"}), \
             patch.object(BUILD.cache, "collect_native_cache_inputs", side_effect=inputs):
            _, proof = self.build(cache_root=self.root/"cache")
        self.assertEqual((len(self.configurations()), self.app_builds()), (1, []))
        self.assertEqual((proof["cache_hit"], proof["early_lookup"], proof["early_lookup_error"]),
                         (True, "unavailable", "JSONDecodeError"))

    def test_early_lookup_does_not_mask_cancellation(self):
        with self.modeled_cache(), patch.object(BUILD.cache, "collect_native_cache_inputs",
                                                side_effect=runtime.Cancelled()):
            with self.assertRaises(runtime.Cancelled):
                self.build(cache_root=self.root/"cache")
        self.assertEqual(self.configurations(), [])

    def test_collector_command_failure_after_configuration_fails_the_producer(self):
        failure = BUILD.NativeIosBuildError("original iOS build failed; retain logs", 1)
        with self.modeled_cache(), \
             patch.object(BUILD.cache, "collect_native_cache_inputs", side_effect=failure) as collect:
            with self.assertRaisesRegex(BUILD.NativeIosBuildError, "retain logs"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual((len(self.configurations()), collect.call_count, self.leases), (1, 2, []))

    def test_unprotected_input_after_configuration_fails_the_producer(self):
        failure = BUILD.cache.NativeBuildCacheError("native tool input is not a protected bounded file: /model")
        with self.modeled_cache(), \
             patch.object(BUILD.cache, "collect_native_cache_inputs", side_effect=failure) as collect:
            with self.assertRaisesRegex(BUILD.cache.NativeBuildCacheError, "protected bounded file"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual((len(self.configurations()), collect.call_count, self.leases), (1, 2, []))

    def test_corrupt_early_entry_fails_without_configuration_or_rebuild(self):
        self.entry_state = "corrupt"
        with self.modeled_cache():
            with self.assertRaisesRegex(BUILD.cache.NativeBuildCacheError, "inventory changed"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual((self.configurations(), self.app_builds()), ([], []))

    def test_early_hit_rejects_wallet_source_changed_during_reuse(self):
        self.entry_state = "changed-during-reuse"
        with self.modeled_cache({"pods":False, "app":"model source"}):
            with self.assertRaisesRegex(BUILD.NativeIosBuildError, "changed during cache publication"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual(self.configurations(), [])

    def test_imported_test_support_is_in_cache_input_inventory(self):
        def inputs(root, source, *args, **kwargs):
            self.assertIn(self.source/"test/support/legacy_payment_link.dart", source)
            raise RuntimeError("cache lookup boundary")
        with patch.object(BUILD.cache,"collect_native_cache_inputs",side_effect=inputs):
            with self.assertRaisesRegex(RuntimeError,"cache lookup boundary"):
                self.build(cache_root=self.root/"cache")

    def test_preparation_test_support_changes_are_rejected_before_configured_lookup(self):
        self.change_test_support = True
        with self.modeled_cache() as inputs:
            with self.assertRaisesRegex(BUILD.NativeIosBuildError,"legacy_payment_link.dart"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual(inputs.call_count, 1)  # The early lookup only.

    def test_missing_simulator_rust_target_is_prepared_before_input_snapshot(self):
        self.installed_targets.clear()
        def inputs(*args, **kwargs):
            self.assertIn("aarch64-apple-ios-sim", self.installed_targets)
            additions = [args[4:] for args in self.commands if "add" in args]
            self.assertEqual(additions, [["rustup", "target", "add", "--toolchain", "stable", "aarch64-apple-ios-sim"]])
            self.assertFalse(any("xcodebuild" in args for args in self.commands))
            raise RuntimeError("prepared cache lookup boundary")
        with patch.object(BUILD.cache,"collect_native_cache_inputs",side_effect=inputs):
            with self.assertRaisesRegex(RuntimeError,"prepared cache lookup boundary"):
                self.build(cache_root=self.root/"cache")

    def test_missing_stable_toolchain_is_installed_before_target_query(self):
        self._assert_missing_toolchain_preparation("")

    def test_missing_exact_override_toolchain_is_installed_before_target_query(self):
        self._assert_missing_toolchain_preparation("1.96.0")

    def _assert_missing_toolchain_preparation(self, override):
        self.installed_targets.clear()
        self.installed_toolchains.clear()
        name = override or "stable"
        def inputs(*args, **kwargs):
            self.assertIn(name,self.installed_toolchains)
            self.assertIn("aarch64-apple-ios-sim",self.installed_targets)
            operations = [args[4:] for args in self.commands if "rustup" in args]
            install = operations.index(["rustup","toolchain","install",name])
            target_query = operations.index(["rustup","target","list","--installed","--toolchain",name])
            self.assertLess(install,target_query)
            self.assertFalse(any("xcodebuild" in args for args in self.commands))
            raise RuntimeError("prepared cache lookup boundary")
        with patch.dict(os.environ,{"VIZOR_RUST_TOOLCHAIN":override}), patch.object(
                BUILD.cache,"collect_native_cache_inputs",side_effect=inputs):
            with self.assertRaisesRegex(RuntimeError,"prepared cache lookup boundary"):
                self.build(cache_root=self.root/"cache")

    def test_missing_configured_beta_is_prepared_before_input_snapshot(self):
        self._assert_configured_channel_preparation("beta")

    def test_missing_configured_nightly_and_source_are_prepared_before_input_snapshot(self):
        self._assert_configured_channel_preparation("nightly")

    def test_prepared_nightly_is_not_reinstalled_or_updated(self):
        self.configured_toolchain = "nightly"
        (self.source/"rust").mkdir()
        (self.source/"rust/cargokit.yaml").write_text("cargo: {debug: {toolchain: nightly}}")
        self.installed_toolchains = {"nightly"}
        self.installed_components = {"rust-src"}
        def inputs(*args, **kwargs):
            self.assertFalse(any("install" in args or "add" in args for args in self.commands))
            raise RuntimeError("prepared nightly lookup boundary")
        with patch.dict(os.environ,{"VIZOR_RUST_TOOLCHAIN":""}), patch.object(
                BUILD.cache,"collect_native_cache_inputs",side_effect=inputs):
            with self.assertRaisesRegex(RuntimeError,"prepared nightly lookup boundary"):
                self.build(cache_root=self.root/"cache")

    def _assert_configured_channel_preparation(self, channel):
        self.configured_toolchain = channel
        (self.source/"rust").mkdir()
        (self.source/"rust/cargokit.yaml").write_text("cargo: {debug: {toolchain: "+channel+"}}")
        self.installed_toolchains.clear()
        self.installed_targets.clear()
        def inputs(*args, **kwargs):
            self.assertIn(channel, self.installed_toolchains)
            self.assertIn("aarch64-apple-ios-sim", self.installed_targets)
            operations = [args[4:] for args in self.commands if "rustup" in args]
            install = operations.index(["rustup", "toolchain", "install", channel])
            target_query = operations.index(["rustup", "target", "list", "--installed", "--toolchain", channel])
            self.assertLess(install, target_query)
            self.assertNotIn("stable", self.installed_toolchains)
            if channel == "nightly":
                self.assertIn("rust-src", self.installed_components)
            self.assertFalse(any("xcodebuild" in args for args in self.commands))
            raise RuntimeError("configured cache lookup boundary")
        with patch.dict(os.environ,{"VIZOR_RUST_TOOLCHAIN":""}), patch.object(
                BUILD.cache,"collect_native_cache_inputs",side_effect=inputs):
            with self.assertRaisesRegex(RuntimeError,"configured cache lookup boundary"):
                self.build(cache_root=self.root/"cache")

    def test_preparation_source_changes_are_rejected_before_configured_lookup(self):
        self.change_source = True
        with self.modeled_cache() as inputs:
            with self.assertRaisesRegex(BUILD.NativeIosBuildError, "lib/app.dart"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual(inputs.call_count, 1)  # The early lookup only.

    def test_one_mobile_regtest_cohort_build_without_a_helper(self):
        _, proof = self.build()
        self.assertEqual(set(proof), {"ios_app_build_count", "cache_hit", "cache_key", "architecture",
            "joined_build_processes", "exit_codes", "checked_source_files_sha256",
            "persistent_cache_attestation", "wallet_or_catalog_pass"})
        self.assertEqual(proof["ios_app_build_count"], 1)
        self.assertEqual(proof["architecture"], "arm64")
        self.assertFalse(proof["wallet_or_catalog_pass"])
        configure = next(args for args in self.commands if "--config-only" in args)
        for flag in ("--simulator", "--debug", "--dart-define=VIZOR_FORM_FACTOR=mobile",
                     "--dart-define=VIZOR_E2E_IOS_COHORT=true", "--dart-define=VIZOR_PAYMENT_LINK_REGTEST_ENABLED=true"):
            self.assertEqual(configure.count(flag), 1)
        builds = [args for args in self.commands if "/usr/bin/xcodebuild" in args]
        self.assertEqual(len(builds), 1)
        self.assertIn("Runner", builds[0])
        self.assertIn("ENABLE_DEBUG_DYLIB=NO", builds[0])
        self.assertIn(str(self.case.workspace.root/"ios-build"), builds[0])
        self.assertFalse(any(word in item for args in self.commands for item in args
                             for word in ("native-cleanup", "DEVELOPMENT_TEAM")))
        self.capture.assert_called_once_with(
            self.case.workspace.root/"ios-build/Build/Products/Debug-iphonesimulator/Runner.app")

    def test_source_inventory_has_no_harness_helper_or_plist_stamp_inputs(self):
        self.build()
        listing = next(args for args in self.commands if "ls-files" in args)
        requested = listing[listing.index("--")+1:]
        self.assertEqual(requested, ["lib", "integration_test", "test/support", "rust", "rust_builder", "ios",
                                     "assets", "third_party", "pubspec.yaml", "pubspec.lock", ".fvmrc"])

    def test_source_inventory_covers_every_file_the_actual_cohort_target_imports(self):
        self.build()
        listing = next(args for args in self.commands if "ls-files" in args)
        requested = listing[listing.index("--")+1:]
        configure = next(args for args in self.commands if "--target" in args)
        closure = dart_import_closure(CHECKOUT, configure[configure.index("--target")+1])
        self.assertIn("integration_test/support/mobile_regtest_flow.dart", closure)
        self.assertEqual(sorted(path for path in closure if not covered(path, requested)), [])
        self.assertEqual(sorted(path for path in closure if path.startswith("test/")
                                and not path.startswith("test/support/")), [])

    def test_cache_hit_captures_only_the_cohort_copy(self):
        leases = []
        class Lease:
            key = "c"*64
            def __init__(self, root, inputs, **options):
                self.root, self.options = root, options
                leases.append(self)
            def __enter__(self):
                return self
            def __exit__(self, *_):
                pass
            def load(self):
                return {role: self.root/(role+".app") for role in self.options["roles"]}
            def materialize(self, case, paths):
                return {role: case.workspace.root/"native-publication"/(role+".app") for role in paths}
        with patch.object(BUILD.cache, "collect_native_cache_inputs", return_value={"model":"inputs"}), \
             patch.object(BUILD.cache, "NativeCohortCacheLease", Lease):
            _, proof = self.build(cache_root=self.root/"cache")
        self.assertEqual([lease.options["roles"] for lease in leases], [("cohort",)])
        self.capture.assert_called_once_with(self.case.workspace.root/"native-publication/cohort.app")
        self.assertEqual((proof["ios_app_build_count"], proof["cache_hit"], proof["cache_key"]), (0, True, "c"*64))
        self.assertEqual(set(proof), {"ios_app_build_count", "cache_hit", "cache_key", "architecture",
            "joined_build_processes", "exit_codes", "persistent_cache_attestation", "wallet_or_catalog_pass",
            "early_lookup"})
        self.assertEqual(proof["early_lookup"], "hit")
        self.assertFalse(any("/usr/bin/xcodebuild" in args or "--config-only" in args for args in self.commands))

    def test_changed_wallet_input_does_not_publish_a_pair(self):
        self.change_source = True
        with self.assertRaisesRegex(BUILD.NativeIosBuildError,"lib/app.dart"):
            self.build()


if __name__ == "__main__":
    unittest.main()
