"""Coordinator models; native signing, wallet assertions and Docker are not real."""
import contextlib
from dataclasses import replace
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_catalog
import native_macos_suite as SUITE

# Every selection requests this one signer build: all catalog Rust targets.
BUILT_TARGETS = tuple(dict.fromkeys(target for target, _ in SUITE.RUST_CASES.values()))


class SuiteTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="native-suite-model-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        (self.root/"bin/cache/dart-sdk/bin").mkdir(parents=True)
        for name in ("bin/flutter", "grpcurl", "bin/cache/dart-sdk/bin/dart"):
            tool = self.root/name
            tool.write_text("model-only")
            tool.chmod(0o700)
        self.args = SimpleNamespace(workers=2,repeat=2,build_jobs=4,order="short-first",timing_reports=[],
            flutter=self.root/"bin/flutter", grpcurl=self.root/"grpcurl",
            proto_dir=self.root)
        self.catalog = e2e_catalog.load_catalog()
        self.scenarios = (self.catalog.scenarios_by_id["flutter.macos.import-sync"],)
        self.helper = object()
        self.macos_build_proof = {"app_build_count":1, "helper_build_count":1}
        self.ios_build_proof = {"ios_app_build_count":1}
        self.signer = SimpleNamespace(identity=lambda: {"cargo_build_count":1, "cache_hit":False, "cache_key":"a"*64})
        self.voting = object()
        self.voting_build_proof = {"build_count": 1}
        self.barrier = threading.Barrier(2)
        self.observed = []
        self.fail = False
        self.on_build = None
        self.retained = []

    def git(self, command, **kwargs):
        if "runtimes" in command:
            return subprocess.CompletedProcess(command,0,json.dumps({"runtimes":[{
                "identifier":"model-runtime", "isAvailable":True,
                "supportedArchitectures":[SUITE.platform.machine()],
                "supportedDeviceTypes":[{"identifier":"model-device"}]}]}), "")
        return subprocess.CompletedProcess(command,0,"a"*40+"\n" if "rev-parse" in command else "","")

    def execute(self, root, run_id, worker_id, scenario, **kwargs):
        self.observed.append((root,run_id,worker_id,kwargs["helper"],kwargs["artifact"],kwargs["voting_artifact"]))
        self.barrier.wait(timeout=2)
        return {"scenario_id":scenario.id,"target":scenario.target,"test":scenario.test,
                "status":"failed" if self.fail and root.name == "repetition-0" else "passed"}

    def build_signer(self, producer, **kwargs):
        if self.on_build is not None:
            # Earlier invocations in one test already wrote their summaries.
            self.on_build(next(path for path in (self.root/".regtest-logs").glob("native-suite-*")
                               if not (path/"summary.json").exists()))
        return self.signer

    def model_producer(self, evidence):
        """Producer outputs as left by real builders: logs, markers, Cargo links, SDK modes."""
        case = evidence/"builds/e2e"/("vizor_"+evidence.name.removeprefix("native-suite-")+"_w0_1")
        for path in (case.parent, case):
            path.mkdir(mode=0o700)
        for name in ("process-0000.log", "workspace-owner.json", "case-manifest.json"):
            (case/name).write_text(name)
        target = case/"funder-build/target/debug"
        (target/"deps").mkdir(parents=True)
        (target/"deps/regtest_direct_funder-0a1b").write_bytes(b"f"*2048)
        os.link(target/"deps/regtest_direct_funder-0a1b", target/"regtest_direct_funder")
        (case/"funder-build/publication").mkdir()
        (case/"funder-build/publication/regtest_direct_funder").write_bytes(b"p"*1024)
        (case/"voting-build").mkdir()
        (case/"voting-build/build-proof.json").write_text("{}")
        (case/"native-publication/cohort.app").mkdir(parents=True)
        (case/"native-publication/cohort.app/MaterialIcons.otf").write_bytes(b"m"*512)
        (case/"native-publication/cohort.app/MaterialIcons.otf").chmod(0o664)
        return case

    def invoke(self):
        output = io.StringIO()
        self.errors = io.StringIO()
        with patch.object(SUITE.sys,"platform","darwin"), \
             patch.object(SUITE.subprocess,"run",side_effect=self.git), \
             patch.object(SUITE,"NativeCaseLifecycle",side_effect=lambda x:x), \
             patch.object(SUITE,"prepare_native_case_workspace",return_value=object()), \
             patch.object(SUITE,"build_native_macos_cohort",return_value=(self.helper,self.macos_build_proof)) as build, \
             patch.object(SUITE,"build_native_ios_cohort",return_value=(self.helper,self.ios_build_proof)) as ios_build, \
             patch.object(SUITE,"build_regtest_funder",side_effect=self.build_signer) as signer, \
             patch.object(SUITE,"build_voting_artifacts",return_value=(self.voting,self.voting_build_proof)) as voting, \
             patch.object(SUITE,"derive_payment_addresses",return_value={"desktop_transparent":"tm-public-sdk-model",
                 "receiver_tex":"texregtest1publicsdkmodel"}) as payment_addresses, \
             patch.object(SUITE,"derive_ios_migration_addresses", return_value={
                 "note_addresses":tuple("uregtest1model"+str(index) for index in range(500)),
                 "send_recipient":"uregtest1receivermodel"}) as ios_addresses, \
             patch.object(SUITE,"execute_case",side_effect=self.execute), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(self.errors):
            code = SUITE.run_native_suite(self.args,self.catalog,self.scenarios,
                {"kind":"scenario","values":[self.scenarios[0].id]},source_root=self.root)
        self.voting_builder = voting
        self.ios_builder = ios_build
        self.payment_address_deriver = payment_addresses
        self.ios_address_deriver = ios_addresses
        return code,json.loads(output.getvalue()),build,signer

    def test_two_concurrent_repetitions_share_only_one_build_and_signer(self):
        code,summary,build,signer = self.invoke()
        self.assertEqual(code,0)
        build.assert_called_once()
        signer.assert_called_once()
        self.voting_builder.assert_not_called()
        self.assertEqual(len({item[0] for item in self.observed}),2)
        self.assertEqual(len({item[1] for item in self.observed}),2)
        self.assertTrue(all(item[3] is self.helper and item[4] is self.signer for item in self.observed))
        for item in summary["repetition_reports"]:
            report = json.loads(Path(item["report"]).read_text())
            self.assertEqual(report["schema_version"],2)
            self.assertEqual(report["results"][0]["status"],"passed")
            with self.assertRaisesRegex(e2e_catalog.CatalogError,"zero scenarios"):
                e2e_catalog.select_scenarios(self.catalog,failed_from=Path(item["report"]))

    def test_short_dispatch_keeps_catalog_result_order_and_separate_budgets(self):
        self.args.workers, self.args.repeat = 1, 1
        self.scenarios = tuple(self.catalog.scenarios_by_id[name] for name in (
            "rust.receive.sync", "rust.send.basic", "flutter.macos.import-sync"))
        report = self.root/"timings.json"
        report.write_text(json.dumps({"schema_version":2,"catalog_sha256":self.catalog.fingerprint,
            "source_commit":"b" * 40,"results":[{
                "scenario_id":case.id,"profile":case.profile,"target":case.target,"test":case.test,
                "status":"passed","duration_seconds":duration,
            } for case,duration in zip(self.scenarios,(8,2,20))]}))
        self.args.timing_reports = [report]
        observed = []
        def execute(root, run_id, worker_id, case, **kwargs):
            observed.append((case.id,worker_id))
            return {"scenario_id":case.id,"target":case.target,"test":case.test,
                    "status":"passed","duration_seconds":1}
        self.execute = execute
        code,summary,_,_ = self.invoke()
        self.assertEqual(code,0)
        self.assertEqual(observed,[(self.scenarios[1].id,1),(self.scenarios[0].id,0),(self.scenarios[2].id,2)])
        final = json.loads(Path(summary["repetition_reports"][0]["report"]).read_text())
        self.assertEqual([case["scenario_id"] for case in final["results"]],[case.id for case in self.scenarios])
        self.assertEqual(summary["schedule"],final["schedule"])
        self.assertEqual(summary["resource_budget"],{
            "artifact_producer_slots":1,"cargo_jobs":4,"case_slots":1,"ios_preparation_slots":0})

    def test_ios_preparation_slots_have_a_separate_budget(self):
        self.args.workers, self.args.repeat = 4, 1
        self.args.ios_runtime, self.args.ios_device_type = "model-runtime", "model-device"
        self.scenarios = tuple(self.catalog.scenarios_by_id[name] for name in (
            "flutter.ios.create-sync", "flutter.ios.import-sync", "flutter.ios.fallback-endpoint",
            "flutter.ios.slow-height-fallback"))
        slots = []
        self.execute = lambda root, run_id, index, case, **kwargs: (
            slots.append(kwargs["ios_preparation_slots"]) or {"scenario_id":case.id,"status":"passed"})
        code, summary, _, _ = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(summary["resource_budget"]["case_slots"], 4)
        self.assertEqual(summary["resource_budget"]["ios_preparation_slots"], 2)
        self.assertTrue(all(item is slots[0] for item in slots))
        self.assertTrue(slots[0].acquire(blocking=False))
        self.assertTrue(slots[0].acquire(blocking=False))
        self.assertFalse(slots[0].acquire(blocking=False))
        slots[0].release()
        slots[0].release()

    def test_cancelled_preparation_wait_never_allocates_a_worker(self):
        cancel = threading.Event()
        slots = Mock()
        slots.acquire.side_effect = lambda **_: (cancel.set() or False)
        scenario = self.catalog.scenarios_by_id["flutter.ios.import-sync"]
        with patch.object(SUITE,"prepare_native_worker_lifecycle") as allocate:
            result = SUITE.execute_case(self.root,"a"*10,0,scenario,helper=self.helper,
                artifact=self.signer,source_root=self.root,dart=Path("/model/dart"),
                args=self.args,cancel=cancel,ios_preparation_slots=slots)
        self.assertEqual(result["status"],"cancelled")
        allocate.assert_not_called()
        slots.release.assert_not_called()

    def test_cancellation_after_acquisition_returns_only_its_slot(self):
        cancel = threading.Event()
        slots = Mock()
        slots.acquire.side_effect = lambda **_: (cancel.set() or True)
        with self.assertRaises(SUITE.runtime.Cancelled):
            SUITE._acquire_ios_preparation_slot(slots,cancel)
        slots.release.assert_called_once_with()

    def test_preparation_releases_before_backend_and_wallet_execution(self):
        self.args.ios_runtime, self.args.ios_device_type = "model-runtime", "model-device"
        slots = threading.BoundedSemaphore(1)
        scenario = self.catalog.scenarios_by_id["flutter.ios.import-sync"]
        session = SimpleNamespace(case=SimpleNamespace(workspace=SimpleNamespace(root=self.root)))
        def prepared(**kwargs):
            self.assertEqual(kwargs["timeout"],120)
            self.assertFalse(slots.acquire(blocking=False))
            return session
        def backend(**kwargs):
            self.assertTrue(slots.acquire(blocking=False))
            slots.release()
            raise RuntimeError("model stops before backend execution")
        session.prepare_zakura_backend = backend
        worker = SimpleNamespace(prepare_case=prepared,retain=Mock(),retained_resources=Mock(return_value=[]))
        with patch.object(SUITE,"prepare_native_worker_lifecycle",return_value=worker):
            result = SUITE.execute_case(self.root,"a"*10,0,scenario,helper=self.helper,
                artifact=self.signer,source_root=self.root,dart=Path("/model/dart"),
                args=self.args,cancel=threading.Event(),ios_preparation_slots=slots)
        self.assertEqual(result["error"],"model stops before backend execution")
        worker.retain.assert_called_once()
        # Diagnostic timings name the phase that stopped the case.
        self.assertEqual(result["failed_phase"],"backend_start")
        self.assertEqual(set(result["phase_seconds"]),{"ios_admission_wait","prepare_case","backend_start"})
        self.assertTrue(all(value >= 0 for value in result["phase_seconds"].values()))

    def test_failed_preparation_retains_before_freeing_slot_and_cancels_on_unproven_join(self):
        self.args.ios_runtime, self.args.ios_device_type = "model-runtime", "model-device"
        slots = threading.BoundedSemaphore(1)
        cancel = threading.Event()
        scenario = self.catalog.scenarios_by_id["flutter.ios.import-sync"]
        def retain(**kwargs):
            self.assertFalse(slots.acquire(blocking=False))
            raise RuntimeError("preparation writer join unproven")
        worker = SimpleNamespace(prepare_case=Mock(side_effect=RuntimeError("preparation failed")),retain=retain,
                                 retained_resources=Mock(return_value=[]))
        with patch.object(SUITE,"prepare_native_worker_lifecycle",return_value=worker) as allocate:
            result = SUITE.execute_case(self.root,"a"*10,0,scenario,helper=self.helper,
                artifact=self.signer,source_root=self.root,dart=Path("/model/dart"),
                args=self.args,cancel=cancel,ios_preparation_slots=slots)
            second = SUITE.execute_case(self.root,"a"*10,1,scenario,helper=self.helper,
                artifact=self.signer,source_root=self.root,dart=Path("/model/dart"),
                args=self.args,cancel=cancel,ios_preparation_slots=slots)
        self.assertEqual(result["cleanup_errors"],["preparation writer join unproven"])
        self.assertEqual(result["failed_phase"],"prepare_case")
        self.assertEqual(set(result["phase_seconds"]),{"ios_admission_wait","prepare_case"})
        self.assertEqual(second["status"],"cancelled")
        allocate.assert_called_once()
        self.assertTrue(cancel.is_set())
        self.assertTrue(slots.acquire(blocking=False))
        slots.release()

    def run_case(self, scenario_id, *, slots=None, cancel=None, retain=None, execute=None):
        """Drive one modeled case through execute_case; its executor is the given model."""
        self.args.ios_runtime, self.args.ios_device_type = "model-runtime", "model-device"
        session = SimpleNamespace(case=SimpleNamespace(workspace=SimpleNamespace(root=self.root)),
            backend=SimpleNamespace(mine=Mock(), closed=True), close=Mock(),
            prepare_zakura_backend=Mock(), prepare_zakura_front=Mock(), prepare_zakura_control=Mock())
        worker = SimpleNamespace(prepare_case=Mock(return_value=session), close=Mock(),
                                 retain=Mock(side_effect=retain), retained_resources=Mock(return_value=self.retained))
        executor = Mock(side_effect=execute, return_value={"assertions_passed":True})
        target = "execute_native_ios_case" if scenario_id.startswith("flutter.ios.") else "execute_native_macos_case"
        with patch.object(SUITE, "prepare_native_worker_lifecycle", return_value=worker), \
             patch.object(SUITE, target, executor):
            result = SUITE.execute_case(self.root, "a"*10, 0, self.catalog.scenarios_by_id[scenario_id],
                helper=self.helper, artifact=self.signer, source_root=self.root, dart=Path("/model/dart"),
                args=self.args, cancel=cancel or threading.Event(), ios_preparation_slots=slots)
        return result, executor, worker

    def test_first_ios_launch_holds_a_preparation_slot_until_its_vm_url(self):
        slots = threading.BoundedSemaphore(1)
        held = []
        def execute(session, **kwargs):
            held.append(not slots.acquire(blocking=False))  # Held by this case.
            kwargs["on_launch_ready"]()
            held.append(not slots.acquire(blocking=False))  # Free before the Driver.
            slots.release()
            kwargs["on_launch_ready"]()  # A repeated report is a no-op.
            return {"assertions_passed":True}
        result, executor, _ = self.run_case("flutter.ios.create-sync", slots=slots, execute=execute)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(held, [True, False])
        self.assertEqual(executor.call_args.kwargs["launch_timeout"], SUITE.IOS_LAUNCH_TIMEOUT_SECONDS)
        self.assertEqual(list(result["phase_seconds"]), ["ios_admission_wait", "prepare_case", "backend_start",
            "mine", "funding", "front_control", "ios_launch_admission_wait", "execute", "close"])
        self.assertTrue(slots.acquire(blocking=False))
        self.assertFalse(slots.acquire(blocking=False))
        slots.release()

    def test_configured_launch_timeout_reaches_the_ios_executor(self):
        self.args.ios_launch_timeout = 45.0
        result, executor, _ = self.run_case("flutter.ios.create-sync", slots=threading.BoundedSemaphore(1))
        self.assertEqual(result["status"], "passed")
        self.assertEqual(executor.call_args.kwargs["launch_timeout"], 45.0)

    def test_launch_deadline_expiry_times_out_execute_and_frees_the_slot_after_retention(self):
        slots = threading.BoundedSemaphore(1)
        def retain(**kwargs):
            self.assertFalse(slots.acquire(blocking=False))  # Still held while retaining.
        def execute(session, **kwargs):
            raise SUITE.runtime.RunnerError("iOS app did not publish its VM URL within the launch deadline", 124)
        result, _, worker = self.run_case("flutter.ios.create-sync", slots=slots, retain=retain, execute=execute)
        self.assertEqual((result["status"], result["failure_kind"], result["returncode"]), ("timed_out", "timeout", 124))
        self.assertEqual(result["failed_phase"], "execute")
        self.assertFalse(result["native_cleanup_proved"])
        worker.retain.assert_called_once_with(timeout=60)
        self.assertTrue(slots.acquire(blocking=False))
        slots.release()

    def test_unproven_launch_retention_holds_the_slot_then_cancels_queued_admissions(self):
        slots = threading.BoundedSemaphore(1)
        cancel = threading.Event()
        def retain(**kwargs):
            self.assertFalse(slots.acquire(blocking=False))
            raise RuntimeError("launch writer join unproven")
        def execute(session, **kwargs):
            raise SUITE.runtime.RunnerError("case app exited before its owned job was observed")
        result, _, _ = self.run_case("flutter.ios.create-sync", slots=slots, cancel=cancel,
                                     retain=retain, execute=execute)
        self.assertEqual(result["cleanup_errors"], ["launch writer join unproven"])
        self.assertTrue(cancel.is_set())
        self.assertTrue(slots.acquire(blocking=False))
        slots.release()

    def test_driver_failure_after_the_vm_url_does_not_release_the_slot_twice(self):
        slots = threading.BoundedSemaphore(1)
        def execute(session, **kwargs):
            kwargs["on_launch_ready"]()
            raise SUITE.runtime.RunnerError("original iOS Driver reported failing assertions")
        result, _, worker = self.run_case("flutter.ios.create-sync", slots=slots, execute=execute)
        self.assertEqual((result["status"], result["failed_phase"]), ("failed", "execute"))
        worker.retain.assert_called_once()
        # A second release would raise from the bounded semaphore in finally.
        self.assertTrue(slots.acquire(blocking=False))
        self.assertFalse(slots.acquire(blocking=False))
        slots.release()

    def test_cancelled_launch_admission_wait_releases_only_the_slot_it_acquired(self):
        cancel = threading.Event()
        slots = Mock()
        attempts = []
        def acquire(**kwargs):
            attempts.append(kwargs)
            if len(attempts) == 1:
                return True  # Preparation admission.
            cancel.set()
            return False  # Still queued for the first launch.
        slots.acquire.side_effect = acquire
        result, executor, worker = self.run_case("flutter.ios.create-sync", slots=slots, cancel=cancel)
        self.assertEqual((result["status"], result["failed_phase"]), ("cancelled", "ios_launch_admission_wait"))
        executor.assert_not_called()
        slots.release.assert_called_once_with()
        worker.retain.assert_called_once()

    def test_macos_case_phases_are_unchanged_by_ios_launch_admission(self):
        slots = Mock()
        result, executor, _ = self.run_case("flutter.macos.custom-endpoint-no-fallback", slots=slots)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(list(result["phase_seconds"]), ["prepare_case", "backend_start", "mine",
            "funding", "front_control", "execute", "close"])
        self.assertNotIn("launch_timeout", executor.call_args.kwargs)
        slots.acquire.assert_not_called()
        slots.release.assert_not_called()

    def test_ios_launch_timeout_is_validated_only_when_ios_is_selected(self):
        ios = (self.catalog.scenarios_by_id["flutter.ios.import-sync"],)
        self.args.ios_runtime, self.args.ios_device_type = "model-runtime", "model-device"
        with patch.object(SUITE.sys,"platform","darwin"), \
             patch.object(SUITE.subprocess,"run",side_effect=self.git):
            for value in (0, -1.0, 5, 29.9, float("nan"), float("inf"), 3601, True, "60"):
                self.args.ios_launch_timeout = value
                with self.subTest(value=value):
                    with self.assertRaisesRegex(ValueError, "ios-launch-timeout"):
                        SUITE.validate_options(self.args, ios)
                    SUITE.validate_options(self.args, self.scenarios)
            for value in (None, 30, 120, 3600):
                self.args.ios_launch_timeout = value
                SUITE.validate_options(self.args, ios)
        self.assertFalse((self.root/".regtest-logs").exists())

    def test_ios_summary_reports_its_launch_timeout(self):
        self.args.workers, self.args.repeat = 2, 1
        self.args.ios_runtime, self.args.ios_device_type = "model-runtime", "model-device"
        self.scenarios = (self.catalog.scenarios_by_id["flutter.ios.import-sync"],)
        self.execute = lambda root, run_id, index, case, **kwargs: {"scenario_id":case.id,"status":"passed"}
        _, summary, _, _ = self.invoke()
        self.assertEqual(summary["resource_budget"]["ios_launch_timeout_seconds"], SUITE.IOS_LAUNCH_TIMEOUT_SECONDS)
        self.args.ios_launch_timeout = 90.0
        _, summary, _, _ = self.invoke()
        self.assertEqual(summary["resource_budget"], {"artifact_producer_slots":1, "cargo_jobs":4,
            "case_slots":1, "ios_preparation_slots":1, "ios_launch_timeout_seconds":90.0})

    def test_invalid_timing_input_is_rejected_before_resources_or_builds(self):
        self.args.timing_reports = [self.root/"missing.json"]
        with patch.object(SUITE.sys,"platform","darwin"):
            with self.assertRaises(OSError):
                SUITE.run_native_suite(self.args,self.catalog,self.scenarios,{},source_root=self.root)
        self.assertFalse((self.root/".regtest-logs").exists())

    def test_unproven_retention_cancels_following_case_before_allocation(self):
        cancel = threading.Event()
        worker = SimpleNamespace(prepare_case=Mock(side_effect=RuntimeError("case failed")),
                                 retain=Mock(side_effect=RuntimeError("writer join unproven")),
                                 retained_resources=Mock(return_value=[]))
        with patch.object(SUITE,"prepare_native_worker_lifecycle",return_value=worker) as allocate:
            first = SUITE.execute_case(self.root,"a" * 10,0,self.scenarios[0],helper=self.helper,
                artifact=self.signer,source_root=self.root,dart=Path("/model/dart"),args=self.args,cancel=cancel)
            second = SUITE.execute_case(self.root,"a" * 10,1,self.scenarios[0],helper=self.helper,
                artifact=self.signer,source_root=self.root,dart=Path("/model/dart"),args=self.args,cancel=cancel)
        self.assertEqual(first["status"],"failed")
        self.assertEqual(first["cleanup_errors"],["writer join unproven"])
        self.assertEqual(second["status"],"cancelled")
        allocate.assert_called_once()

    def test_cache_hit_reports_zero_builds_without_changing_case_execution(self):
        self.signer = SimpleNamespace(identity=lambda: {
            "cargo_build_count":0, "cache_hit":True, "cache_key":"b"*64})
        self.scenarios = (self.catalog.scenarios_by_id["rust.receive.sync"],)
        code, summary, app, signer = self.invoke()
        self.assertEqual(code, 0)
        app.assert_not_called()
        signer.assert_called_once()
        self.assertEqual(summary["builds"]["signer_build_count"], 0)
        self.assertEqual(summary["builds"]["rust_build_count"], 0)
        self.assertTrue(summary["builds"]["signer_cache_hit"])
        self.assertEqual(summary["builds"]["signer_cache_key"], "b"*64)
        self.assertEqual(len(self.observed), 2)
        self.assertTrue(all(item[4] is self.signer for item in self.observed))
        self.assertTrue(signer.call_args.kwargs["cache_root"].is_relative_to(self.root/".regtest-logs/build-cache"))

    def test_native_cache_hit_keeps_fresh_repetitions_and_reports_zero_app_helper_builds(self):
        self.macos_build_proof = {"app_build_count":0, "helper_build_count":0, "cache_hit":True}
        code,summary,build,_ = self.invoke()
        self.assertEqual(code,0)
        self.assertEqual(summary["builds"]["app_build_count"],0)
        self.assertEqual(summary["builds"]["helper_build_count"],0)
        self.assertTrue(summary["builds"]["cache_hit"])
        self.assertEqual(len({item[1] for item in self.observed}),2)
        self.assertTrue(build.call_args.kwargs["cache_root"].is_relative_to(self.root/".regtest-logs/build-cache"))

    def test_ios_cache_hit_reports_zero_builds_and_keeps_new_cases(self):
        self.scenarios = (self.catalog.scenarios_by_id["flutter.ios.import-sync"],)
        self.args.ios_runtime,self.args.ios_device_type = "model-runtime","model-device"
        self.ios_build_proof = {"ios_app_build_count":0, "cache_hit":True}
        code,summary,build,_ = self.invoke()
        self.assertEqual(code,0)
        build.assert_not_called()
        self.assertEqual(summary["builds"]["ios"],{"ios_app_build_count":0, "cache_hit":True})
        self.assertEqual(len({item[1] for item in self.observed}),2)
        # Single-app entries use a new root; older pair entries are never read.
        self.assertEqual(self.ios_builder.call_args.kwargs["cache_root"],
                         self.root/".regtest-logs/build-cache/ios-cohort-v2")

    def test_ios_repetitions_build_one_cohort_and_do_not_build_macos(self):
        self.scenarios = (self.catalog.scenarios_by_id["flutter.ios.import-sync"],)
        self.args.ios_runtime, self.args.ios_device_type = "model-runtime", "model-device"
        code, summary, mac_build, signer = self.invoke()
        self.assertEqual(code, 0)
        mac_build.assert_not_called()
        self.ios_builder.assert_called_once()
        signer.assert_called_once()
        self.assertEqual(summary["builds"]["ios"]["ios_app_build_count"], 1)

    def test_ios_unavailable_selection_is_rejected_before_run_writes(self):
        self.args.ios_runtime, self.args.ios_device_type = "other-runtime", "model-device"
        with patch.object(SUITE.sys,"platform","darwin"), \
             patch.object(SUITE.subprocess,"run",side_effect=self.git):
            with self.assertRaisesRegex(ValueError,"not available"):
                SUITE.validate_options(self.args,(self.catalog.scenarios_by_id["flutter.ios.import-sync"],))
        self.assertFalse((self.root/".regtest-logs").exists())

    def test_ios_migration_group_derives_maximum_dataset_once_and_shares_one_build(self):
        self.scenarios = tuple(self.catalog.scenarios_by_id[name] for name in (
            "flutter.ios.ironwood-pre-migration-send", "flutter.ios.ironwood-migration-500-notes"))
        self.args.ios_runtime, self.args.ios_device_type = "model-runtime", "model-device"
        code, summary, mac_build, signer = self.invoke()
        self.assertEqual(code, 0)
        mac_build.assert_not_called()
        signer.assert_called_once()
        self.assertTrue(signer.call_args.kwargs["wallet_addresses"])
        self.ios_builder.assert_called_once()
        self.ios_address_deriver.assert_called_once()
        self.assertEqual(self.ios_address_deriver.call_args.args[2], self.scenarios)
        self.assertEqual(summary["builds"]["ios_note_address_count"], 500)

    def test_mobile_migration_profile_mismatch_is_rejected_before_build_or_run_writes(self):
        self.args.ios_runtime, self.args.ios_device_type = "model-runtime", "model-device"
        migration = self.catalog.scenarios_by_id["flutter.ios.ironwood-migration"]
        with patch.object(SUITE.sys,"platform","darwin"), \
             patch.object(SUITE.subprocess,"run",side_effect=self.git):
            with self.assertRaisesRegex(ValueError, "profile does not match"):
                SUITE.validate_options(self.args, (replace(migration, profile="flutter-direct-height1"),))
        self.assertFalse((self.root/".regtest-logs").exists())

    def test_fully_passing_run_removes_only_producer_intermediates(self):
        produced = []
        self.on_build = lambda evidence: produced.append(self.model_producer(evidence))
        code, summary, _, _ = self.invoke()
        self.assertEqual(code, 0)
        case = produced[0]
        self.assertEqual(sorted(item.relative_to(case).as_posix() for item in case.rglob("*")), [
            "case-manifest.json", "process-0000.log", "voting-build", "voting-build/build-proof.json",
            "workspace-owner.json"])
        builds = case.parent.parent
        record = json.loads((builds/"build-prune.json").read_text())
        prefix = "e2e/"+case.name+"/"
        self.assertEqual(record, {"schema_version":1, "run_id":summary["run_id"], "trigger":"passed-run",
            "removed":[prefix+"funder-build", prefix+"native-publication"], "bytes":2048+1024+512, "errors":[]})
        self.assertEqual(stat.S_IMODE((builds/"build-prune.json").stat().st_mode), 0o400)
        self.assertIn("Removed passing-run build intermediates: 3.5 KiB in 2 entries", self.errors.getvalue())
        # Reports were written before the sweep and are never rewritten by it.
        self.assertEqual(json.loads((builds.parent/"summary.json").read_text()), summary)

    def test_failed_interrupted_or_errored_runs_keep_every_producer_output(self):
        def interrupted(root, run_id, worker_id, scenario, **kwargs):
            signal.getsignal(signal.SIGINT)(signal.SIGINT, None)
            return {"scenario_id":scenario.id, "status":"passed"}
        def coordinator_error(root, run_id, worker_id, scenario, **kwargs):
            raise RuntimeError("model coordinator failure")
        original = self.execute
        for name, execute, fail in (("failed", original, True), ("interrupted", interrupted, False),
                                    ("report-error", coordinator_error, False)):
            with self.subTest(name):
                produced = []
                self.on_build = lambda evidence: produced.append(self.model_producer(evidence))
                self.execute, self.fail, self.barrier = execute, fail, threading.Barrier(2)
                code, summary, _, _ = self.invoke()
                self.assertEqual(code, 0 if name == "interrupted" else 1)
                self.assertEqual(summary["error"], "model coordinator failure" if name == "report-error" else None)
                case = produced[0]
                for path in ("funder-build/target/debug/regtest_direct_funder", "funder-build/publication",
                             "native-publication/cohort.app/MaterialIcons.otf", "voting-build/build-proof.json"):
                    self.assertTrue((case/path).exists(), path)
                self.assertFalse((case.parent.parent/"build-prune.json").exists())
                self.assertNotIn("build intermediates", self.errors.getvalue())

    def test_run_owner_lock_is_held_for_the_whole_run_and_released_after(self):
        held = []
        def execute(root, run_id, worker_id, scenario, **kwargs):
            # Another open file description conflicts with the runner's flock.
            descriptor = os.open(root.parent/"run-owner.lock", os.O_RDONLY|os.O_NOFOLLOW)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX|fcntl.LOCK_NB)
                held.append(False)
            except BlockingIOError:
                held.append(True)
            finally:
                os.close(descriptor)
            return {"scenario_id":scenario.id, "status":"passed"}
        self.execute = execute
        code, summary, _, _ = self.invoke()
        self.assertEqual((code, held), (0, [True, True]))
        evidence = self.root/".regtest-logs"/("native-suite-"+summary["run_id"])
        self.assertEqual(stat.S_IMODE((evidence/"run-owner.lock").stat().st_mode), 0o600)
        owner = json.loads((evidence/"run-owner.json").read_text())
        self.assertEqual({key: owner[key] for key in ("schema_version", "run_id", "pid", "checkout")},
                         {"schema_version":1, "run_id":summary["run_id"], "pid":os.getpid(), "checkout":str(self.root)})
        self.assertTrue(owner["started_at"].endswith("Z") and owner["host"])
        probe = ("import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDONLY)\n"
                 "try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)\n"
                 "except BlockingIOError: sys.exit(23)\n")
        self.assertEqual(subprocess.run([sys.executable, "-c", probe, str(evidence/"run-owner.lock")],
                                        timeout=5).returncode, 0)

    def test_sighup_cancels_like_sigint_unless_nohup_ignores_it(self):
        observed = []
        def execute(root, run_id, worker_id, scenario, **kwargs):
            handler = signal.getsignal(signal.SIGHUP)
            observed.append(handler)
            if callable(handler):
                handler(signal.SIGHUP, None)
            return {"scenario_id":scenario.id, "status":"passed"}
        self.execute = execute
        original = signal.signal(signal.SIGHUP, signal.SIG_DFL)
        try:
            for inherited in (signal.SIG_DFL, signal.SIG_IGN):
                with self.subTest(inherited=inherited):
                    signal.signal(signal.SIGHUP, inherited)
                    observed.clear()
                    code, summary, _, _ = self.invoke()
                    self.assertEqual(code, 0)
                    self.assertEqual(callable(observed[0]), inherited == signal.SIG_DFL)
                    self.assertEqual(signal.getsignal(signal.SIGHUP), inherited)
                    builds = self.root/".regtest-logs"/("native-suite-"+summary["run_id"])/"builds"
                    # A cancelled run is interrupted, so it keeps every build output.
                    self.assertEqual((builds/"build-prune.json").exists(), inherited == signal.SIG_IGN)
        finally:
            signal.signal(signal.SIGHUP, original)

    def test_failed_case_reports_retained_resources_through_the_worker(self):
        self.retained = [{"namespace":"vizor_aaaaaaaaaa_w0_1", "evidence":"/model/case", "workspace":"/model/w",
            "docker":{"fixture_run_id":"a"*32, "stopped":True, "identity":None}, "simulator":None,
            "macos_support":"/model/support", "port_locks_held":False}]
        def execute(session, **kwargs):
            raise SUITE.runtime.RunnerError("original Driver reported failing assertions")
        failed, _, worker = self.run_case("flutter.macos.custom-endpoint-no-fallback", execute=execute)
        self.assertEqual(failed["retained"], self.retained)
        worker.retained_resources.assert_called_once_with()
        passed, _, worker = self.run_case("flutter.macos.custom-endpoint-no-fallback")
        self.assertNotIn("retained", passed)
        worker.retained_resources.assert_not_called()

    def test_summary_totals_and_one_stderr_line_report_retained_state(self):
        def execute(root, run_id, worker_id, scenario, **kwargs):
            namespace = "vizor_"+run_id+"_w0_1"
            return {"scenario_id":scenario.id, "status":"failed", "retained":[{"namespace":namespace,
                "docker":{"fixture_run_id":"b"*32}, "simulator":None, "macos_support":"/model/"+namespace}]}
        self.execute = execute
        code, summary, _, _ = self.invoke()
        self.assertEqual(code, 1)
        totals = summary["retained"]
        self.assertEqual({key: totals[key] for key in ("cases", "docker_fixtures", "simulators", "macos_namespaces")},
                         {"cases":2, "docker_fixtures":2, "simulators":0, "macos_namespaces":2})
        self.assertEqual(len(totals["namespaces"]), 2)
        lines = [line for line in self.errors.getvalue().splitlines() if line.startswith("Retained by ")]
        self.assertEqual(len(lines), 1)
        self.assertIn("native-suite-"+summary["run_id"]+": 2 failed case(s) (", lines[0])
        self.assertIn("2 Docker fixture(s), 0 Simulator(s), 2 macOS namespace(s); evidence ", lines[0])
        self.assertTrue(lines[0].endswith("; list: python3 scripts/e2e/native-prune.py --run "+summary["run_id"]))
        self.execute = lambda root, run_id, worker_id, scenario, **kwargs: {"scenario_id":scenario.id, "status":"passed"}
        code, summary, _, _ = self.invoke()
        self.assertEqual(summary["retained"], {"cases":0, "namespaces":[], "docker_fixtures":0,
                                               "simulators":0, "macos_namespaces":0})
        self.assertIn("Retained by native-suite-"+summary["run_id"]+": none\n", self.errors.getvalue())

    def test_a_failed_repetition_remains_rerunnable_and_makes_the_batch_fail(self):
        self.fail = True
        code,summary,_,_ = self.invoke()
        self.assertEqual(code,1)
        failed = next(item for item in summary["repetition_reports"] if item["failed"])
        selected = e2e_catalog.select_scenarios(self.catalog,failed_from=Path(failed["report"]))
        self.assertEqual(tuple(s.id for s in selected),("flutter.macos.import-sync",))

    def test_options_refuse_pending_cases_and_missing_tools_before_writes(self):
        with patch.object(SUITE.sys,"platform","darwin"):
            with self.assertRaises(ValueError):
                SUITE.validate_options(self.args,(self.catalog.scenarios_by_id["flutter.ios.import-sync"],))
            self.args.flutter = None
            with self.assertRaises(ValueError):
                SUITE.validate_options(self.args,self.scenarios)
        self.assertFalse((self.root/".regtest-logs").exists())

    def test_invalid_cache_environment_names_are_rejected_before_writes(self):
        for value in ("1MODEL", "MODEL-NAME", "MODEL_*"):
            with self.subTest(value=value), patch.dict(SUITE.os.environ, {"VIZOR_E2E_CACHE_ENV":value}), \
                 patch.object(SUITE.sys,"platform","darwin"):
                with self.assertRaisesRegex(ValueError,"VIZOR_E2E_CACHE_ENV"):
                    SUITE.validate_options(self.args,self.scenarios)
                with self.assertRaisesRegex(ValueError,"VIZOR_E2E_CACHE_ENV"):
                    SUITE.run_native_suite(self.args,self.catalog,self.scenarios,{},source_root=self.root)
        self.assertFalse((self.root/".regtest-logs").exists())

    def test_summary_names_the_build_environment_without_values_or_digests(self):
        secret = "model-secret-value"
        with patch.dict(SUITE.os.environ, {"VIZOR_MODEL_X_TOKEN":secret, "OLDPWD":"/model/previous",
                                           "VIZOR_E2E_CACHE_ENV":"OTHER_SWIFT_FLAGS", "OTHER_SWIFT_FLAGS":"-DMODEL"}):
            code, summary, _, _ = self.invoke()
        self.assertEqual(code, 0)
        environment = summary["build_environment"]
        self.assertEqual(set(environment), {"hashed_names", "excluded_names", "requested_extra_names"})
        self.assertLessEqual({"VIZOR_MODEL_X_TOKEN", "OLDPWD"}, set(environment["excluded_names"]))
        self.assertLessEqual({"OTHER_SWIFT_FLAGS", "VIZOR_E2E_CACHE_ENV"}, set(environment["hashed_names"]))
        self.assertEqual(environment["requested_extra_names"], ["OTHER_SWIFT_FLAGS"])
        text = json.dumps(summary)
        for value in (secret, "/model/previous", hashlib.sha256(secret.encode()).hexdigest(),
                      hashlib.sha256(b"-DMODEL").hexdigest()):
            self.assertNotIn(value, text)
        written = json.loads(next((self.root/".regtest-logs").glob("native-suite-*/summary.json")).read_text())
        self.assertEqual(written["build_environment"], environment)

    def test_rust_cases_reuse_the_full_signer_build_without_an_app_or_helper(self):
        self.scenarios = tuple(self.catalog.scenarios_by_id[name] for name in (
            "rust.receive.sync", "rust.send.basic", "rust.import.bip39-passphrase"))
        code, summary, app, signer = self.invoke()
        self.assertEqual(code, 0)
        app.assert_not_called()
        self.payment_address_deriver.assert_not_called()
        signer.assert_called_once()
        self.assertEqual(signer.call_args.kwargs["test_targets"], BUILT_TARGETS)
        self.assertEqual(summary["builds"]["rust_test_targets"],
                         ["regtest_receive_sync", "regtest_send", "regtest_import"])
        self.assertEqual(summary["builds"]["rust_built_test_targets"], list(BUILT_TARGETS))
        self.assertEqual(summary["builds"]["rust_build_count"], 1)
        self.assertTrue(all(item[3] is None for item in self.observed))

    def test_ironwood_group_reports_two_selected_targets_and_rejects_wrong_profile(self):
        self.scenarios = tuple(self.catalog.scenarios_by_id[name] for name in (
            "rust.ironwood.migration", "rust.ironwood.gift-card-claim"))
        code, summary, app, signer = self.invoke()
        self.assertEqual(code, 0)
        app.assert_not_called()
        self.assertEqual(signer.call_args.kwargs["test_targets"], BUILT_TARGETS)
        self.assertEqual(summary["builds"]["rust_test_targets"],
                         ["ironwood_regtest_migration", "ironwood_regtest_gift_card_claim"])
        self.assertEqual(summary["builds"]["rust_build_count"], 1)
        with patch.object(SUITE.sys, "platform", "darwin"):
            with self.assertRaises(ValueError):
                SUITE.validate_options(self.args, (replace(self.scenarios[0], profile="zakura-direct-height1"),))

    def test_multi_account_selection_reuses_the_full_signer_without_native_builds(self):
        self.scenarios = tuple(s for s in self.catalog.scenarios if s.target == "regtest_multi_account")
        self.assertEqual(len(self.scenarios), 8)
        code, summary, app, signer = self.invoke()
        self.assertEqual(code, 0)
        app.assert_not_called()
        signer.assert_called_once()
        self.assertEqual(signer.call_args.kwargs["test_targets"], BUILT_TARGETS)
        self.assertEqual(summary["builds"]["rust_test_targets"], ["regtest_multi_account"])
        self.assertEqual(summary["builds"]["rust_build_count"], 1)
        self.assertTrue(all(item[3] is None for item in self.observed))

    def test_mixed_engine_selection_shares_the_signer_and_worker_budget(self):
        self.scenarios += (self.catalog.scenarios_by_id["rust.receive.sync"],)
        code, summary, app, signer = self.invoke()
        self.assertEqual(code, 0)
        app.assert_called_once()
        signer.assert_called_once()
        self.assertEqual(signer.call_args.kwargs["test_targets"], BUILT_TARGETS)
        self.assertEqual(summary["builds"]["rust_test_targets"], ["regtest_receive_sync"])

    def test_any_selection_requests_the_same_full_signer_build(self):
        self.args.ios_runtime, self.args.ios_device_type = "model-runtime", "model-device"
        self.args.voting_sdk_cache = self.args.voting_pir_cache = self.root
        self.execute = lambda root, run_id, index, case, **kwargs: {"scenario_id":case.id,"status":"passed"}
        requests = set()
        for names in (("rust.receive.sync",), ("rust.ironwood.migration", "rust.send.basic"),
                      ("flutter.macos.import-sync",), ("flutter.ios.import-sync",), ("flutter.macos.voting",)):
            with self.subTest(selection=names):
                self.scenarios = tuple(self.catalog.scenarios_by_id[name] for name in names)
                code, summary, _, signer = self.invoke()
                self.assertEqual(code, 0)
                requests.add((signer.call_args.kwargs["test_targets"], signer.call_args.kwargs["wallet_addresses"]))
                self.assertEqual(summary["builds"]["rust_built_test_targets"], list(BUILT_TARGETS))
        self.assertEqual(requests, {(BUILT_TARGETS, True)})
        self.assertEqual(set(BUILT_TARGETS), {s.target for s in self.catalog.scenarios if s.engine == "rust"})

    def test_non_payment_macos_selection_compiles_the_same_tex_fixture(self):
        tex_addresses = []
        for name in ("flutter.macos.import-sync", "flutter.macos.tex-send"):
            with self.subTest(scenario=name):
                self.scenarios = (self.catalog.scenarios_by_id[name],)
                code, summary, app, signer = self.invoke()
                self.assertEqual(code, 0)
                self.payment_address_deriver.assert_called_once()
                self.assertTrue(signer.call_args.kwargs["wallet_addresses"])
                tex_addresses.append(app.call_args.kwargs["tex_address"])
                self.assertEqual(summary["builds"]["rust_test_targets"], [])
        self.assertEqual(tex_addresses, ["texregtest1publicsdkmodel"]*2)

    def test_build_failure_never_creates_a_passing_empty_batch(self):
        with patch.object(SUITE.sys,"platform","darwin"), \
             patch.object(SUITE.subprocess,"run",side_effect=self.git), \
             patch.object(SUITE,"NativeCaseLifecycle",side_effect=lambda x:x), \
             patch.object(SUITE,"prepare_native_case_workspace",return_value=object()), \
             patch.object(SUITE,"build_regtest_funder",return_value=self.signer), \
             patch.object(SUITE,"derive_payment_addresses",return_value={"desktop_transparent":"tm-public-sdk-model",
                 "receiver_tex":"texregtest1publicsdkmodel"}), \
             patch.object(SUITE,"build_native_macos_cohort",side_effect=RuntimeError("compiler failed")), \
             contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = SUITE.run_native_suite(self.args,self.catalog,self.scenarios,{},source_root=self.root)
        self.assertEqual(code,1)
        summary = json.loads(next((self.root/".regtest-logs").glob("native-suite-*/summary.json")).read_text())
        self.assertEqual(summary["error"],"compiler failed")
        self.assertEqual(summary["repetition_reports"],[])

    def test_endpoint_cases_are_supported_without_enabling_other_domains(self):
        scenarios = tuple(self.catalog.scenarios_by_id[name] for name in (
            "flutter.macos.fallback-endpoint", "flutter.macos.custom-endpoint-no-fallback",
            "flutter.macos.slow-height-fallback", "flutter.macos.sync-startup-stall-recovery"))
        with patch.object(SUITE.sys, "platform", "darwin"):
            SUITE.validate_options(self.args, scenarios)
        self.assertNotIn("flutter.macos.send", SUITE.SUPPORTED_SCENARIOS)

    def test_import_keeps_both_exact_balances_and_independent_sources(self):
        self.assertEqual(SUITE.scenario_funding("flutter.macos.import-sync"), (
            (SUITE._IMPORT_UA, 125000000, "ironwood", 1),
            (SUITE._IMPORT_TRANSPARENT, 75000000, "transparent", 2),
        ))

    def test_mempool_cases_are_publicly_runnable_without_host_prefunding(self):
        scenarios = tuple(self.catalog.scenarios_by_id[name] for name in (
            "flutter.macos.mempool-receive-history", "flutter.macos.mempool-during-sync",
            "flutter.macos.mempool-expiry"))
        with patch.object(SUITE.sys, "platform", "darwin"):
            SUITE.validate_options(self.args, scenarios)
        for scenario in scenarios:
            self.assertEqual(SUITE.scenario_funding(scenario.id), ())
            self.assertTrue(scenario.supported)
        self.assertTrue(e2e_catalog.plan(self.catalog, scenarios).runnable)

    def test_gift_cases_are_publicly_runnable_with_exact_funding(self):
        scenarios = tuple(self.catalog.scenarios_by_id[name] for name in (
            "flutter.macos.payment-link-round-trip", "flutter.macos.payment-link-restart",
            "flutter.macos.payment-link-recovery"))
        with patch.object(SUITE.sys, "platform", "darwin"):
            SUITE.validate_options(self.args, scenarios)
        for scenario in scenarios:
            self.assertEqual(SUITE.scenario_funding(scenario.id), (
                (SUITE._DESKTOP_UA,125000000,"ironwood",1),))
            self.assertTrue(scenario.supported)
        self.assertTrue(e2e_catalog.plan(self.catalog, scenarios).runnable)

    def test_voting_repetitions_share_one_producer_and_exact_preactivation_funding(self):
        self.scenarios = tuple(self.catalog.scenarios_by_id[name] for name in sorted(SUITE.VOTING_SCENARIOS))
        self.args.voting_sdk_cache = self.args.voting_pir_cache = self.root
        code, summary, app, signer = self.invoke()
        self.assertEqual(code, 0)
        self.voting_builder.assert_called_once()
        app.assert_called_once()
        signer.assert_called_once()
        self.assertEqual(summary["builds"]["voting_build_count"], 1)
        self.assertTrue(all(item[5] is self.voting for item in self.observed))
        for scenario in self.scenarios:
            self.assertEqual(SUITE.scenario_funding(scenario.id), (
                (SUITE._DESKTOP_UA,13000000,"orchard",1),))
            # Existing phase deadlines remain 15+45 minutes; service/restart
            # allowance is additional, not a shorter whole-case override.
            self.assertGreaterEqual(scenario.timeout_seconds, 15*60+45*60+15*60)

    def test_voting_requires_both_source_caches_and_activation500_before_writes(self):
        scenario = self.catalog.scenarios_by_id["flutter.macos.voting"]
        with patch.object(SUITE.sys, "platform", "darwin"):
            with self.assertRaisesRegex(ValueError, "voting-sdk-cache"):
                SUITE.validate_options(self.args, (scenario,))
            self.args.voting_sdk_cache = self.root
            with self.assertRaisesRegex(ValueError, "voting-pir-cache"):
                SUITE.validate_options(self.args, (scenario,))
            self.args.voting_pir_cache = self.root
            with self.assertRaisesRegex(ValueError, "preactivation"):
                SUITE.validate_options(self.args, (replace(scenario, profile="flutter-direct-height1"),))
        self.assertFalse((self.root/".regtest-logs").exists())

    def test_warm_voting_cache_reports_zero_builds_and_keeps_cases_isolated(self):
        self.scenarios = tuple(self.catalog.scenarios_by_id[name] for name in sorted(SUITE.VOTING_SCENARIOS))
        self.args.voting_sdk_cache = self.args.voting_pir_cache = self.root
        self.voting_build_proof = {"build_count": 0, "cache_hit": True, "cache_key": "b"*64}
        code, summary, _, _ = self.invoke()
        self.assertEqual(code, 0)
        self.voting_builder.assert_called_once()
        self.assertEqual(self.voting_builder.call_args.kwargs["cache_root"],
                         self.root/".regtest-logs/build-cache/voting-v1")
        self.assertEqual(summary["builds"]["voting_build_count"], 0)
        self.assertEqual(summary["builds"]["voting_proof"], self.voting_build_proof)
        self.assertEqual(len(self.observed), len(self.scenarios)*self.args.repeat)
        self.assertEqual(len({item[0] for item in self.observed}), self.args.repeat)
        self.assertTrue(all(item[5] is self.voting for item in self.observed))

    def test_payment_group_keeps_exact_balances_and_independent_funding_sources(self):
        names = ("flutter.macos.shield-transparent", "flutter.macos.shield-transparent-retry",
            "flutter.macos.multi-account-send", "flutter.macos.tex-send", "flutter.macos.payment-uri-send",
            "flutter.macos.payment-uri-locked-send", "flutter.macos.payment-request-round-trip")
        with patch.object(SUITE.sys, "platform", "darwin"):
            SUITE.validate_options(self.args, tuple(self.catalog.scenarios_by_id[name] for name in names))
        self.assertEqual(SUITE.scenario_funding(names[0]), ())
        self.assertEqual(SUITE.scenario_funding(names[1]), ())
        with self.assertRaises(ValueError):
            SUITE.scenario_funding(names[2])
        self.assertEqual(SUITE.scenario_funding(names[2], desktop_transparent="tm-public-sdk-model"), (
            (SUITE._DESKTOP_UA,125000000,"ironwood",1),
            ("tm-public-sdk-model",75000000,"transparent",2)))
        for name in names[3:]:
            self.assertEqual(SUITE.scenario_funding(name), ((SUITE._DESKTOP_UA,125000000,"ironwood",1),))

    def test_payment_selection_derives_addresses_before_the_one_common_app_build(self):
        self.scenarios = tuple(self.catalog.scenarios_by_id[name] for name in (
            "flutter.macos.multi-account-send", "flutter.macos.tex-send"))
        code, summary, app, signer = self.invoke()
        self.assertEqual(code, 0)
        signer.assert_called_once()
        self.assertTrue(signer.call_args.kwargs["wallet_addresses"])
        app.assert_called_once()
        self.assertEqual(app.call_args.kwargs["tex_address"], "texregtest1publicsdkmodel")
        self.assertEqual(summary["builds"]["payment_addresses"]["desktop_transparent"], "tm-public-sdk-model")

    def test_fallback_cases_fund_the_existing_desktop_fixture_only(self):
        for name in ("flutter.macos.fallback-endpoint", "flutter.macos.slow-height-fallback"):
            with self.subTest(scenario=name):
                self.assertEqual(SUITE.scenario_funding(name), (
                    (SUITE._DESKTOP_UA, 125000000, "ironwood", 1),
                ))

    def test_unreachable_endpoint_and_startup_recovery_need_no_payment(self):
        for name in ("flutter.macos.custom-endpoint-no-fallback", "flutter.macos.sync-startup-stall-recovery"):
            self.assertEqual(SUITE.scenario_funding(name), ())
        with self.assertRaises(ValueError):
            SUITE.scenario_funding("flutter.macos.send")


if __name__ == "__main__":
    unittest.main()
