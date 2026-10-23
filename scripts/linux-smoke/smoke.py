#!/usr/bin/env python3
"""Run in a disposable Xvfb/D-Bus container or test VM; never a host wallet."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

from check_bundle import inspect_bundle


RENDER_ERRORS = re.compile(
    r"undefined symbol|symbol lookup error|version [`'][^\n]+not found|"
    r"Failed to create (?:EGL|OpenGL) context|"
    r"Failed to create platform view rendering surface|Could not determine GL version|"
    r"Timed out waiting for OpenGL frame|"
    r"error while loading shared libraries|Xlib is not thread-safe",
    re.IGNORECASE,
)


def command(argv: list[str], **kwargs) -> str:
    return subprocess.run(argv, check=True, capture_output=True, text=True, timeout=30, **kwargs).stdout


def phrase_box(tsv: str, phrase: str) -> tuple[int, int] | None:
    """Find adjacent OCR words on one line, excluding OS/window-title evidence."""
    lines: dict[tuple[str, ...], list[dict]] = {}
    for row in csv.DictReader(io.StringIO(tsv), delimiter="\t"):
        if row.get("level") == "5" and row.get("text", "").strip():
            key = tuple(row[k] for k in ("page_num", "block_num", "par_num", "line_num"))
            lines.setdefault(key, []).append(row)
    target = re.sub(r"[^a-z0-9]", "", phrase.lower())
    for words in lines.values():
        normalized = [re.sub(r"[^a-z0-9]", "", word["text"].lower()) for word in words]
        for start in range(len(words)):
            joined = ""
            for end in range(start, len(words)):
                joined += normalized[end]
                if joined == target:
                    match = words[start:end + 1]
                    left = min(int(word["left"]) for word in match)
                    top = min(int(word["top"]) for word in match)
                    right = max(int(word["left"]) + int(word["width"]) for word in match)
                    bottom = max(int(word["top"]) + int(word["height"]) for word in match)
                    return ((left + right) // 2, (top + bottom) // 2)
                if len(joined) >= len(target):
                    break
    return None


def stop_owned_process(process: subprocess.Popen) -> None:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)


def owned_pids(process: subprocess.Popen) -> list[int]:
    # The FUSE runtime stays alive while its AppRun child owns the GTK window.
    # Every launch gets its own process group; never match another desktop app.
    pids = {process.pid}
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit():
            pid = int(entry.name)
            try:
                if os.getpgid(pid) == process.pid:
                    pids.add(pid)
            except ProcessLookupError:
                pass
    return sorted(pids)


def capture_until(process: subprocess.Popen, output: Path, name: str, phrase: str, timeout: int) -> tuple[str, tuple[int, int]]:
    from PIL import Image

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"App exited before {name} (exit {process.returncode})")
        windows = []
        for pid in owned_pids(process):
            windows.extend(subprocess.run(
                ["xdotool", "search", "--onlyvisible", "--pid", str(pid)],
                capture_output=True, text=True, timeout=5,
            ).stdout.split())
        if windows:
            window = windows[-1]
            command(["xdotool", "windowactivate", "--sync", window])
            image = output / f"{name}.png"
            command(["scrot", "--overwrite", "--focused", str(image)])
            # Small Flutter button text over the welcome artwork is missed at
            # native resolution. Preserve that screenshot and OCR a 3x copy.
            ocr_image = output / f"{name}-ocr.png"
            with Image.open(image) as original:
                gray = original.convert("L")
                gray.resize((gray.width * 3, gray.height * 3)).save(ocr_image)
            tsv = command(["tesseract", str(ocr_image), "stdout", "-l", "eng", "--psm", "11", "tsv"])
            (output / f"{name}.tsv").write_text(tsv)
            box = phrase_box(tsv, phrase)
            if box:
                return window, (box[0] // 3, box[1] // 3)
        time.sleep(2)
    raise RuntimeError(f"No rendered {name} containing {phrase!r} within {timeout}s")


def check_ui(appdir: Path, output: Path, timeout: int, executable: Path | None = None) -> dict:
    with (output / "openbox.log").open("w") as wm_log, (output / "app.log").open("w") as app_log:
        wm = subprocess.Popen(["openbox"], stdout=wm_log, stderr=subprocess.STDOUT, start_new_session=True)
        app = None
        try:
            # This keyring and HOME exist only for this disposable test run.
            keyring = subprocess.run(
                ["gnome-keyring-daemon", "--unlock", "--components=secrets"],
                input="vizor-smoke-disposable\n", capture_output=True, text=True, timeout=15,
            )
            (output / "keyring.log").write_text(keyring.stdout + keyring.stderr)
            if keyring.returncode:
                raise RuntimeError("Could not initialize the disposable keyring")
            app = subprocess.Popen(
                [str(executable or appdir / "AppRun")], cwd=appdir, stdout=app_log,
                stderr=subprocess.STDOUT, start_new_session=True,
            )
            window, (x, y) = capture_until(app, output, "welcome", "Import wallet", timeout)
            command(["xdotool", "mousemove", "--window", window, str(x), str(y), "click", "1"])
            capture_until(app, output, "import-method", "Import secret passphrase", timeout)
            if app.poll() is not None:
                raise RuntimeError("App exited after navigation")
        finally:
            if app is not None:
                stop_owned_process(app)
            stop_owned_process(wm)
    return {"status": "passed", "screens": ["welcome.png", "import-method.png"]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--appimage", type=Path)
    source.add_argument("--appdir", type=Path, help="Already extracted AppDir (container development only)")
    parser.add_argument("--launch-appimage", action="store_true",
                        help="Launch the original AppImage via FUSE after inspection (test VM only)")
    parser.add_argument("--output", type=Path, default=Path("/tmp/evidence"))
    parser.add_argument("--timeout", type=int, default=90, help="Seconds per screen")
    args = parser.parse_args()
    if args.launch_appimage and not args.appimage:
        parser.error("--launch-appimage requires --appimage")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    result: dict = {"status": "failed", "failures": [], "renderer": "X11 / Mesa llvmpipe (software)", "machine": os.uname().machine}
    try:
        (output / "os-release.txt").write_text(Path("/etc/os-release").read_text())
        (output / "glxinfo.txt").write_text(command(["glxinfo", "-B"]))
        result["os"] = Path("/etc/os-release").read_text().splitlines()
        with tempfile.TemporaryDirectory(prefix="vizor-smoke-") as temporary:
            work = Path(temporary)
            # Each invocation also isolates state from earlier tests in this container.
            home = work / "home"
            home.mkdir(mode=0o700)
            runtime = work / "runtime"
            runtime.mkdir(mode=0o700)
            os.environ.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
                              XDG_DATA_HOME=str(home / ".local/share"), XDG_CACHE_HOME=str(home / ".cache"),
                              XDG_RUNTIME_DIR=str(runtime))
            if args.appimage:
                artifact = work / "Vizor.AppImage"
                shutil.copyfile(args.appimage, artifact)
                artifact.chmod(0o755)
                digest = hashlib.sha256()
                with artifact.open("rb") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(block)
                result["appimage_sha256"] = digest.hexdigest()
                extraction = subprocess.run(
                    [str(artifact), "--appimage-extract"], cwd=work,
                    capture_output=True, text=True, timeout=120,
                )
                (output / "extract.log").write_text(extraction.stdout + extraction.stderr)
                extraction.check_returncode()
                appdir = work / "squashfs-root"
            else:
                appdir = args.appdir.resolve()
            if not (appdir / "AppRun").is_file():
                raise RuntimeError("No AppRun in extracted bundle")
            bundle = inspect_bundle(appdir, output)
            result["bundle"] = {"status": bundle["status"], "elf_count": len(bundle["elfs"])}
            result["failures"].extend(bundle["failures"])
            # Keep UI evidence even when the bundle policy fails.
            try:
                result["launch"] = "AppImage / FUSE" if args.launch_appimage else "extracted AppRun"
                result["ui"] = check_ui(appdir, output, args.timeout,
                                        artifact if args.launch_appimage else None)
            except (RuntimeError, OSError, subprocess.SubprocessError) as error:
                result["ui"] = {"status": "failed"}
                result["failures"].append(str(error))
            log = (output / "app.log").read_text(errors="replace") if (output / "app.log").exists() else ""
            errors = [line for line in log.splitlines() if RENDER_ERRORS.search(line)]
            result["failures"].extend(errors)
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        result["failures"].append(str(error))
    result["status"] = "failed" if result["failures"] else "passed"
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
