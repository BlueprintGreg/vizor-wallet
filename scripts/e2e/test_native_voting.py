"""Real Git archives, original children/files/leases; compiler/service transport modeled."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_voting as VOTE
import native_voting_build as BUILD
import funder_cache as CACHE
import test_funder_build as FIXTURE


class VotingBuildTests(unittest.TestCase):
    def setUp(self):
        self.model = FIXTURE.FunderBuildTests()
        self.model.setUp()
        self.addCleanup(self.model.doCleanups)
        for name in ("scripts/init.sh", "e2e-tests/tests/create_round_for_zashi.rs", "e2e-tests/Cargo.toml",
                     "circuits/Cargo.toml", "Cargo.toml"):
            path = self.model.source/name
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_text("original model input\n")
        self.model.git("add", ".")
        self.model.git("commit", "-qm", "pinned voting model sources")
        self.pin = self.model.git("rev-parse", "HEAD").strip()
        self.case = self.model.case()
        self.make_calls = 0
        self.selected_compilers = []
        self.wrong_round = False
        self.cache = self.model.root / "voting-cache"
        self.tool_identity = "modeled tool identity"
        self.go_configuration = "off"
        self.go_programs = {name:"" for name in ("CC", "CXX", "FC", "PKG_CONFIG", "GOCACHEPROG")}
        self.tools = {"cargo": self.model.cargo, "rustc": self.model.compiler}
        self.proxies = {}
        for name in ("go", "make"):
            tool = self.model.root / ("selected-" + name)
            tool.write_text("modeled " + name + " tool\n")
            tool.chmod(0o700)
            self.tools[name] = tool
        self.go_root = self.model.root/"go-sdk"
        for name in ("src", "pkg/tool", "lib", "bin"):
            path = self.go_root/name
            path.mkdir(parents=True, exist_ok=True)
            (path/"artifact").write_text("modeled Go compiler/library")
        (self.go_root/"bin/go").write_text("modeled selected Go driver")
        (self.go_root/"bin/go").chmod(0o700)
        self.go_module_cache = self.model.root/"go-modules"
        self.go_dependency = self.go_module_cache/"example.org/dependency@v1.0.0"
        self.go_dependency.mkdir(parents=True)
        (self.go_dependency/"dependency.go").write_text("original Go dependency source")
        self.go_dependency_metadata = None

    def build(self, **options):
        if not self.case.accepting_launches:
            self.case = self.model.case()
        original = self.case.run_command
        original_which = BUILD.shutil.which

        def command(arguments, **kwargs):
            if arguments[0] == "git":
                return original(arguments, **kwargs)
            actual = arguments[4:] if arguments[0] == sys.executable else arguments
            name = Path(actual[0]).name.removeprefix("selected-")
            target = Path(kwargs["env"]["CARGO_TARGET_DIR"])
            if name == "rustc" and actual[1:] == ["-vV"]:
                data = self.tool_identity+"\nhost: aarch64-apple-darwin"
                return original([sys.executable,"-c",f"print({data!r})"], **kwargs)
            if name == "cargo" and actual[1:2] == ["metadata"]:
                self.assertNotIn("--offline", actual)  # Original voting Cargo producers permit downloads.
                self.assertIn("--locked", actual)
                payload = {"version":1,"packages":[{"id":"dependency",
                    "manifest_path":str(self.model.cargo_dependency/"Cargo.toml")}],
                    "resolve":{"nodes":[{"id":"dependency"}]}}
                return original([sys.executable, "-c", f"print({json.dumps(payload)!r})"], **kwargs)
            if name == "rustc" and actual[1:] == ["--print", "sysroot"]:
                return original([sys.executable, "-c", f"print({str(self.model.rust_sysroot)!r})"], **kwargs)
            if name == "go" and actual[1:3] == ["env", "-json"]:
                self.assertEqual(actual[3:], ["GOROOT", "GOTOOLDIR", *self.go_programs])
                data = json.dumps({"GOROOT":str(self.go_root), "GOTOOLDIR":str(self.go_root/"pkg/tool"),
                                   **self.go_programs})
                return original([sys.executable, "-c", f"print({data!r})"], **kwargs)
            if name == "go" and actual[1:] == ["env", "GOMODCACHE"]:
                return original([sys.executable, "-c", f"print({str(self.go_module_cache)!r})"], **kwargs)
            if name == "go" and actual[1:4] == ["list", "-deps", "-json=Standard,Module,Error"]:
                self.assertIn(actual[4:], (["-tags=halo2,redpallas", "./cmd/svoted"], ["./cmd/voting-config"]))
                sdk = Path(arguments[3])
                data = self.go_dependency_metadata if self.go_dependency_metadata is not None else "\n".join(
                    json.dumps(package, indent=2) for package in (
                        {"Standard":True, "Dir":str(self.go_root/"src")},
                        {"Module":{"Dir":str(sdk), "Main":True}},
                        {"Module":{"Dir":str(self.go_dependency)}}))
                return original([sys.executable, "-c", f"print({data!r})"], **kwargs)
            if actual[:1] == ["/usr/bin/which"] and actual[1] in {"cc", "ar"}:
                tool_name = "path_ar" if actual[1] == "ar" else "cc"
                return original([sys.executable, "-c", f"print({str(self.model.apple_tools[tool_name])!r})"], **kwargs)
            if actual[:3] == ["/usr/bin/xcrun", "--sdk", "macosx"]:
                path = self.model.apple_trees[-1] if "--show-sdk-path" in actual else self.model.apple_tools[actual[-1]]
                return original([sys.executable, "-c", f"print({str(path)!r})"], **kwargs)
            if name == "go" and actual[1:] == ["env", "GOENV"]:
                return original([sys.executable, "-c", f"print({str(self.go_configuration)!r})"], **kwargs)
            if name == "xcrun" and actual[1:] == ["--find", "make"]:
                return original([sys.executable, "-c", f"print({str(self.sdk_make)!r})"], **kwargs)
            if name == "rustup" and actual[1:2] == ["which"]:
                return original([sys.executable, "-c", f"print({str(self.tools[actual[2]])!r})"], **kwargs)
            if name == "make" and "-C" in actual:
                self.make_calls += 1
                self.assertIn("CIRCUITS_CARGO_FLAGS=--locked --no-default-features --features zakura", actual)
                sdk = Path(actual[actual.index("-C")+1])
                outputs = [sdk/"svoted", sdk/"voting-config"]
            elif name == "cargo" and actual[1:2] == ["build"]:
                self.assertIn("--locked", actual)
                self.selected_compilers.append(kwargs["env"].get("RUSTC"))
                outputs = [target/"release/pir-export", target/"release/nf-server"]
            elif name == "cargo" and actual[1:2] == ["test"]:
                self.assertIn("--no-run", actual)
                self.selected_compilers.append(kwargs["env"].get("RUSTC"))
                sdk = Path(actual[actual.index("--manifest-path")+1]).parent.parent
                output = target/"release/deps/create_round-modeled"
                outputs = [output]
                record = {"reason":"compiler-artifact", "executable":str(output),
                    "target":{"name":"create_round_for_zashi", "kind":["test"],
                              "src_path":str(sdk/"e2e-tests/tests/create_round_for_zashi.rs")},
                    "profile":{"test":not self.wrong_round}}
            else:
                return original([sys.executable,"-c", f"print({self.tool_identity!r})"], **kwargs)
            script = "from pathlib import Path; import json; "
            for output in outputs:
                script += (f"p=Path({str(output)!r}); p.parent.mkdir(mode=0o700,parents=True,exist_ok=True); "
                           "p.write_text('modeled original build output'); p.chmod(0o700); ")
            if name == "cargo" and actual[1:2] == ["test"]:
                script += f"print(json.dumps({record!r})); "
            return original([sys.executable,"-c",script], **kwargs)

        with patch.object(BUILD,"VOTE_SDK_REV",self.pin), patch.object(BUILD,"PIR_REV",self.pin), \
             patch.object(self.case,"run_command",side_effect=command), \
             patch.object(BUILD.shutil,"which",side_effect=lambda name, **options:
                 str(self.proxies.get(name, self.tools[name])) if name in self.tools else original_which(name, **options)):
            return BUILD.build_voting_artifacts(self.case, sdk_cache=self.model.source,
                pir_cache=self.model.source, cache_root=self.cache, timeout=15, **options)

    def published_inputs(self, proof):
        # Proofs name hashed variables; only the published manifest keeps digests.
        return json.loads((self.cache/proof["cache_key"]/"manifest.json").read_text())["inputs"]

    def test_build_once_publishes_original_joined_outputs_not_dirty_checkout(self):
        (self.model.source/"scripts/init.sh").write_text("dirty checkout")
        artifact, proof = self.build()
        self.assertEqual(self.make_calls, 1)
        self.assertFalse(self.case.accepting_launches)
        self.assertEqual((artifact.sdk/"scripts/init.sh").read_text(), "original model input\n")
        self.assertEqual(set(artifact.binaries), {"svoted","voting-config","pir-export","nf-server","create-round"})
        self.assertEqual(proof["build_count"], 1)
        self.assertFalse(proof["wallet_or_catalog_pass"])
        artifact.verify_unchanged()
        (artifact.sdk/"scripts/init.sh").write_text("changed runtime script")
        with self.assertRaisesRegex(BUILD.VotingBuildError, "runtime source changed"):
            artifact.verify_unchanged()

    def test_wrong_round_harness_cannot_become_published_artifact(self):
        self.wrong_round = True
        with self.assertRaisesRegex(BUILD.VotingBuildError, "original Cargo test"):
            self.build()
        self.assertFalse(self.case.accepting_launches)

    def test_receipt_cannot_reconstruct_original_producer(self):
        with self.assertRaises(BUILD.VotingBuildError):
            BUILD.ProducedVotingArtifacts(None, None, {}, {}, None, object(), cache_inputs={})

    def test_warm_cache_skips_builds_but_has_new_original_owner_and_runtime_scripts(self):
        cold, first = self.build()
        warm, second = self.build()
        self.assertEqual(self.make_calls, 1)
        self.assertFalse(first["cache_hit"])
        self.assertTrue(second["cache_hit"])
        self.assertEqual(second["build_count"], 0)
        self.assertEqual(first["cache_key"], second["cache_key"])
        self.assertNotEqual(cold.sdk, warm.sdk)
        self.assertEqual(first["binary_sha256"], second["binary_sha256"])
        for name in cold.binaries:
            self.assertNotEqual(cold.binaries[name].stat().st_ino, warm.binaries[name].stat().st_ino)
        self.assertEqual((warm.sdk / "scripts/init.sh").read_text(), "original model input\n")
        cold.verify_unchanged()
        warm.verify_unchanged()

    def test_jobs_and_shell_bookkeeping_are_not_build_identity(self):
        with patch.dict(os.environ, {"_": "first"}):
            _, first = self.build(jobs=1)
        with patch.dict(os.environ, {"_": "second"}):
            _, second = self.build(jobs=8)
        self.assertEqual(self.make_calls, 1)
        self.assertEqual(first["cache_key"], second["cache_key"])
        self.assertNotIn("_", self.published_inputs(first)["environment_sha256"])
        self.assertNotIn("_", first["cache_inputs"]["environment_names"])

    def test_shell_session_and_credential_variables_reuse_voting_executables(self):
        _, first = self.build()
        entries = os.environ.get("PATH", "").split(os.pathsep)
        with patch.dict(os.environ, {"PWD":"/model/elsewhere", "OLDPWD":"/model/before", "SHLVL":"9",
                                     "TERM_SESSION_ID":"w9t9p9:model", "MODEL_ACCESS_TOKEN":"model-secret",
                                     "PATH":os.pathsep.join((*entries, str(self.model.root/"missing"), entries[0]))}):
            _, second = self.build()
        self.assertTrue(second["cache_hit"])
        self.assertEqual(first["cache_key"], second["cache_key"])
        self.assertEqual(self.make_calls, 1)
        self.assertNotIn("MODEL_ACCESS_TOKEN", self.published_inputs(second)["environment_sha256"])

    def test_build_tags_invalidate_and_reports_name_variables_without_digests(self):
        with patch.dict(os.environ, {"BUILD_TAGS":"first-model-tag"}):
            _, first = self.build()
        with patch.dict(os.environ, {"BUILD_TAGS":"second-model-tag"}):
            _, second = self.build()
        self.assertNotEqual(first["cache_key"], second["cache_key"])
        self.assertEqual(self.make_calls, 2)
        digest = hashlib.sha256(b"second-model-tag").hexdigest()
        self.assertEqual(self.published_inputs(second)["environment_sha256"]["BUILD_TAGS"], digest)
        written = (self.case.workspace.root/"voting-build/build-proof.json").read_text()
        for report in (json.dumps(second), written):
            self.assertNotIn(digest, report)
            self.assertNotIn("environment_sha256", report)
        self.assertIn("BUILD_TAGS", second["cache_inputs"]["environment_names"])
        self.assertEqual(json.loads(written)["cache_inputs"]["environment_names"],
                         second["cache_inputs"]["environment_names"])

    def test_absolute_cargo_receives_the_captured_original_rust_compiler(self):
        _, proof = self.build()
        expected = proof["cache_inputs"]["tools"]["outer"]["rustc"]["path"]
        self.assertEqual(self.selected_compilers, [expected, expected])

    @unittest.skipUnless(sys.platform == "darwin", "the Apple Make proxy is macOS-only")
    def test_system_make_proxy_binds_the_actual_selected_sdk_implementation(self):
        self.sdk_make = self.tools["make"]
        self.tools["make"] = Path("/usr/bin/make")
        _, proof = self.build()
        for context in ("outer", "sdk"):
            self.assertEqual(proof["cache_inputs"]["tools"][context]["make"]["path"], str(self.sdk_make))
        self.assertEqual(self.make_calls, 1)

    def rustup_proxies(self):
        rustup = self.model.root/"rustup"
        rustup.write_text("original rustup driver")
        rustup.chmod(0o700)
        for name in ("cargo", "rustc"):
            self.proxies[name] = self.model.root/("proxy-"+name)
            self.proxies[name].symlink_to(rustup)
        return rustup

    def test_rustup_proxy_bytes_invalidate_without_selected_compiler_changes(self):
        rustup = self.rustup_proxies()
        _, first = self.build()
        _, warm = self.build()
        self.assertTrue(warm["cache_hit"])
        self.assertEqual(warm["build_count"], 0)
        rustup.write_text("repaired rustup driver")
        _, second = self.build()
        for field in ("tools", "tool_versions", "environment_sha256"):
            self.assertEqual(self.published_inputs(first)[field], self.published_inputs(second)[field])
        self.assertNotEqual(first["cache_key"], second["cache_key"])
        self.assertEqual(self.make_calls, 2)
        for context in ("outer", "sdk"):
            for name in ("cargo", "rustc"):
                self.assertEqual(first["cache_inputs"]["invoked_tools"][context][name]["path"], str(rustup))

    def test_rustup_proxy_mutation_while_sealing_rejects_without_launch(self):
        rustup = self.rustup_proxies()
        close = self.case.close
        def seal():
            receipt = close()
            rustup.write_text("changed rustup driver after join")
            return receipt
        with patch.object(self.case,"close",side_effect=seal), self.assertRaisesRegex(
                BUILD.VotingBuildError,"build tool or producer changed"):
            self.build()
        self.assertFalse(self.case.accepting_launches)

    def test_changed_pin_tool_bytes_version_and_environment_invalidate(self):
        keys = [self.build()[1]["cache_key"]]
        self.tools["go"].write_text("changed Go bytes\n")
        keys.append(self.build()[1]["cache_key"])
        self.tool_identity = "new modeled version"
        keys.append(self.build()[1]["cache_key"])
        with patch.dict(os.environ, {"CGO_CFLAGS": "-DNEW_BUILD"}):
            keys.append(self.build()[1]["cache_key"])
        (self.model.source / "scripts/init.sh").write_text("changed pinned script\n")
        self.model.git("add", "scripts/init.sh")
        self.model.git("commit", "-qm", "changed pin")
        self.pin = self.model.git("rev-parse", "HEAD").strip()
        keys.append(self.build()[1]["cache_key"])
        self.assertEqual(len(set(keys)), 5)
        self.assertEqual(self.make_calls, 5)

    def test_cargo_dependency_bytes_invalidate_without_lock_config_or_environment_changes(self):
        _, first = self.build()
        (self.model.cargo_dependency/"lib.rs").write_text("patched Cargo dependency")
        _, second = self.build()
        for field in ("configuration_sha256", "environment_sha256", "archives_sha256"):
            self.assertEqual(self.published_inputs(first)[field], self.published_inputs(second)[field])
        self.assertNotEqual(first["cache_key"], second["cache_key"])
        self.assertEqual(self.make_calls, 2)

    def test_go_dependency_bytes_invalidate_without_lock_config_or_environment_changes(self):
        _, first = self.build()
        (self.go_dependency/"dependency.go").write_text("patched Go dependency source")
        _, second = self.build()
        for field in ("configuration_sha256", "environment_sha256", "archives_sha256", "tool_versions"):
            self.assertEqual(self.published_inputs(first)[field], self.published_inputs(second)[field])
        self.assertNotEqual(first["cache_key"], second["cache_key"])
        self.assertEqual(self.make_calls, 2)

    def test_go_dependency_mutation_while_sealing_rejects_without_launch(self):
        close = self.case.close
        def seal():
            receipt = close()
            (self.go_dependency/"dependency.go").write_text("changed Go source after join")
            return receipt
        with patch.object(self.case,"close",side_effect=seal), self.assertRaisesRegex(
                BUILD.VotingBuildError,"Go dependency sources changed"):
            self.build()
        self.assertFalse(self.case.accepting_launches)

    def test_go_dependency_inventory_binds_effective_replacement_and_nested_sources(self):
        metadata = "go: downloading example.org/dependency v1.0.0\n"+json.dumps({"Module":{
            "Dir":str(self.go_dependency), "Replace":{"Dir":str(self.go_dependency)}}})
        def command(args):
            if args[1:] == ["env", "GOMODCACHE"]:
                return (str(self.go_module_cache),)
            return (metadata,)
        def inputs():
            return BUILD.toolchain_inputs.go_dependency_inputs(command, self.tools["go"], threading.Event(),
                queries=(("-tags=halo2,redpallas", "./cmd/svoted"),))
        first = inputs()
        self.assertEqual(set(first["source_trees_sha256"]), {str(self.go_dependency)})
        nested = self.go_dependency/"build/generated.go"
        nested.parent.mkdir()
        nested.write_text("compiled source even under generated-looking directory")
        self.assertNotEqual(first, inputs())

    def test_invalid_go_dependency_metadata_cannot_authorize_cache_lookup(self):
        for payload in ("", "not metadata", json.dumps({"Module":{"Dir":"relative"}}),
                        json.dumps({"Error":{"Err":"unresolved package"}})):
            with self.subTest(payload=payload):
                self.go_dependency_metadata = payload
                with self.assertRaises(BUILD.toolchain_inputs.ToolInputError):
                    self.build()
                self.assertEqual(self.make_calls, 0)

    @unittest.skipUnless(sys.platform == "darwin", "default Apple archiver inputs are macOS-only")
    def test_default_archiver_bytes_invalidate_without_compiler_or_environment_changes(self):
        _, first = self.build()
        self.model.apple_tools["path_ar"].write_text("patched default archiver")
        _, second = self.build()
        for field in ("tools", "tool_versions", "environment_sha256"):
            self.assertEqual(self.published_inputs(first)[field], self.published_inputs(second)[field])
        self.assertNotEqual(first["cache_key"], second["cache_key"])
        self.assertEqual(self.make_calls, 2)

    def test_forwarded_linker_prefix_bytes_invalidate_with_unchanged_environment(self):
        linker = self.model.root/"forwarded-tools/ld"
        linker.parent.mkdir()
        linker.write_text("original forwarded linker")
        linker.chmod(0o700)
        with patch.dict(os.environ,{"RUSTFLAGS":"-C link-arg=-B"+str(linker.parent)}):
            _,first = self.build()
            linker.write_text("patched forwarded linker")
            _,second = self.build()
        self.assertEqual(self.published_inputs(first)["environment_sha256"],
                         self.published_inputs(second)["environment_sha256"])
        self.assertNotEqual(first["cache_key"],second["cache_key"])
        self.assertEqual(self.make_calls,2)

    def test_target_rustflags_linker_bytes_invalidate_with_unchanged_environment(self):
        linker = self.model.root/"target-linker"
        linker.write_text("original target linker")
        linker.chmod(0o700)
        with patch.dict(os.environ, {"CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS":"-C linker="+str(linker)}):
            _, first = self.build()
            linker.write_text("patched target linker")
            _, second = self.build()
        self.assertEqual(self.published_inputs(first)["environment_sha256"],
                         self.published_inputs(second)["environment_sha256"])
        self.assertNotEqual(first["cache_key"], second["cache_key"])
        self.assertEqual(self.make_calls, 2)

    def test_go_configuration_contents_invalidate_without_logging_values(self):
        configuration = self.model.root / "go-env"
        configuration.write_text("first secret configuration\n")
        self.go_configuration = configuration
        _, first = self.build()
        configuration.write_text("second secret configuration\n")
        _, second = self.build()
        self.assertNotEqual(first["cache_key"], second["cache_key"])
        self.assertNotIn("secret configuration", json.dumps(second["cache_inputs"]))
        self.assertEqual(self.make_calls, 2)

    def test_goenv_program_bytes_invalidate_with_unchanged_configuration_and_environment(self):
        configuration = self.model.root/"go-env"
        self.go_configuration = configuration
        for name in self.go_programs:
            with self.subTest(setting=name):
                program = self.model.root/('effective-'+name.lower())
                program.write_text("original Go-configured compiler")
                program.chmod(0o700)
                self.go_programs[name] = str(program)+" --configured-argument"
                configuration.write_text(name+"="+self.go_programs[name]+"\n")
                _, first = self.build()
                program.write_text("patched Go-configured compiler")
                _, second = self.build()
                for field in ("configuration_sha256", "environment_sha256", "tool_versions"):
                    self.assertEqual(self.published_inputs(first)[field], self.published_inputs(second)[field])
                self.assertNotEqual(first["cache_key"], second["cache_key"])
                for context in ("outer", "sdk"):
                    self.assertNotEqual(first["cache_inputs"]["compiler_inputs"]["go"][context],
                                        second["cache_inputs"]["compiler_inputs"]["go"][context])
                self.go_programs[name] = ""

    def test_goenv_program_mutation_while_sealing_rejects_without_launch(self):
        program = self.model.root/"effective-go-cc"
        program.write_text("original compiler")
        program.chmod(0o700)
        self.go_programs["CC"] = str(program)
        close = self.case.close
        def seal():
            receipt = close()
            program.write_text("changed compiler after join")
            return receipt
        with patch.object(self.case,"close",side_effect=seal), self.assertRaisesRegex(
                BUILD.VotingBuildError,"compiler/linker/SDK inputs changed"):
            self.build()
        self.assertFalse(self.case.accepting_launches)

    def test_go_compiler_and_sdk_bytes_invalidate_with_unchanged_driver_version(self):
        for name in ("src/artifact", "pkg/tool/artifact", "lib/artifact", "bin/go"):
            with self.subTest(input=name):
                _, first = self.build()
                (self.go_root/name).write_text("patched Go SDK input")
                _, second = self.build()
                self.assertEqual(first["cache_inputs"]["tool_versions"],
                                 second["cache_inputs"]["tool_versions"])
                self.assertEqual(first["cache_inputs"]["tools"], second["cache_inputs"]["tools"])
                self.assertNotEqual(first["cache_key"], second["cache_key"])

    def test_cargo_dependency_mutation_while_sealing_rejects_without_launch(self):
        close = self.case.close
        def seal():
            receipt = close()
            (self.model.cargo_dependency/"lib.rs").write_text("changed dependency after join")
            return receipt
        with patch.object(self.case,"close",side_effect=seal), self.assertRaisesRegex(
                BUILD.VotingBuildError,"Cargo dependency sources changed"):
            self.build()
        self.assertFalse(self.case.accepting_launches)

    def test_go_mutation_while_sealing_rejects_publication_without_launch(self):
        close = self.case.close
        def seal():
            receipt = close()
            (self.go_root/"pkg/tool/artifact").write_text("changed Go compiler after join")
            return receipt
        with patch.object(self.case, "close", side_effect=seal), self.assertRaisesRegex(
                BUILD.VotingBuildError, "compiler/linker/SDK inputs changed"):
            self.build()
        self.assertFalse(self.case.accepting_launches)

    def test_rust_sysroot_changes_invalidate_without_compiler_or_version_changes(self):
        for path in self.model.rust_libraries:
            with self.subTest(input=path):
                _, first = self.build()
                path.write_text("patched Rust sysroot library")
                _, second = self.build()
                self.assertEqual(first["cache_inputs"]["tools"], second["cache_inputs"]["tools"])
                self.assertEqual(first["cache_inputs"]["tool_versions"], second["cache_inputs"]["tool_versions"])
                self.assertNotEqual(first["cache_key"], second["cache_key"])

    def test_corrupt_cache_fails_without_rebuild_or_overwrite(self):
        _, proof = self.build()
        binary = self.cache / proof["cache_key"] / "svoted"
        binary.chmod(0o700)
        binary.write_text("corrupt cached executable")
        binary.chmod(0o500)
        with self.assertRaisesRegex(CACHE.FunderCacheError, "bytes changed"):
            self.build()
        self.assertEqual(self.make_calls, 1)
        self.assertEqual(binary.read_text(), "corrupt cached executable")

    def test_one_runtime_copy_cannot_mutate_shared_cache_or_sibling(self):
        cold, first = self.build()
        sibling, _ = self.build()
        cold.binaries["svoted"].chmod(0o700)
        cold.binaries["svoted"].write_text("changed case-local executable")
        with self.assertRaises(BUILD.VotingBuildError):
            cold.verify_unchanged()
        sibling.verify_unchanged()
        _, third = self.build()
        self.assertEqual(self.make_calls, 1)
        self.assertEqual(first["binary_sha256"], third["binary_sha256"])

    def test_publication_inventory_cannot_be_replaced_with_a_loose_binary(self):
        artifact, _ = self.build()
        artifact.binaries["svoted"] = self.tools["go"]
        with self.assertRaisesRegex(BUILD.VotingBuildError, "inventory changed"):
            artifact.verify_unchanged()

    def test_failed_original_compile_has_no_immutable_publication(self):
        self.wrong_round = True
        with self.assertRaises(BUILD.VotingBuildError):
            self.build()
        self.assertFalse(any(path.is_dir() for path in self.cache.iterdir()))


class VotingOracleTests(unittest.TestCase):
    def test_real_oracles_require_discovery_nonempty_tree_and_parallel_slow_shares(self):
        metrics = {"discovery_successes":1,"config_requests":1,"round_list_requests":1,
                   "slow_share_requests":2,"slow_share_max_inflight":2}
        for index in (1, "1"):
            VOTE.verify_participation(metrics,{"tree":{"next_index":index}},slow_helper=True)
        for index in (0,"0",True,None):
            with self.assertRaises(VOTE.RunnerError):
                VOTE.verify_participation(metrics,{"tree":{"next_index":index}},slow_helper=False)
        metrics["slow_share_max_inflight"] = 1
        with self.assertRaises(VOTE.RunnerError):
            VOTE.verify_participation(metrics,{"tree":{"next_index":1}},slow_helper=True)

    def test_missing_generated_binding_does_not_fall_back_to_shared_default(self):
        with self.assertRaisesRegex(VOTE.RunnerError, "missing generated"):
            VOTE.patch_toml('[api]\naddress = "shared"\n', {("grpc","address"):"127.0.0.1:1234"})
        self.assertIn('address = "127.0.0.1:1234"', VOTE.patch_toml(
            '[api]\naddress = "shared"\n', {("api","address"):"127.0.0.1:1234"}))

    def test_unproven_original_service_join_keeps_all_port_locks(self):
        model = FIXTURE.FunderBuildTests()
        model.setUp()
        self.addCleanup(model.doCleanups)
        case = model.case()
        services = object.__new__(VOTE.NativeVotingServices)
        services.closed = services._failed = False
        services.session = Mock(case=case)
        services.artifact = Mock()
        services.lease = VOTE.lease_native_ports(0,"a1b2c3d4e5",
            port_names=VOTE.PORT_NAMES, lock_root=model.root/"locks")
        self.addCleanup(services.lease.close)
        services.lease.release_sockets()
        services.processes = [case.start_process([sys.executable,"-u","-c","import time; time.sleep(30)"],
                                                env=os.environ.copy())]
        with patch.object(case,"stop_process",side_effect=RuntimeError("join unproved")):
            with self.assertRaisesRegex(VOTE.RunnerError,"retain state and port locks"):
                services.close()
        for port in services.lease.ports.values():
            descriptor = os.open(model.root/"locks"/f"{port}.lock",os.O_RDWR)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(descriptor,fcntl.LOCK_EX|fcntl.LOCK_NB)
            finally:
                os.close(descriptor)
        case.close()  # Join the test's original writer before releasing its leases.


class VotingStateLayoutTests(unittest.TestCase):
    """Real case directories; exporters, nf-server and the vote chain are modeled."""

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="voting-layout-model-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.evidence = self.root/"evidence/e2e/vizor_a1b2c3d4e5_w0_1"
        self.mutable = self.root/"workspace/vizor_a1b2c3d4e5_w0_1"
        for path in (self.evidence, self.mutable, self.root/"sdk"):
            path.mkdir(mode=0o700, parents=True)
        manifest = json.dumps({"worker_id":0, "run_id":"a1b2c3d4e5"})
        session = object.__new__(VOTE.NativeWorkerCase)
        session._finished, session._front, session.mutable_directory = False, Mock(), self.mutable
        session.verify_owned = lambda: None
        session.case = Mock(workspace=Mock(root=self.evidence,
            launch_environment=Mock(return_value={"VIZOR_E2E_CASE_MANIFEST":manifest})))
        artifact = object.__new__(BUILD.ProducedVotingArtifacts)
        artifact.verify_unchanged = lambda: None
        artifact.sdk = self.root/"sdk"
        artifact.binaries = {name:self.root/name for name in
                             ("svoted", "voting-config", "pir-export", "nf-server", "create-round")}
        self.services = VOTE.NativeVotingServices(session, artifact, self.root, sys.executable, threading.Event())
        self.commands = {}
        self.served_height = 510

    def start(self):
        services = self.services

        def run(name, command, *, cwd=None, extra_env=None):
            self.commands[name] = command
            if name == "nullifier-export":
                Path(command[command.index("--output")+1]).write_bytes(b"n"*32)
            elif name == "pir-export":
                output = Path(command[command.index("--output-dir")+1])
                for tier, size in (("tier0.bin", 16), ("tier1.bin", 64), ("pir_root.json", 8)):
                    (output/tier).write_bytes(b"t"*size)
            return ""

        def spawn(name, command, ports):
            self.commands[name] = command
            if name == "pir-server":  # nf-server writes its index and cache into --pir-data-dir.
                data = Path(command[command.index("--pir-data-dir")+1])
                (data/"nullifiers.index").write_bytes(b"i"*16)
                (data/"tier1.precompute").write_bytes(b"p"*4096)

        def get(url):
            if url.endswith("/root"):
                return {"height":self.served_height, "nullifier_pool":"ironwood", "dataset_version":2}
            if url.endswith("/rounds/active"):
                return {"round":{"vote_round_id":base64.b64encode(b"\x01"*32).decode(), "ea_pk":"model"}}
            if url.endswith("/commit"):
                return {"result":{"signed_header":{"header":{"chain_id":"svote-1", "validators_hash":"A"*64}}}}
            raise AssertionError(url)

        def signed_config(round_id, ea_pk):
            (services.config/"static-voting-config.json").write_text("{}")

        lease = Mock(ports={name:40000+index for index, name in enumerate(VOTE.PORT_NAMES)})
        with patch.object(VOTE, "lease_native_ports", return_value=lease), \
             patch.object(services, "_run", side_effect=run), \
             patch.object(services, "_spawn", side_effect=spawn), \
             patch.object(services, "_get", side_effect=get), \
             patch.object(services, "_signed_config", side_effect=signed_config), \
             patch.object(services, "_ready"), patch.object(services, "_patch_bindings"), \
             patch.object(services, "_check_processes"):
            return services.start(510, "http://127.0.0.1:29067", time.monotonic_ns()+60*10**9)

    def test_pir_tiers_and_precompute_cache_stay_out_of_case_evidence(self):
        self.start()
        pir, snapshot = self.mutable/VOTE.PIR_DATA_DIRECTORY, self.evidence/"voting/pir-snapshot"
        self.assertEqual(self.services.pir_data, pir)
        self.assertEqual(sorted(path.name for path in snapshot.iterdir()), sorted(VOTE.SNAPSHOT_FILES))
        self.assertEqual((snapshot/"nullifiers.checkpoint").read_bytes(), struct.pack("<QQ", 510, 32))
        for name in VOTE.SNAPSHOT_FILES:
            self.assertEqual((pir/name).read_bytes(), (snapshot/name).read_bytes())
        exported = self.commands["pir-export"]
        for flag in ("--nullifiers", "--checkpoint", "--output-dir"):
            self.assertTrue(Path(exported[exported.index(flag)+1]).is_relative_to(pir))
        served = self.commands["pir-server"]
        self.assertEqual(served[served.index("--pir-data-dir")+1], str(pir))
        self.assertTrue((pir/"tier1.precompute").exists())
        names = {path.name for path in self.evidence.rglob("*")}
        self.assertFalse(names & {"pir-data", "tier0.bin", "tier1.bin", "tier1.precompute", "nullifiers.index"})
        for name in ("pir-root.json", "ports.json", "runtime.json"):
            self.assertTrue((self.evidence/"voting"/name).exists(), name)

    def test_existing_mutable_pir_directory_is_never_adopted(self):
        stale = self.mutable/VOTE.PIR_DATA_DIRECTORY
        stale.mkdir(mode=0o700)
        (stale/"tier1.precompute").write_bytes(b"stale")
        with self.assertRaisesRegex(VOTE.RunnerError, "single-use"):
            self.start()
        self.assertFalse((self.evidence/"voting").exists())
        self.assertEqual((stale/"tier1.precompute").read_bytes(), b"stale")
        self.assertEqual(self.commands, {})

    def test_failed_start_keeps_snapshot_and_mutable_pir_data(self):
        self.served_height = 511
        with self.assertRaisesRegex(VOTE.RunnerError, "exact real migration snapshot"):
            self.start()
        self.assertTrue(self.services.closed)
        self.assertTrue((self.evidence/"voting/pir-snapshot/nullifiers.bin").exists())
        self.assertTrue((self.mutable/VOTE.PIR_DATA_DIRECTORY/"tier1.precompute").exists())


if __name__ == "__main__":
    unittest.main()
