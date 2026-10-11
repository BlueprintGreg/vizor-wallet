"""Inventory, map and prune retained native E2E resources of dead runs.

Scope is this checkout's .regtest-logs runs plus the Docker resources and
Simulators that exact case evidence maps to them. Only a held run-owner lock
proves a live runner. Nothing here signals processes, prunes broadly, removes
images, caches, lock files or denial markers, or rewrites run reports.
"""
from __future__ import annotations

import contextlib
import dataclasses
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import time
import uuid

import native_owned_tree as tree


OWNER_LABEL = "com.zakura.regtest-fixture"
RUN_LABEL = "com.zakura.regtest-fixture.run"
NAMESPACE_LABEL = "com.keplr.vizor.e2e.namespace"
SUITE_LABEL = "com.keplr.vizor.e2e.suite-run"
# The longest catalog case (6000 seconds) plus the signer build budget.
MIN_ASSUMED_DEAD_SECONDS = 7200
_RUN_RE = re.compile(r"native-suite-([0-9a-f]{10})\Z")
_NAMESPACE_RE = re.compile(r"vizor_[0-9a-f]{10}_w[0-9]+_[0-9]+\Z")
_FIXTURE_RE = re.compile(r"[0-9a-f]{32}\Z")
_RESOURCE_RE = re.compile(r"zakura-proof-([0-9a-f]{12})-(node|donor|lwd|net|lwd-data)\Z")
_DEVICE_RE = re.compile(r"Vizor E2E vizor_[0-9a-f]{10}_w[0-9]+_[0-9]+\Z")
_ROLES = {"container": {"node", "donor", "lwd"}, "network": {"net"}, "volume": {"lwd-data"}}
_ABSENT = {"container": "Error response from daemon: No such container: {}",
           "network": "Error response from daemon: network {} not found",
           "volume": "Error response from daemon: get {}: no such volume"}
_REMOVE = {"container": ("container", "rm", "--force"), "volume": ("volume", "rm"), "network": ("network", "rm")}
_MAC_E2E = "Library/Containers/com.keplr.vizor/Data/Library/Application Support/com.keplr.vizor/e2e"
_DEVICES = "Library/Developer/CoreSimulator/Devices"
_MAX_EVIDENCE_BYTES = 4 * 1024 * 1024


class RetentionError(RuntimeError):
    """Usage, inventory or ownership could not be established."""


def run_docker(arguments):
    return subprocess.run(["docker", *arguments], capture_output=True, text=True, timeout=120, check=False)


def run_simctl(arguments):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("SIMCTL_CHILD_")}
    return subprocess.run(["/usr/bin/xcrun", "simctl", *arguments], capture_output=True, text=True,
                          timeout=120, check=False, env=environment)


def _entry(path):
    try:
        return path.lstat()
    except FileNotFoundError:
        return None


def _owned(details, kind):
    return details is not None and kind(details.st_mode) and details.st_uid == os.getuid()


def _children(parent, pattern):
    """Owned real child directories; links and foreign entries are never followed."""
    if not _owned(_entry(parent), stat.S_ISDIR):
        return []
    return [parent / name for name in sorted(os.listdir(parent))
            if pattern.fullmatch(name) and _owned(_entry(parent / name), stat.S_ISDIR)]


def _read(path, limit=_MAX_EVIDENCE_BYTES):
    """A bounded owned regular file opened without following a final link."""
    try:
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
            details = os.fstat(stream.fileno())
            if not _owned(details, stat.S_ISREG) or details.st_size > limit:
                return None
            return stream.read(limit + 1)
    except OSError:
        return None


def _json(path):
    data = _read(path)
    try:
        value = None if data is None else json.loads(data)
    except (ValueError, UnicodeError):
        return None
    return value if isinstance(value, dict) else None


def _udid(value):
    try:
        return value if isinstance(value, str) and str(uuid.UUID(value)).upper() == value else None
    except ValueError:
        return None


@dataclasses.dataclass
class Case:
    path: Path
    namespace: str
    fixtures: set
    device: dict | None


@dataclasses.dataclass
class Run:
    run_id: str
    path: Path
    identity: tuple
    activity: float
    locked: bool
    liveness: str
    reason: str
    cases: list
    # Names of case directories whose workspace marker names another path (a moved checkout).
    stale: list = dataclasses.field(default_factory=list)


def _device(case):
    """The exact UUID from the owner marker, else from the intent nonce's create log."""
    owner = _json(case / "simulator-owner.json")
    intent = owner or _json(case / "simulator-allocation.json")
    nonce = None if intent is None else intent.get("owner_nonce")
    if (intent is None or intent.get("namespace") != case.name or intent.get("workspace") != str(case)
        or intent.get("name") != "Vizor E2E " + case.name
        or not isinstance(nonce, str) or not re.fullmatch(r"[0-9a-f]{16}", nonce)):
        return None
    if owner is not None:
        udids, evidence = {owner.get("udid")}, "simulator-owner.json"
    else:
        # simctl create prints only the new UUID into its own command log.
        udids, evidence = set(), "create log"
        for log in sorted(case.glob(f"simulator-{nonce}-[0-9][0-9][0-9][0-9].log")):
            data = _read(log, 4096)
            text = "" if data is None else data.decode("ascii", "replace").strip()
            if _udid(text) is not None:
                udids.add(text)
    udid = next(iter(udids)) if len(udids) == 1 else None
    if _udid(udid) is None:
        return None
    return {"udid": udid, "name": intent["name"], "runtime": intent.get("runtime_identifier"),
            "device_type": intent.get("device_type_identifier"), "evidence": evidence}


def _case(path):
    marker = _json(path / "workspace-owner.json")
    if marker is None or marker.get("namespace") != path.name or marker.get("workspace") != str(path):
        return None
    fixtures = set()
    if _owned(_entry(path / "zakura-backend"), stat.S_ISDIR):
        for name, field in (("fixture-identity.json", None), ("start-proof.json", "identity"),
                            ("retention-proof.json", None), ("cleanup-proof.json", None)):
            record = _json(path / "zakura-backend" / name) or {}
            record = record.get(field) if field is not None else record
            value = record.get("run_id") if isinstance(record, dict) else None
            if isinstance(value, str) and _FIXTURE_RE.fullmatch(value):
                fixtures.add(value)
    return Case(path, path.name, fixtures, _device(path))


def _newest_mtime(path):
    try:
        newest, pending = path.lstat().st_mtime, [path]
        while pending:
            with os.scandir(pending.pop()) as entries:
                for entry in entries:
                    details = entry.stat(follow_symlinks=False)
                    newest = max(newest, details.st_mtime)
                    if stat.S_ISDIR(details.st_mode):
                        pending.append(Path(entry.path))
        return newest
    except OSError:
        return float("inf")  # Unreadable activity is never old enough.


def run_liveness(path, *, assume_dead_after=None, now=None):
    """Only a held run-owner flock proves a live runner; timestamps never do."""
    try:
        descriptor = os.open(path / "run-owner.lock", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        descriptor = None
    except OSError as error:
        return "unknown", f"run-owner.lock is unusable: {error}"
    if descriptor is not None:
        try:
            details = os.fstat(descriptor)
            if not _owned(details, stat.S_ISREG) or details.st_nlink != 1:
                return "unknown", "run-owner.lock is not an owned regular file"
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return "alive", "its runner holds run-owner.lock"
        finally:
            os.close(descriptor)
        # The runner writes run-owner.json only after it first held the lock.
        if _owned(_entry(path / "run-owner.json"), stat.S_ISREG):
            return "dead", "run-owner.lock is free"
    if _owned(_entry(path / "summary.json"), stat.S_ISREG):
        return "dead", "summary.json exists and no runner holds a run-owner lock"
    reason = "no run-owner lock or summary.json proves its runner ended"
    if assume_dead_after is not None:
        idle = (time.time() if now is None else now) - _newest_mtime(path)
        if idle >= assume_dead_after:
            return "assumed-dead", (f"POLICY --assume-dead-after {assume_dead_after}: idle {idle:.0f}s, "
                                    "not a liveness proof; " + reason)
    return "unknown", reason


def scan_runs(logs, *, assume_dead_after=None, now=None):
    """This checkout's native-suite runs and their exact case evidence."""
    runs = []
    for path in _children(logs, _RUN_RE):
        details = path.lstat()
        liveness, reason = run_liveness(path, assume_dead_after=assume_dead_after, now=now)
        directories = [case for repetition in _children(path, re.compile(r"repetition-[0-9]+\Z"))
                       for workers in _children(repetition, re.compile(r"native-workers\Z"))
                       for worker in _children(workers, re.compile(r"[0-9a-f]{10}-w[0-9]+\Z"))
                       for evidence in _children(worker, re.compile(r"evidence\Z"))
                       for cases in _children(evidence, re.compile(r"e2e\Z"))
                       for case in _children(cases, _NAMESPACE_RE)]
        # Markers of a moved or renamed checkout name its old path and map nothing here.
        stale = [directory.name for directory in directories
                 if (_json(directory / "workspace-owner.json") or {}).get("workspace") not in (None, str(directory))]
        cases = [case for case in map(_case, directories) if case is not None]
        runs.append(Run(_RUN_RE.fullmatch(path.name).group(1), path, tree.identity(details), details.st_mtime,
                        _entry(path / "run-owner.lock") is not None, liveness, reason, cases, stale=stale))
    return runs


def _absent(kind, ident, completed):
    """Only the exact daemon response proves absence, never a transport error."""
    try:
        return (completed.returncode == 1 and completed.stderr.strip() == _ABSENT[kind].format(ident)
                and json.loads(completed.stdout) == [])
    except ValueError:
        return False


def _inspect(docker, kind, ident):
    completed = docker([kind, "inspect", ident])
    if completed.returncode:
        if _absent(kind, ident, completed):
            return None
        raise RetentionError(f"docker {kind} inspect {ident} failed: {completed.stderr.strip()}")
    try:
        payload = json.loads(completed.stdout)
    except ValueError as error:
        raise RetentionError(f"docker {kind} inspect returned invalid JSON") from error
    if not isinstance(payload, list) or len(payload) != 1 or not isinstance(payload[0], dict):
        raise RetentionError(f"docker {kind} inspect returned an invalid result")
    return payload[0]


@dataclasses.dataclass
class Resource:
    kind: str
    ident: str
    name: str
    labels: dict
    sources: tuple
    driver: str | None

    @property
    def fixture(self):
        return self.labels.get(RUN_LABEL)

    @property
    def signature(self):
        return self.kind, self.ident, self.name, tuple(sorted(self.labels.items()))


def _resource(kind, payload):
    """Harness resources carry the exact owner label; anything else is never listed."""
    labels = (payload.get("Config") or {}).get("Labels") if kind == "container" else payload.get("Labels")
    if not isinstance(labels, dict) or labels.get(OWNER_LABEL) != "1":
        return None
    name = payload.get("Name")
    if kind == "container" and isinstance(name, str) and name.startswith("/"):
        name = name[1:]
    ident = payload.get("Name") if kind == "volume" else payload.get("Id")
    if not isinstance(ident, str) or not isinstance(name, str):
        return None
    sources = tuple(mount.get("Source") for mount in payload.get("Mounts") or ()
                    if isinstance(mount, dict) and mount.get("Type") == "bind"
                    and mount.get("Destination") == "/config/zakurad.toml")
    return Resource(kind, ident, name, dict(labels), sources, payload.get("Driver"))


def docker_inventory(docker):
    resources = []
    for kind, listing, field in (("container", ("container", "ls", "--all", "--no-trunc"), "{{.ID}}"),
                                 ("network", ("network", "ls", "--no-trunc"), "{{.ID}}"),
                                 ("volume", ("volume", "ls"), "{{.Name}}")):
        listed = docker([*listing, "--filter", f"label={OWNER_LABEL}=1", "--format", field])
        if listed.returncode:
            raise RetentionError(f"docker {kind} listing failed: {listed.stderr.strip()}")
        for ident in listed.stdout.split():
            payload = _inspect(docker, kind, ident)
            resource = None if payload is None else _resource(kind, payload)
            if resource is not None:
                resources.append(resource)
    return resources


def simulator_inventory(simctl):
    listed = simctl(["list", "devices", "--json"])
    if listed.returncode:
        raise RetentionError(f"simctl device listing failed: {listed.stderr.strip()}")
    try:
        groups = json.loads(listed.stdout)["devices"]
        devices = {}
        for runtime, entries in groups.items():
            for entry in entries:
                udid = _udid(entry["udid"])
                if udid is None:
                    raise ValueError("noncanonical device UUID")
                devices[udid] = {"udid": udid, "name": entry["name"], "runtime": runtime,
                                 "device_type": entry.get("deviceTypeIdentifier"), "state": entry.get("state")}
        return devices
    except (ValueError, KeyError, TypeError, AttributeError) as error:
        raise RetentionError(f"invalid simctl device inventory: {error}") from error


def macos_namespaces(home):
    try:
        return [(path.name, _json(path / "mac-storage-owner.json") or {})
                for path in _children(home / _MAC_E2E, _NAMESPACE_RE)]
    except OSError as error:
        raise RetentionError(f"macOS namespaces are unreadable: {error}") from error


def _deletable(run):
    if run.liveness in ("dead", "assumed-dead"):
        return "delete", "run is " + run.liveness + " (" + run.reason + ")"
    if run.liveness == "alive":
        return "keep", "run is alive: " + run.reason
    return "keep", "run liveness unknown: " + run.reason + "; --assume-dead-after can assume it dead"


def _map_docker(resources, runs):
    """Fixture run label to one case by its evidence or bind mount; else unmapped."""
    cases = {str(case.path): (run, case) for run in runs for case in run.cases}
    owners = {}
    for run in runs:
        for case in run.cases:
            for fixture in case.fixtures:
                owners.setdefault(fixture, set()).add(str(case.path))
    for resource in resources:
        for source in resource.sources:
            path = Path(source) if isinstance(source, str) else Path()
            owner = (str(path.parent.parent) if path.name == "zakurad.toml" and path.parent.name == "zakura-backend"
                     else "?")
            owners.setdefault(resource.fixture, set()).add(owner if owner in cases else "foreign:" + str(source))
    mapped = []
    for resource in resources:
        fixture, shape = resource.fixture, _RESOURCE_RE.fullmatch(resource.name)
        if (not isinstance(fixture, str) or not _FIXTURE_RE.fullmatch(fixture) or shape is None
            or shape.group(1) != fixture[:12] or shape.group(2) not in _ROLES[resource.kind]
            or (resource.kind == "volume" and resource.driver != "local")):
            mapped.append((resource, None, None, "not an exact fixture resource shape"))
            continue
        found = owners.get(fixture, set())
        if not found:
            mapped.append((resource, None, None, "no case evidence in this checkout names its fixture"))
        elif len(found) != 1 or next(iter(found)) not in cases:
            mapped.append((resource, None, None, "its fixture maps outside this checkout or to several cases"))
        else:
            run, case = cases[next(iter(found))]
            if (resource.labels.get(NAMESPACE_LABEL, case.namespace) != case.namespace
                or resource.labels.get(SUITE_LABEL, run.run_id) != run.run_id):
                mapped.append((resource, run, None, "Vizor labels disagree with its case evidence"))
            else:
                mapped.append((resource, run, case, None))
    return mapped


def _map_devices(devices, runs):
    claimed, mapped = set(), []
    for run in runs:
        for case in run.cases:
            expected = case.device
            if expected is None or expected["udid"] not in devices:
                continue
            claimed.add(expected["udid"])
            current = devices[expected["udid"]]
            if any(current[key] != expected[key] for key in ("name", "runtime", "device_type")):
                mapped.append((current, run, None, "inventory identity differs from " + expected["evidence"]))
            else:
                mapped.append((current, run, case, expected["evidence"]))
    for udid, device in sorted(devices.items()):
        if udid not in claimed and _DEVICE_RE.fullmatch(device["name"]):
            mapped.append((device, None, None, "name-only match; no owner marker or create log names this UUID"))
    return mapped


@dataclasses.dataclass
class Item:
    kind: str
    ident: str
    name: str
    run: Run | None
    namespace: str | None
    action: str
    reason: str
    resource: Resource | None = None
    device: dict | None = None
    result: str | None = None
    detail: str | None = None

    def line(self):
        owner = "-" if self.run is None else "native-suite-" + self.run.run_id + (
            "/" + self.namespace if self.namespace else "")
        short = self.ident if self.kind == "simulator" else self.ident[:12]
        label = self.name if self.ident in ("", self.name) else f"{self.name} [{short}]"
        return (f"{self.result or self.action:<9} {self.kind:<9} {label}  {owner}: "
                + (self.reason if self.detail is None else self.detail))

    def record(self):
        return {"kind": self.kind, "id": self.ident, "name": self.name, "namespace": self.namespace,
                "run_id": None if self.run is None else self.run.run_id, "action": self.action,
                "reason": self.reason, "result": self.result, "detail": self.detail}


def _plan(found, selected, docker_map, device_map, namespaces, *, builds, folders, incomplete):
    chosen = {run.run_id for run in selected}
    cases = {str(case.path): (run, case) for run in found for case in run.cases}
    items = []
    for resource, run, case, reason in docker_map:
        if case is None:
            items.append(Item(resource.kind, resource.ident, resource.name, run, None, "unmapped",
                              reason + "; never deleted", resource))
        elif run.run_id in chosen:
            items.append(Item(resource.kind, resource.ident, resource.name, run, case.namespace,
                              *_deletable(run), resource))
    for device, run, case, reason in device_map:
        if case is None:
            items.append(Item("simulator", device["udid"], device["name"], run, None, "unmapped",
                              reason + "; never deleted"))
        elif run.run_id in chosen:
            action, why = _deletable(run)
            items.append(Item("simulator", device["udid"], device["name"], run, case.namespace, action,
                              why + "; UUID from " + reason, device=case.device))
    for name, marker in namespaces:
        run, case = cases.get(marker.get("workspace"), (None, None))
        if case is None or case.namespace != name:
            items.append(Item("macos", name, name, None, None, "unmapped",
                              "its owner marker names no case in this checkout; listed only"))
        elif run.run_id in chosen:
            items.append(Item("macos", name, name, run, name, "list", "macOS namespaces are listed only; "
                              "Keychain and preferences need the signed cleanup helper"))
    for run in selected:
        action, why = _deletable(run)
        if builds and _owned(_entry(run.path / "builds"), stat.S_ISDIR):
            items.append(Item("builds", "", "builds", run, None, "strip" if action == "delete" else "keep",
                              why + "; keeps producer logs and markers" if action == "delete" else why))
        if folders:
            blocker = None if action == "delete" else why
            # The folder holds the only evidence naming whatever its moved cases left behind.
            moved = f"case evidence {run.stale[0]} names another workspace path" if run.stale else None
            blocker = blocker or incomplete or moved or _blocker(run, items, planned=True)
            items.append(Item("folder", "", run.path.name, run, None, "keep" if blocker else "remove",
                              blocker or why + "; no mapped resource remains"))
    return items


def _blocker(run, items, *, planned):
    """A run folder is the ownership evidence of anything still mapped to it."""
    for item in items:
        if item.run is not run or item.kind in ("builds", "folder"):
            continue
        if item.action in ("unmapped", "list"):
            return f"{item.kind} {item.name} still maps to it ({item.action})"
        if planned and item.action != "delete":
            return f"{item.kind} {item.name} is kept"
        if not planned and item.result not in ("deleted", "absent"):
            return f"{item.kind} {item.name} was not removed ({item.result})"
    return None


def _hold_prune_lock(stack, logs):
    """Serialize prunes of one checkout; the lock file itself is never removed."""
    directory = logs / "prune"
    try:
        os.mkdir(directory, 0o700)
    except FileExistsError:
        pass
    details = _entry(directory)
    if not _owned(details, stat.S_ISDIR) or stat.S_IMODE(details.st_mode) & 0o077:
        raise RetentionError("the prune directory must be private and owned")
    descriptor = os.open(directory / "prune.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    stack.callback(os.close, descriptor)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        raise RetentionError("another prune of this checkout holds .regtest-logs/prune/prune.lock") from error


@contextlib.contextmanager
def _hold_dead_run(run):
    """Hold a dead run's owner lock while acting on it; never adopt a live one."""
    try:
        descriptor = os.open(run.path / "run-owner.lock", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        if run.locked:
            raise RetentionError("run-owner.lock changed since inventory") from None
        yield
        return
    try:
        details = os.fstat(descriptor)
        if not run.locked or not _owned(details, stat.S_ISREG) or details.st_nlink != 1:
            raise RetentionError("run-owner.lock changed since inventory")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RetentionError("its runner holds run-owner.lock again; nothing was changed") from error
        yield
    finally:
        os.close(descriptor)


def _delete_resource(docker, resource):
    current = _inspect(docker, resource.kind, resource.ident)
    if current is None:
        return "absent", "already absent"
    current = _resource(resource.kind, current)
    if current is None or current.signature != resource.signature:
        return "skipped", "changed since inventory; not deleted"
    removed = docker([*_REMOVE[resource.kind], resource.ident])
    if removed.returncode:
        raise RetentionError(f"docker {resource.kind} rm failed: {removed.stderr.strip()}")
    if _inspect(docker, resource.kind, resource.ident) is not None:
        raise RetentionError("still present after removal")
    return "deleted", "removed by exact " + ("name" if resource.kind == "volume" else "ID")


def _simctl(simctl, arguments):
    completed = simctl(arguments)
    if completed.returncode:
        raise RetentionError(f"simctl {arguments[0]} failed: {completed.stderr.strip()}")


def _delete_device(simctl, home, expected, *, wait=60.0):
    udid, directory = expected["udid"], home / _DEVICES / expected["udid"]
    current = simulator_inventory(simctl).get(udid)
    if current is None:
        if _entry(directory) is not None:
            raise RetentionError("its device directory remains without an inventory entry")
        return "absent", "already absent"
    if any(current[key] != expected[key] for key in ("name", "runtime", "device_type")):
        return "skipped", "changed since inventory; not deleted"
    if current["state"] != "Shutdown":
        _simctl(simctl, ["shutdown", udid])
        deadline = time.monotonic() + wait
        while current is not None and current["state"] != "Shutdown":
            if time.monotonic() >= deadline:
                raise RetentionError("shutdown was not observed")
            time.sleep(0.2)
            current = simulator_inventory(simctl).get(udid)
        if current is None:
            raise RetentionError("device disappeared during shutdown; deletion unproven")
    _simctl(simctl, ["delete", udid])
    if udid in simulator_inventory(simctl):
        raise RetentionError("device remains in the inventory after delete")
    if _entry(directory) is not None:
        raise RetentionError("device directory remains after delete")
    return "deleted", "shut down, deleted by exact UUID, absent from inventory and disk"


def _remove_folder(logs, run):
    """Anchored removal of one whole run folder, including its own run-owner.lock."""
    with contextlib.ExitStack() as stack:
        logs_fd = tree.open_directory(stack, logs, private=True)
        run_fd = tree.open_directory(stack, run.path.name, dir_fd=logs_fd, private=True)
        if tree.identity(os.fstat(run_fd)) != run.identity:
            raise RetentionError("run folder changed since inventory")
        def attached():
            if tree.identity(os.stat(run.path.name, dir_fd=logs_fd, follow_symlinks=False)) != run.identity:
                raise tree.OwnedTreeError("run folder attachment changed")
        removed = []
        tree.remove_output(run_fd, tree.scan(run_fd, allow_links=True, build_output=True), attached,
                           removed=removed)
        attached()
        os.rmdir(run.path.name, dir_fd=logs_fd)
    return tree.output_bytes(entry for _, entry in removed)


def _act(item, logs, home, docker, simctl):
    try:
        if item.kind in _REMOVE:
            item.result, item.detail = _delete_resource(docker, item.resource)
        elif item.kind == "simulator":
            item.result, item.detail = _delete_device(simctl, home, item.device)
        elif item.kind == "builds":
            record = tree.prune_build_outputs(item.run.path / "builds")
            item.result = "failed" if record["errors"] else "stripped"
            item.detail = (f"removed {tree.size_text(record['bytes'])} in {len(record['removed'])} entries"
                           + "".join("; " + error for error in record["errors"]))
        else:
            item.result, item.detail = "removed", f"removed {tree.size_text(_remove_folder(logs, item.run))}"
    except (RetentionError, tree.OwnedTreeError, OSError, subprocess.SubprocessError) as error:
        item.result, item.detail = "failed", str(error)


def _apply(selected, items, logs, home, docker, simctl):
    """Act per dead run while holding its lock, in the fixture's own removal order."""
    for run in selected:
        planned = [item for item in items if item.run is run and item.action in ("delete", "strip", "remove")]
        if not planned:
            continue
        try:
            with _hold_dead_run(run):
                # Containers go before the volume and network they use, as in close().
                for kind in ("container", "volume", "network", "simulator", "builds", "folder"):
                    for item in (item for item in planned if item.kind == kind):
                        blocker = _blocker(run, items, planned=False) if kind == "folder" else None
                        if blocker:
                            item.result, item.detail = "kept", blocker
                        else:
                            _act(item, logs, home, docker, simctl)
        except RetentionError as error:
            for item in planned:
                if item.result is None:
                    item.result, item.detail = "skipped", str(error)


def _inventory(found, docker, simctl, home):
    """Each unavailable inventory is reported and blocks folder removal."""
    unavailable, docker_map, device_map, namespaces = {}, [], [], []
    try:
        docker_map = _map_docker(docker_inventory(docker), found)
    except (RetentionError, OSError, subprocess.SubprocessError) as error:
        unavailable["docker"] = str(error)
    try:
        device_map = _map_devices(simulator_inventory(simctl), found)
    except (RetentionError, OSError, subprocess.SubprocessError) as error:
        unavailable["simulators"] = str(error)
    try:
        namespaces = macos_namespaces(home)
    except RetentionError as error:
        unavailable["macos"] = str(error)
    return docker_map, device_map, namespaces, unavailable


def _utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _write_receipt(logs, checkout, started, options, unavailable, selected, items, *, interrupted):
    """The read-only record of one --apply; incomplete when an item failed or acting stopped early."""
    failed = sum(item.result == "failed" for item in items)
    path = logs / "prune" / (time.strftime("prune-%Y%m%dT%H%M%SZ-", time.gmtime()) + secrets.token_hex(4) + ".json")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump({"schema_version": 1, "checkout": str(checkout), "started_at": started, "finished_at": _utc(),
                   "options": options, "unavailable": unavailable, "complete": not failed and not interrupted,
                   "runs": [{"run_id": run.run_id, "liveness": run.liveness, "reason": run.reason}
                            for run in selected],
                   "items": [item.record() for item in items]}, output, indent=2, sort_keys=True)
        output.write("\n")
    return path


def prune(checkout, *, runs=(), older_than=None, keep_last=0, assume_dead_after=None, builds=False,
          folders=False, apply=False, home=None, docker=run_docker, simctl=run_simctl, out=print, now=None):
    """List by default; with apply, remove exact IDs of selected dead runs only.

    Returns the exit status. Usage and environment errors raise RetentionError.
    """
    if any(not isinstance(run_id, str) or not re.fullmatch(r"[0-9a-f]{10}", run_id) for run_id in runs):
        raise RetentionError("--run takes a ten-character native-suite run ID")
    if type(keep_last) is not int or keep_last < 0:
        raise RetentionError("--keep-last must be zero or more")
    if assume_dead_after is not None and (type(assume_dead_after) is not int
                                          or assume_dead_after < MIN_ASSUMED_DEAD_SECONDS):
        raise RetentionError(f"--assume-dead-after must be at least {MIN_ASSUMED_DEAD_SECONDS} seconds")
    if folders and not runs and older_than is None:
        raise RetentionError("--folders requires --run or --older-than")
    logs = Path(checkout) / ".regtest-logs"
    if not _owned(_entry(logs), stat.S_ISDIR):
        out("No .regtest-logs in this checkout; nothing is retained.")
        return 0
    now = time.time() if now is None else now
    home = Path.home() if home is None else Path(home)
    with contextlib.ExitStack() as stack:
        if apply:
            _hold_prune_lock(stack, logs)
        started = _utc()
        found = scan_runs(logs, assume_dead_after=assume_dead_after, now=now)
        missing = sorted(set(runs) - {run.run_id for run in found})
        if missing:
            raise RetentionError("no such run in this checkout: " + ", ".join(missing))
        recent = sorted(found, key=lambda run: (run.activity, run.run_id), reverse=True)
        selected = [run for run in recent[keep_last:] if (not runs or run.run_id in runs)
                    and (older_than is None or now - run.activity >= older_than)]
        docker_map, device_map, namespaces, unavailable = _inventory(found, docker, simctl, home)
        items = _plan(found, selected, docker_map, device_map, namespaces, builds=builds, folders=folders,
                      incomplete="inventory incomplete: " + ", ".join(sorted(unavailable)) if unavailable else None)
        if apply:
            interrupted = True
            try:
                _apply(selected, items, logs, home, docker, simctl)
                interrupted = False
            finally:
                # Before any output: a closed stdout or Ctrl-C must not lose the record of removals.
                receipt = _write_receipt(logs, checkout, started, {
                    "runs": list(runs), "older_than_seconds": older_than, "keep_last": keep_last,
                    "assume_dead_after_seconds": assume_dead_after, "builds": builds, "folders": folders},
                    unavailable, selected, items, interrupted=interrupted)
        out(("Applying to" if apply else "Dry run, nothing changes; --apply acts on")
            + f" {len(selected)} selected run(s) in {logs}")
        for name, error in sorted(unavailable.items()):
            out(f"inventory {name} unavailable: {error}")
        for run in selected:
            out(f"run       native-suite-{run.run_id}  {run.liveness}: {run.reason}")
            for item in items:
                if item.run is run and item.action != "unmapped":
                    out("  " + item.line())
        for item in items:
            if item.action == "unmapped":
                out(item.line())
        if not apply:
            out(f"{sum(item.action in ('delete', 'strip', 'remove') for item in items)} item(s) would be removed")
            return 0
        failed = sum(item.result == "failed" for item in items)
        removed = sum(item.result in ("deleted", "stripped", "removed") for item in items)
        out(f"{removed} item(s) removed, {failed} failed; receipt: {receipt}")
        return 1 if failed else 0
