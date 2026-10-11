"""Real private source files; modeled SDK commands/signatures/native artifacts."""
from pathlib import Path
import contextlib
import json
import os
import posixpath
import re
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_runtime as runtime
import native_macos_build as BUILD
from native_case_lifecycle import NativeCaseLifecycle
from native_workspace import prepare_native_case_workspace

CHECKOUT = Path(__file__).resolve().parents[2]
_DIRECTIVE = re.compile(r"""^\s*(?:import|export|part)\s+(['"])([^'"]+)\1((?:\s+if\s*\([^)]*\)\s*(['"])[^'"]+\4)*)""",
                        re.M)


def covered(name, pathspec):
    """Git directory pathspec semantics for the modeled ls-files listing."""
    return any(name == path or name.startswith(path+"/") for path in pathspec)


def dart_import_closure(root, entry):
    """First-party Dart files an entry point compiles, conditional imports included."""
    package = "package:"+re.search(r"^name:\s*(\S+)", (root/"pubspec.yaml").read_text(), re.M).group(1)+"/"
    closure, pending = set(), [entry]
    while pending:
        name = pending.pop()
        if name in closure:
            continue
        closure.add(name)
        text = re.sub(r"(?m)//.*$", "", re.sub(r"/\*.*?\*/", "", (root/name).read_text(), flags=re.S))
        for match in _DIRECTIVE.finditer(text):
            for uri in (match.group(2), *re.findall(r"""if\s*\([^)]*\)\s*['"]([^'"]+)['"]""", match.group(3))):
                if uri.startswith(package):
                    pending.append("lib/"+uri.removeprefix(package))
                elif ":" not in uri:
                    pending.append(posixpath.normpath(posixpath.join(posixpath.dirname(name), uri)))
    return closure


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="native-build-model-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.source = self.root/"source"
        self.source.mkdir(mode=0o700)
        for name in ("macos/Runner.xcodeproj/project.pbxproj", "lib/app.dart",
                     "test/support/legacy_payment_link.dart", ".dart_tool/package_config.json", "bin/flutter"):
            path = self.source/name
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_text("model source")
            path.chmod(0o700)
        self.project = self.source/"macos/Runner.xcodeproj/project.pbxproj"
        self.commands = []
        self.case = NativeCaseLifecycle(prepare_native_case_workspace(self.root,platform="macos",
            scenario_id="flutter.macos.native-build",run_id="abcdef0123",
            worker_id=0,case_index=0,ports={"rpc":28232,"lwd":29067,"proxy":29068},activation_height=1))
        self.mode = "same-project-bytes"
        self.native_arguments = None
        self.installed_targets = {"aarch64-apple-darwin", "x86_64-apple-darwin"}
        self.leases, self.published = [], set()

    def model_inputs(self, *args, **kwargs):
        """Model collector: Pod sandbox presence plus one checked wallet source."""
        return {"pods":(self.source/"macos/Pods").is_dir(), "app":(self.source/"lib/app.dart").read_text()}

    @contextlib.contextmanager
    def modeled_cache(self, *published):
        test = self
        test.published.update(json.dumps(item, sort_keys=True) for item in published)
        class Lease:
            def __init__(self, root, inputs, **options):
                self.root, self.inputs, self.exited = root, inputs, False
                self.key = str(len(test.leases)).rjust(64, "0")
                test.leases.append(self)
            def __enter__(self):
                return self
            def __exit__(self, *_):
                self.exited = True
            def load(self):
                if test.mode == "corrupt-entry":
                    raise BUILD.cache.NativeBuildCacheError("native cache attachment/inventory changed")
                if json.dumps(self.inputs, sort_keys=True) not in test.published:
                    return None
                return {role:self.root/(role+".app") for role in ("cohort", "helper")}
            def materialize(self, case, paths):
                test.commands.append(["materialize"])
                if test.mode == "changed-during-reuse":
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
        return [args for args in self.commands if "--target" in args and "--config-only" not in args]

    def command(self, arguments, **kwargs):
        self.commands.append(arguments)
        if "--config-only" in arguments:
            self.assertTrue(all(lease.exited for lease in self.leases), "a key lease is held during configuration")
        actual = arguments[4:] if arguments[0] == sys.executable else arguments
        if actual[:3] == ["rustup", "toolchain", "list"]:
            return runtime.CommandResult(0,("stable\n",))
        if actual[:3] == ["rustup", "target", "list"]:
            return runtime.CommandResult(0,tuple(name+"\n" for name in sorted(self.installed_targets)))
        if actual[:3] == ["rustup", "target", "add"]:
            self.installed_targets.add(actual[-1])
        if "ls-files" in arguments:
            requested = arguments[arguments.index("--")+1:]
            files = ("lib/app.dart", "macos/Runner.xcodeproj/project.pbxproj", "test/support/legacy_payment_link.dart")
            return runtime.CommandResult(0,("\0".join(name for name in files if covered(name, requested))+"\0",))
        if "--target" in arguments:
            self.native_arguments = arguments
            # Reproduce the SDK's same-content metadata rewrite.
            timestamp = self.project.stat().st_mtime_ns + 1_000_000
            os.utime(self.project,ns=(timestamp,timestamp))
            if self.mode == "changed-project-bytes":
                self.project.write_text("changed project")
            elif self.mode == "changed-wallet-source":
                (self.source/"lib/app.dart").write_text("changed wallet")
            elif self.mode == "changed-test-support":
                (self.source/"test/support/legacy_payment_link.dart").write_text("changed imported test support")
            if "--config-only" in arguments:
                (self.source/"macos/Pods").mkdir(exist_ok=True)
            else:
                app = self.source/"build/macos/Build/Products/Debug/Vizor.app/Contents"
                app.mkdir(parents=True)
                (app/"embedded.provisionprofile").write_text("modeled profile")
        elif "--display" in arguments:
            return runtime.CommandResult(0,("Authority=modeled identity",))
        elif "swift" in arguments:
            target = Path(arguments[arguments.index("--scratch-path")+1])/"debug"
            target.mkdir(parents=True)
            (target/"vizor-native-cleanup").write_text("modeled executable")
        return runtime.CommandResult(0,())

    def build(self, **options):
        captured = SimpleNamespace(team="MODEL",verify_unchanged=lambda:None)
        with patch.object(self.case,"run_command",side_effect=self.command), \
             patch.object(BUILD,"_inspect_signed_app",return_value=SimpleNamespace(team="MODEL")), \
             patch.object(BUILD,"capture_mac_cleanup_helper",return_value=captured):
            return BUILD.build_native_macos_cohort(self.case,source_root=self.source,
                                                  flutter=self.source/"bin/flutter", **options)

    def test_checkout_lock_covers_preparation_and_releases_after_failure(self):
        self.mode = "changed-wallet-source"
        original = self.command
        def command(arguments, **options):
            if "--config-only" in arguments:
                with self.assertRaisesRegex(BUILD.cache.FunderCacheError,"deadline"):
                    with BUILD.cache.NativeCheckoutBuildLease(self.source,
                            timeout=0.05,cancel_event=threading.Event()):
                        pass
            return original(arguments, **options)
        with patch.object(self,"command",side_effect=command), self.modeled_cache():
            with self.assertRaisesRegex(BUILD.NativeMacosBuildError,"lib/app.dart"):
                self.build(cache_root=self.root/"cache")
        with BUILD.cache.NativeCheckoutBuildLease(self.source,
                timeout=0.1,cancel_event=threading.Event()):
            pass

    def test_unproven_join_retains_the_checkout_without_authorizing_next_build(self):
        self.mode = "changed-wallet-source"
        with patch.object(self.case,"close",side_effect=RuntimeError("unproven original join")), \
             self.modeled_cache():
            with self.assertRaisesRegex(BUILD.NativeMacosBuildError,"lib/app.dart"):
                self.build(cache_root=self.root/"cache")
        with self.assertRaisesRegex(BUILD.cache.NativeBuildCacheError,"unjoined retained"):
            with BUILD.cache.NativeCheckoutBuildLease(self.source,
                    timeout=0.1,cancel_event=threading.Event()):
                pass
        self.case.close()

    def test_pods_are_prepared_without_app_compilation_only_after_an_early_miss(self):
        def inputs(*args, **kwargs):
            configured = bool(self.configurations())
            self.assertEqual((self.source/"macos/Pods").is_dir(), configured)
            self.assertFalse(any("add" in args for args in self.commands))
            self.assertFalse(any("install" in args for args in self.commands))
            self.assertFalse(any("swift" in args for args in self.commands))
            if configured:
                raise RuntimeError("cache lookup boundary")
            return self.model_inputs()
        with self.modeled_cache(), patch.object(BUILD.cache, "collect_native_cache_inputs", side_effect=inputs):
            with self.assertRaisesRegex(RuntimeError, "cache lookup boundary"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual(len(self.configurations()), 1)
        self.assertTrue(self.leases[0].exited)

    def test_early_hit_skips_configuration_and_checkout_writes(self):
        stamp = self.project.stat().st_mtime_ns
        with self.modeled_cache({"pods":False, "app":"model source"}) as collect:
            _, proof = self.build(cache_root=self.root/"cache")
        self.assertEqual(self.configurations(), [])
        self.assertEqual(self.app_builds(), [])
        self.assertFalse((self.source/"macos/Pods").exists())
        self.assertEqual(self.project.stat().st_mtime_ns, stamp)
        self.assertEqual((proof["cache_hit"], proof["app_build_count"], proof["early_lookup"]), (True, 0, "hit"))
        self.assertNotIn("early_lookup_changed_inputs", proof)
        self.assertEqual(len(self.leases), 1)
        self.assertEqual(collect.call_count, 2)  # The early lookup and the recheck after copying.

    def test_early_miss_configures_once_then_reuses_the_configured_entry(self):
        with self.modeled_cache({"pods":True, "app":"model source"}) as collect:
            _, proof = self.build(cache_root=self.root/"cache")
        self.assertEqual(len(self.configurations()), 1)
        self.assertEqual(self.app_builds(), [])
        self.assertTrue(self.leases[0].exited)
        self.assertEqual([lease.inputs["pods"] for lease in self.leases], [False, True])
        self.assertEqual((proof["cache_hit"], proof["early_lookup"], proof["early_lookup_changed_inputs"]),
                         (True, "miss", ["pods"]))
        self.assertEqual(collect.call_count, 3)  # Early, configured and the recheck after copying.

    def test_cache_miss_configures_once_and_publishes_the_configured_key(self):
        with self.modeled_cache():
            _, proof = self.build(cache_root=self.root/"cache")
        self.assertEqual((len(self.configurations()), len(self.app_builds())), (1, 1))
        self.assertEqual(self.published, {json.dumps({"app":"model source", "pods":True}, sort_keys=True)})
        self.assertEqual((proof["cache_hit"], proof["app_build_count"], proof["early_lookup"]), (False, 1, "miss"))

    def test_missing_pre_configuration_state_falls_back_to_configuration(self):
        def inputs(*args, **kwargs):
            if not (self.source/"macos/Pods").is_dir():
                raise FileNotFoundError("macos/Podfile.lock")
            return self.model_inputs()
        with self.modeled_cache({"pods":True, "app":"model source"}), \
             patch.object(BUILD.cache, "collect_native_cache_inputs", side_effect=inputs):
            _, proof = self.build(cache_root=self.root/"cache")
        self.assertEqual(len(self.configurations()), 1)
        self.assertEqual((proof["cache_hit"], proof["early_lookup"], proof["early_lookup_error"]),
                         (True, "unavailable", "FileNotFoundError"))
        self.assertNotIn("early_lookup_changed_inputs", proof)

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
        failure = BUILD.NativeMacosBuildError("owned native build/signing failed; retain original logs", 1)
        with self.modeled_cache(), \
             patch.object(BUILD.cache, "collect_native_cache_inputs", side_effect=failure) as collect:
            with self.assertRaisesRegex(BUILD.NativeMacosBuildError, "retain original logs"):
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
        self.mode = "corrupt-entry"
        with self.modeled_cache():
            with self.assertRaisesRegex(BUILD.cache.NativeBuildCacheError, "inventory changed"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual((self.configurations(), self.app_builds()), ([], []))

    def test_early_hit_rejects_wallet_source_changed_during_reuse(self):
        self.mode = "changed-during-reuse"
        with self.modeled_cache({"pods":False, "app":"model source"}):
            with self.assertRaisesRegex(BUILD.NativeMacosBuildError, "changed during cache publication"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual(self.configurations(), [])

    def test_imported_test_support_is_in_cache_input_inventory(self):
        def inputs(root, source, *args, **kwargs):
            self.assertIn(self.source/"test/support/legacy_payment_link.dart", source)
            raise RuntimeError("cache lookup boundary")
        with patch.object(BUILD.cache,"collect_native_cache_inputs",side_effect=inputs):
            with self.assertRaisesRegex(RuntimeError,"cache lookup boundary"):
                self.build(cache_root=self.root/"cache")

    def test_source_inventory_covers_every_file_the_actual_cohort_target_imports(self):
        self.build()
        listing = next(args for args in self.commands if "ls-files" in args)
        requested = listing[listing.index("--")+1:]
        target = self.native_arguments[self.native_arguments.index("--target")+1]
        closure = dart_import_closure(CHECKOUT, target)
        self.assertIn("test/support/legacy_payment_link.dart", closure)
        self.assertEqual(sorted(path for path in closure if not covered(path, requested)), [])
        self.assertEqual(sorted(path for path in closure if path.startswith("test/")
                                and not path.startswith("test/support/")), [])

    def test_preparation_test_support_changes_are_rejected_before_configured_lookup(self):
        self.mode = "changed-test-support"
        with self.modeled_cache() as inputs:
            with self.assertRaisesRegex(BUILD.NativeMacosBuildError,"legacy_payment_link.dart"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual(inputs.call_count, 1)  # The early lookup only.
        self.assertEqual(len(self.leases), 1)

    def test_preparation_source_changes_are_rejected_before_configured_lookup(self):
        self.mode = "changed-wallet-source"
        with self.modeled_cache() as inputs:
            with self.assertRaisesRegex(BUILD.NativeMacosBuildError, "lib/app.dart"):
                self.build(cache_root=self.root/"cache")
        self.assertEqual(inputs.call_count, 1)  # The early lookup only.
        self.assertEqual(len(self.leases), 1)

    def test_sdk_project_metadata_rewrite_preserves_identical_input_bytes(self):
        _,proof = self.build()
        self.assertEqual(proof["app_build_count"],1)
        self.assertFalse(proof["wallet_or_catalog_pass"])

    def test_sdk_project_content_change_is_still_rejected(self):
        self.mode = "changed-project-bytes"
        with self.assertRaisesRegex(BUILD.NativeMacosBuildError,"project.pbxproj"):
            self.build()

    def test_cohort_build_keeps_the_existing_regtest_gift_creation_gate(self):
        self.build()
        for flag in ("--dart-define=ZCASH_DEFAULT_NETWORK=regtest",
                     "--dart-define=VIZOR_E2E_MACOS_COHORT=true",
                     "--dart-define=VIZOR_PAYMENT_LINK_REGTEST_ENABLED=true"):
            self.assertEqual(self.native_arguments.count(flag), 1)

    def test_wallet_source_content_change_is_still_rejected(self):
        self.mode = "changed-wallet-source"
        with self.assertRaisesRegex(BUILD.NativeMacosBuildError,"lib/app.dart"):
            self.build()


if __name__ == "__main__":
    unittest.main()
