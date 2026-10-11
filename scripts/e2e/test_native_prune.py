"""Prune models: real run folders, locks and processes; Docker and simctl are modeled."""
import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import native_retention as RETENTION
import native_worker_lifecycle as WORKER
import test_native_zakura_backend as BACKEND_FIXTURES
SPEC = importlib.util.spec_from_file_location("vizor_e2e_prune", SCRIPT_DIR / "native-prune.py")
assert SPEC is not None and SPEC.loader is not None
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)

FIXTURE = "005a93ffd4a44f13b52fb023f9690070"
SECOND = "7b1e0c9d2a3f4e5d6c7b8a9f0e1d2c3b"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-3"
DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPhone-16"
UDID = "8832E342-5B2F-4D21-AC0F-79A33DE629D7"
OTHER_UDID = "1C0FFEE0-0000-4000-8000-000000000001"


def completed(stdout="", stderr="", returncode=0):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class DockerModel:
    """Daemon state with exact label filters, inspect, removal and absence errors."""
    def __init__(self, honor_filters=True):
        self.objects, self.calls, self.inspections = {}, [], {}
        self.honor_filters = honor_filters
        self.failures, self.drift = set(), {}

    @staticmethod
    def labels(kind, payload):
        return payload["Config"]["Labels"] if kind == "container" else payload["Labels"]

    def fixture(self, fixture, case=None, *, source=None, labels=None):
        prefix, owner = "zakura-proof-" + fixture[:12], {
            "com.zakura.regtest-fixture": "1", "com.zakura.regtest-fixture.run": fixture, **(labels or {})}
        ids = {}
        for role in ("node", "lwd"):
            ids[role] = hashlib.sha256((fixture + role).encode()).hexdigest()
            mount = source or (case / "zakura-backend" / "zakurad.toml" if case is not None else None)
            self.objects[("container", ids[role])] = {"Id": ids[role], "Name": "/" + prefix + "-" + role,
                "Config": {"Labels": dict(owner)}, "Mounts": [{"Type": "bind", "Source": str(mount),
                "Destination": "/config/zakurad.toml"}] if role == "node" and mount is not None else []}
        ids["volume"] = prefix + "-lwd-data"
        self.objects[("volume", ids["volume"])] = {"Name": ids["volume"], "Driver": "local", "Labels": dict(owner)}
        ids["network"] = hashlib.sha256((fixture + "net").encode()).hexdigest()
        self.objects[("network", ids["network"])] = {"Id": ids["network"], "Name": prefix + "-net",
                                                     "Labels": dict(owner)}
        return ids

    def tsz(self):
        labels = {"com.zakura.tsz.instance": "codex-preview"}
        self.objects[("network", "a" * 64)] = {"Id": "a" * 64, "Name": "tsz-codex-preview", "Labels": labels}
        for name in ("tsz-codex-preview-chain", "tsz-codex-preview-lwd"):
            self.objects[("volume", name)] = {"Name": name, "Driver": "local", "Labels": dict(labels)}

    def __call__(self, arguments):
        self.calls.append(tuple(arguments))
        kind, verb = arguments[0], arguments[1]
        if verb == "ls":
            key, value = arguments[arguments.index("--filter") + 1].removeprefix("label=").split("=", 1)
            return completed("".join(ident + "\n" for (item_kind, ident), payload in self.objects.items()
                if item_kind == kind and (not self.honor_filters or self.labels(kind, payload).get(key) == value)))
        ident = arguments[-1]
        payload = self.objects.get((kind, ident))
        if verb == "inspect":
            self.inspections[ident] = self.inspections.get(ident, 0) + 1
            if payload is None:
                return completed("[]\n", RETENTION._ABSENT[kind].format(ident) + "\n", 1)
            if ident in self.drift and self.inspections[ident] > 1:
                self.labels(kind, payload).update(self.drift[ident])
            return completed(json.dumps([payload]))
        if verb == "rm" and payload is not None:
            if ident in self.failures:
                return completed("", "Error response from daemon: removal failed", 1)
            del self.objects[(kind, ident)]
            return completed(ident + "\n")
        raise AssertionError(arguments)

    def removals(self):
        return [call for call in self.calls if call[1] == "rm"]


class SimctlModel:
    """Device inventory and its per-UUID directories under a private home."""
    def __init__(self, home):
        self.home, self.devices, self.calls = home, {}, []

    def add(self, udid, name, state="Shutdown"):
        self.devices[udid] = {"udid": udid, "name": name, "state": state, "isAvailable": True,
                              "deviceTypeIdentifier": DEVICE}
        (self.home / RETENTION._DEVICES / udid).mkdir(parents=True)

    def __call__(self, arguments):
        self.calls.append(tuple(arguments))
        if arguments == ["list", "devices", "--json"]:
            return completed(json.dumps({"devices": {RUNTIME: list(self.devices.values())}}))
        if arguments[0] == "shutdown" and arguments[1] in self.devices:
            self.devices[arguments[1]]["state"] = "Shutdown"
            return completed()
        if arguments[0] == "delete" and self.devices.get(arguments[1], {}).get("state") == "Shutdown":
            del self.devices[arguments[1]]
            shutil.rmtree(self.home / RETENTION._DEVICES / arguments[1])
            return completed()
        raise AssertionError(arguments)

    def mutations(self):
        return [call for call in self.calls if call[0] != "list"]


class PruneTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="native-prune-model-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.checkout, self.home = self.root / "checkout", self.root / "home"
        self.checkout.mkdir()
        self.home.mkdir()
        self.logs = self.checkout / ".regtest-logs"
        self.logs.mkdir(mode=0o700)
        self.docker, self.simctl = DockerModel(), SimctlModel(self.home)

    def run_folder(self, run_id, *, lock=True, summary=True):
        path = self.logs / ("native-suite-" + run_id)
        path.mkdir(mode=0o700)
        (path / "builds").mkdir(mode=0o700)
        (path / "repetition-0").mkdir(mode=0o700)
        (path / "repetition-0" / "run.json").write_text(json.dumps({"schema_version": 2, "results": []}))
        if lock:
            os.close(os.open(path / "run-owner.lock", os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600))
            (path / "run-owner.json").write_text(json.dumps({"schema_version": 1, "run_id": run_id}))
        if summary:
            (path / "summary.json").write_text(json.dumps({"schema_version": 2, "run_id": run_id}))
        return path

    def hold(self, lock):
        """A separate process holds the run lock, as its live runner would."""
        source = ("import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDWR); fcntl.flock(fd,fcntl.LOCK_EX); "
                  "print('held',flush=True); sys.stdin.read()")
        process = subprocess.Popen([sys.executable, "-c", source, str(lock)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, text=True)
        def stop():
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            process.stdin.close()
            process.stdout.close()
        self.addCleanup(stop)
        self.assertEqual(process.stdout.readline(), "held\n")
        return stop

    def case(self, run, repetition="1111111111", worker=3, *, fixture=None, device=None, intent_only=False):
        namespace = f"vizor_{repetition}_w{worker}_1"
        path = run
        for part in ("repetition-0", "native-workers", f"{repetition}-w{worker}", "evidence", "e2e", namespace):
            path = path / part
            path.mkdir(mode=0o700, exist_ok=True)
        (path / "workspace-owner.json").write_text(json.dumps({"schema_version": 1, "workspace": str(path),
            "namespace": namespace, "owner_nonce": "ab" * 16}) + "\n")
        (path / "case-manifest.json").write_text("{}")
        if fixture is not None:
            (path / "zakura-backend").mkdir(mode=0o700)
            (path / "zakura-backend" / "fixture-identity.json").write_text(json.dumps({"run_id": fixture}))
            (path / "zakura-backend" / "zakurad.toml").write_text("[network]\n")
        if device is not None:
            intent = {"schema_version": 1, "namespace": namespace, "workspace": str(path),
                      "name": "Vizor E2E " + namespace, "runtime_identifier": RUNTIME,
                      "device_type_identifier": DEVICE, "owner_nonce": "0123456789abcdef"}
            (path / "simulator-allocation.json").write_text(json.dumps(intent))
            if intent_only:
                (path / "simulator-0123456789abcdef-0002.log").write_text(device + "\n")
            else:
                (path / "simulator-owner.json").write_text(json.dumps({**intent, "udid": device}))
        return path

    def prune(self, *arguments):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            try:
                code = CLI.main(arguments, checkout=self.checkout, home=self.home,
                                docker=self.docker, simctl=self.simctl)
            except SystemExit as error:  # argparse usage errors
                code = error.code
        return code, output.getvalue(), errors.getvalue()

    def names(self):
        return sorted(payload["Name"].lstrip("/") for payload in self.docker.objects.values())

    def snapshot(self):
        return {str(path.relative_to(self.root)): (path.lstat().st_mode, path.read_bytes() if path.is_file()
                                                   and not path.is_symlink() else None)
                for path in self.root.rglob("*")}

    def dead_run_with_resources(self, run_id="a1b2c3d4e5", state="Booted"):
        run = self.run_folder(run_id)
        case = self.case(run, fixture=FIXTURE, device=UDID)
        ids = self.docker.fixture(FIXTURE, case)
        self.simctl.add(UDID, "Vizor E2E " + case.name, state)
        return run, case, ids

    def test_dry_run_lists_what_would_be_removed_and_changes_nothing(self):
        run, case, ids = self.dead_run_with_resources()
        before = self.snapshot()
        code, output, errors = self.prune("--builds", "--folders", "--run", "a1b2c3d4e5")
        self.assertEqual((code, errors), (0, ""))
        self.assertIn("run       native-suite-a1b2c3d4e5  dead: run-owner.lock is free", output)
        for kind, name in (("container", "zakura-proof-005a93ffd4a4-node"),
                           ("volume", "zakura-proof-005a93ffd4a4-lwd-data"),
                           ("network", "zakura-proof-005a93ffd4a4-net"), ("simulator", "Vizor E2E " + case.name)):
            self.assertRegex(output, rf"delete +{kind} +{name}")
        self.assertRegex(output, r"strip +builds")
        self.assertRegex(output, r"remove +folder +native-suite-a1b2c3d4e5")
        self.assertEqual(self.snapshot(), before)
        self.assertEqual({call[1] for call in self.docker.calls}, {"ls", "inspect"})
        self.assertEqual(self.simctl.mutations(), [])
        self.assertFalse((self.logs / "prune").exists())

    def test_apply_removes_exact_ids_in_order_and_records_a_receipt(self):
        run, case, ids = self.dead_run_with_resources()
        reports = {name: (run / name).read_bytes() for name in ("summary.json", "repetition-0/run.json")}
        code, output, errors = self.prune("--apply")
        self.assertEqual((code, errors), (0, ""))
        removals = self.docker.removals()
        self.assertEqual(sorted(removals[:2]), sorted([("container", "rm", "--force", ids["node"]),
                                                       ("container", "rm", "--force", ids["lwd"])]))
        self.assertEqual(removals[2:], [("volume", "rm", ids["volume"]), ("network", "rm", ids["network"])])
        for removal in removals:
            position = self.docker.calls.index(removal)
            self.assertEqual(self.docker.calls[position - 1], (removal[0], "inspect", removal[-1]))
            self.assertEqual(self.docker.calls[position + 1], (removal[0], "inspect", removal[-1]))
        self.assertEqual(self.simctl.mutations(), [("shutdown", UDID), ("delete", UDID)])
        self.assertFalse((self.home / RETENTION._DEVICES / UDID).exists())
        self.assertEqual({name: (run / name).read_bytes() for name in reports}, reports)
        self.assertTrue((case / "simulator-owner.json").exists())
        receipts = sorted((self.logs / "prune").glob("prune-*.json"))
        self.assertEqual(len(receipts), 1)
        self.assertEqual(stat.S_IMODE(receipts[0].stat().st_mode), 0o400)
        receipt = json.loads(receipts[0].read_text())
        self.assertEqual(set(receipt), {"schema_version", "checkout", "started_at", "finished_at", "options",
                                        "unavailable", "runs", "items", "complete"})
        self.assertTrue(receipt["complete"])
        self.assertEqual(receipt["runs"], [{"run_id": "a1b2c3d4e5", "liveness": "dead",
                                            "reason": "run-owner.lock is free"}])
        self.assertEqual(sorted((item["kind"], item["result"]) for item in receipt["items"]), [
            ("container", "deleted"), ("container", "deleted"), ("network", "deleted"),
            ("simulator", "deleted"), ("volume", "deleted")])
        self.assertTrue((self.logs / "prune" / "prune.lock").exists())
        self.assertIn("5 item(s) removed, 0 failed; receipt: ", output)

    def test_liveness_comes_from_the_run_lock_or_a_legacy_summary_only(self):
        alive = self.run_folder("aaaaaaaaaa")
        stop = self.hold(alive / "run-owner.lock")
        self.docker.fixture(FIXTURE, self.case(alive, fixture=FIXTURE))
        live_names = self.names()
        starting = self.run_folder("bbbbbbbbbb", summary=False)
        (starting / "run-owner.json").unlink()  # Lock created, never held yet.
        legacy = self.run_folder("cccccccccc", lock=False)
        self.docker.fixture(SECOND, self.case(legacy, "2222222222", fixture=SECOND))
        unknown = self.run_folder("dddddddddd", lock=False, summary=False)
        self.case(unknown, "3333333333", device=UDID)
        self.simctl.add(UDID, "Vizor E2E vizor_3333333333_w3_1")
        code, output, _ = self.prune("--apply")
        self.assertEqual(code, 0)
        self.assertIn("native-suite-aaaaaaaaaa  alive: its runner holds run-owner.lock", output)
        self.assertIn("native-suite-bbbbbbbbbb  unknown: ", output)
        self.assertIn("native-suite-cccccccccc  dead: summary.json exists", output)
        self.assertIn("native-suite-dddddddddd  unknown: ", output)
        self.assertRegex(output, r"keep +simulator .*run liveness unknown: .*--assume-dead-after")
        self.assertEqual(self.names(), live_names)  # Only the legacy finished run's fixture went.
        self.assertEqual(self.simctl.mutations(), [])
        stop()  # The runner is gone; the kernel released its lock.
        old = time.time() - 3 * 3600
        for path in [unknown, *unknown.rglob("*")]:
            os.utime(path, (old, old), follow_symlinks=False)
        self.assertEqual(self.prune("--assume-dead-after", "3600")[0], 2)
        code, output, _ = self.prune("--assume-dead-after", "7200", "--apply")
        self.assertEqual(code, 0)
        self.assertIn("native-suite-aaaaaaaaaa  dead: run-owner.lock is free", output)
        self.assertIn("native-suite-dddddddddd  assumed-dead: POLICY --assume-dead-after 7200: idle ", output)
        self.assertIn("not a liveness proof", output)
        self.assertEqual(self.names(), [])
        self.assertEqual(self.simctl.mutations(), [("delete", UDID)])

    def test_evidence_written_by_the_runner_maps_its_retained_fixture(self):
        run = self.run_folder("abababab08")
        original = WORKER.lease_native_ports
        with patch.object(WORKER, "lease_native_ports", side_effect=lambda worker, run_id:
                          original(worker, run_id, lock_root=self.root / "ports")), \
             patch.object(WORKER.zakura, "load_zakura_fixture_source",
                          return_value=BACKEND_FIXTURES.modeled_source()):
            worker = WORKER.prepare_native_worker_lifecycle(run / "repetition-0", run_id="9999999999", worker_id=3)
            session = worker.prepare_case(platform="rust", scenario_id="rust.receive.sync", case_index=1,
                                          activation_height=1, timeout=3)
            session.prepare_zakura_backend(grpcurl=Path("unused"), proto_dir=Path("unused"),
                                           miner_address="explicit-regtest-miner-model", timeout=3)
            worker.retain(timeout=3)
        fixture, namespace = session.backend._fixture, session.case.workspace.namespace
        self.assertEqual(fixture.labels["com.keplr.vizor.e2e.suite-run"], "abababab08")
        # No bind mount here: fixture-identity.json alone maps the network and volume.
        self.docker.fixture(fixture.run_id, labels=fixture.labels)
        code, output, _ = self.prune()
        self.assertEqual(code, 0)
        for name in (fixture.lwd_volume, fixture.network_name, fixture.node_name):
            self.assertRegex(output, rf"delete +\w+ +{name} .*native-suite-abababab08/{namespace}: run is dead")
        self.docker.objects.clear()
        self.docker.fixture(fixture.run_id, labels={**fixture.labels, "com.keplr.vizor.e2e.suite-run": "0000000000"})
        code, output, _ = self.prune("--apply")
        self.assertEqual(code, 0)
        self.assertRegex(output, rf"(?m)^unmapped +volume +{fixture.lwd_volume} .*Vizor labels disagree")
        self.assertEqual(self.docker.removals(), [])

    def test_non_harness_docker_resources_are_never_listed_or_touched(self):
        for honor in (True, False):
            with self.subTest(honor_filters=honor):
                self.docker = DockerModel(honor_filters=honor)
                self.docker.tsz()
                run = self.run_folder("e1e2e3e4e" + str(int(honor)))
                self.docker.fixture(FIXTURE, self.case(run, fixture=FIXTURE))
                code, output, _ = self.prune("--apply", "--run", run.name.removeprefix("native-suite-"))
                self.assertEqual(code, 0)
                self.assertNotIn("tsz", output)
                for receipt in (self.logs / "prune").glob("prune-*.json"):
                    self.assertNotIn("tsz", receipt.read_text())
                foreign = {"a" * 64, "tsz-codex-preview-chain", "tsz-codex-preview-lwd"}
                self.assertEqual({ident for _, ident in self.docker.objects}, foreign)
                self.assertFalse({call[-1] for call in self.docker.removals()} & foreign)
                # A filter-honoring daemon never even shows them to an inspect.
                self.assertEqual(any(call[-1] in foreign for call in self.docker.calls), not honor)
                shutil.rmtree(run)

    def test_unmapped_harness_resources_and_name_only_devices_are_reported_never_deleted(self):
        run = self.run_folder("f0f0f0f0f0")
        self.case(run)  # The namespace exists, but no marker or create log names a UUID.
        self.simctl.add(UDID, "Vizor E2E vizor_1111111111_w3_1", "Booted")
        self.docker.fixture(SECOND)
        outside = self.root / "other-checkout" / "case" / "zakura-backend" / "zakurad.toml"
        self.docker.fixture(FIXTURE, source=outside)
        code, output, _ = self.prune("--apply", "--folders", "--run", "f0f0f0f0f0")
        self.assertEqual(code, 0)
        self.assertRegex(output, r"(?m)^unmapped +simulator +Vizor E2E vizor_1111111111_w3_1 .*name-only match")
        self.assertRegex(output, r"(?m)^unmapped +volume +zakura-proof-7b1e0c9d2a3f-lwd-data .*no case evidence")
        self.assertRegex(output, r"(?m)^unmapped +container +zakura-proof-005a93ffd4a4-node .*outside this checkout")
        self.assertEqual(self.docker.removals(), [])
        self.assertEqual(self.simctl.mutations(), [])
        self.assertFalse(run.exists())  # Nothing maps to the run itself.

    def test_intent_create_log_maps_only_its_exact_uuid(self):
        run = self.run_folder("abababab01")
        case = self.case(run, device=UDID, intent_only=True)
        self.simctl.add(UDID, "Vizor E2E " + case.name)
        other = self.case(run, "4444444444", device=OTHER_UDID, intent_only=True)
        self.simctl.add("2C0FFEE0-0000-4000-8000-000000000002", "Vizor E2E " + other.name)
        code, output, _ = self.prune("--apply")
        self.assertEqual(code, 0)
        self.assertEqual(self.simctl.mutations(), [("delete", UDID)])
        self.assertRegex(output, r"(?m)^unmapped +simulator +Vizor E2E vizor_4444444444_w3_1 ")

    def test_resource_changed_after_inventory_is_skipped_and_keeps_its_folder(self):
        run, case, ids = self.dead_run_with_resources("abababab02", state="Shutdown")
        self.docker.drift[ids["node"]] = {"com.zakura.regtest-fixture.run": "f" * 32}
        code, output, _ = self.prune("--apply", "--folders", "--run", "abababab02")
        self.assertEqual(code, 0)
        self.assertNotIn(("container", "rm", "--force", ids["node"]), self.docker.removals())
        self.assertRegex(output, r"skipped +container +zakura-proof-005a93ffd4a4-node .*changed since inventory")
        self.assertRegex(output, r"kept +folder .*container zakura-proof-005a93ffd4a4-node was not removed")
        self.assertTrue(run.exists())

    def test_failed_deletion_keeps_its_folder_while_a_clean_dead_run_is_removed(self):
        failed, case, ids = self.dead_run_with_resources("abababab03", state="Shutdown")
        self.docker.failures.add(ids["lwd"])
        clean = self.run_folder("abababab04")
        self.case(clean, "5555555555")
        code, output, _ = self.prune("--apply", "--folders", "--run", "abababab03", "--run", "abababab04")
        self.assertEqual(code, 1)
        self.assertRegex(output, r"failed +container +zakura-proof-005a93ffd4a4-lwd .*removal failed")
        self.assertTrue(failed.exists())
        self.assertFalse(clean.exists())
        receipt = json.loads(next((self.logs / "prune").glob("prune-*.json")).read_text())
        self.assertFalse(receipt["complete"])

    def test_builds_are_stripped_without_touching_case_evidence_or_reports(self):
        run = self.run_folder("abababab05")
        case = self.case(run)
        producer = run / "builds" / "e2e" / "vizor_abababab05_w0_1"
        for path in (producer.parent, producer, producer / "funder-build"):
            path.mkdir(mode=0o700)
        (producer / "process-0000.log").write_text("log")
        (producer / "workspace-owner.json").write_text("{}")
        (producer / "funder-build" / "source.tar").write_bytes(b"s" * 2048)
        evidence = {path: path.read_bytes() for path in run.rglob("*") if path.is_file()
                    and not path.is_relative_to(producer / "funder-build")}
        (self.run_folder("abababab09") / "builds").rmdir()  # Nothing to strip is not a failure.
        code, output, _ = self.prune("--apply", "--builds")
        self.assertEqual(code, 0)
        self.assertRegex(output, r"stripped +builds .*removed 2\.0 KiB in 1 entries")
        self.assertNotRegex(output, r"builds +native-suite-abababab09")
        self.assertFalse((producer / "funder-build").exists())
        self.assertEqual({path: path.read_bytes() for path in evidence}, evidence)
        self.assertTrue(case.exists())

    def test_macos_namespaces_are_listed_only_and_keep_their_run_folder(self):
        run = self.run_folder("abababab06")
        case = self.case(run)
        support = self.home / RETENTION._MAC_E2E
        for namespace, workspace in ((case.name, str(case)), ("vizor_9999999999_w1_1", "/gone/checkout/case")):
            (support / namespace).mkdir(parents=True)
            (support / namespace / "mac-storage-owner.json").write_text(json.dumps({"workspace": workspace}))
        code, output, _ = self.prune("--apply", "--folders", "--run", "abababab06")
        self.assertEqual(code, 0)
        self.assertRegex(output, rf"list +macos +{case.name} .*listed only")
        self.assertRegex(output, r"(?m)^unmapped +macos +vizor_9999999999_w1_1 ")
        self.assertRegex(output, rf"keep +folder .*macos {case.name} still maps to it \(list\)")
        self.assertTrue(run.exists())
        self.assertTrue((support / case.name / "mac-storage-owner.json").exists())

    def test_prune_lock_serializes_apply_and_usage_errors_change_nothing(self):
        self.run_folder("abababab07")
        (self.logs / "prune").mkdir(mode=0o700)
        descriptor = os.open(self.logs / "prune" / "prune.lock", os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            code, _, errors = self.prune("--apply")
            self.assertEqual(code, 2)
            self.assertIn("another prune", errors)
            self.assertEqual(self.prune()[0], 0)
        finally:
            os.close(descriptor)
        before = self.snapshot()
        for arguments in (("--folders",), ("--run", "0123456789"), ("--run", "NOT-A-RUN"),
                          ("--keep-last", "-1"), ("--older-than", "soon"), ("--assume-dead-after", "60")):
            with self.subTest(arguments=arguments):
                self.assertEqual(self.prune(*arguments, "--apply")[0], 2)
        self.assertEqual(self.snapshot(), before)
        shutil.rmtree(self.logs)
        self.assertEqual(self.prune("--apply")[:2], (0, "No .regtest-logs in this checkout; nothing is retained.\n"))
        self.assertFalse(self.logs.exists())

    def test_fresh_cli_invocations_create_no_checkout_artifacts(self):
        scripts = self.root / "fresh" / "scripts" / "e2e"
        scripts.mkdir(parents=True)
        for name in ("native-prune.py", "native_retention.py", "native_owned_tree.py"):
            shutil.copyfile(SCRIPT_DIR / name, scripts / name)
        before = sorted(path.relative_to(self.root / "fresh") for path in (self.root / "fresh").rglob("*"))
        for arguments in ((), ("--apply",)):
            result = subprocess.run([sys.executable, str(scripts / "native-prune.py"), *arguments],
                                    capture_output=True, text=True, check=False, timeout=30)
            self.assertEqual((result.returncode, result.stdout),
                             (0, "No .regtest-logs in this checkout; nothing is retained.\n"), result.stderr)
        self.assertEqual(sorted(path.relative_to(self.root / "fresh") for path in (self.root / "fresh").rglob("*")),
                         before)


if __name__ == "__main__":
    unittest.main()
