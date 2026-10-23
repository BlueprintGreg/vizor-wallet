#!/usr/bin/env python3
"""Pure checks on any host; GTK controls also run inside the smoke image."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from check_bundle import host_library, inspect_bundle
from smoke import phrase_box, RENDER_ERRORS


ROOT = Path(__file__).resolve().parent


def ocr_rows(lines: list[list[str]]) -> str:
    header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n"
    for line, words in enumerate(lines, 1):
        for word, text in enumerate(words, 1):
            header += f"5\t1\t1\t1\t{line}\t{word}\t{word * 40}\t50\t35\t20\t95\t{text}\n"
    return header


class EvidenceTest(unittest.TestCase):
    def test_ocr_requires_adjacent_words_on_one_line(self):
        self.assertEqual(phrase_box(ocr_rows([["Import", "wallet"]]), "Import wallet"), (77, 60))
        self.assertIsNone(phrase_box(ocr_rows([["Import"], ["wallet"]]), "Import wallet"))
        self.assertIsNone(phrase_box(ocr_rows([["Import", "another", "wallet"]]), "Import wallet"))
        self.assertIsNone(phrase_box(ocr_rows([]), "Import wallet"))
        # OCR can join a small button's words without changing its characters.
        self.assertIsNotNone(phrase_box(ocr_rows([["Importwallet"]]), "Import wallet"))

    def test_detects_reported_render_errors(self):
        for message in (
            "libgvfscommon.so: undefined symbol: g_task_set_static_name",
            "Failed to create EGL context for rendering",
            "Failed to create OpenGL context: No available configurations",
            "Failed to create platform view rendering surface",
            "Impeller validation: Could not determine GL version.",
            "Timed out waiting for OpenGL frame of size 1080x720 (have 1280x720)",
            "Xlib is not thread-safe.",
            "libgio.so: version `GLIB_2.80' not found",
        ):
            with self.subTest(message=message):
                self.assertIsNotNone(RENDER_ERRORS.search(message))
        self.assertIsNone(RENDER_ERRORS.search("router redirect: location=/welcome"))

    def test_desktop_libraries_are_host_owned_but_app_runtime_is_kept(self):
        for library in ("libgio-2.0.so.0", "libgtk-3.so.0", "libX11.so.6", "libxcb-dri3.so.0", "libEGL.so.1",
                        "libGLESv2.so.2", "libmount.so.1", "libblkid.so.1", "libpcre2-8.so.0", "libpango-1.0.so.0",
                        "libbz2.so.1"):
            self.assertTrue(host_library(library), library)
        for library in ("libapp.so", "libflutter_linux_gtk.so", "libgstapp-1.0.so.0", "libZXing.so.3",
                        "libv4lconvert.so.0", "libjpeg.so.8", "libbz2.so.1.0"):
            self.assertFalse(host_library(library), library)

    def test_detects_forbidden_symlink_and_renamed_soname(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            appdir = root / "app"
            appdir.mkdir()
            (appdir / "renamed.so").write_bytes(b"\x7fELF")
            (appdir / "libX11.so.6").symlink_to("renamed.so")
            with patch("check_bundle.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "(SONAME) Library soname: [libgio-2.0.so.0]", "")):
                report = inspect_bundle(appdir, root)
            self.assertEqual(len(report["failures"]), 2)
            self.assertEqual(report["status"], "failed")

    def test_missing_dependency_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            appdir = root / "app"
            appdir.mkdir()
            (appdir / "plugin.so").write_bytes(b"\x7fELF")
            with patch("check_bundle.subprocess.run", side_effect=[
                subprocess.CompletedProcess([], 0, "(NEEDED) Shared library: [libmissing.so.1]", ""),
                subprocess.CompletedProcess([], 0, "libmissing.so.1 => not found", ""),
            ]):
                report = inspect_bundle(appdir, root)
            self.assertEqual(report["status"], "failed")
            self.assertIn("not found", report["elfs"][0]["ldd"])

    def test_unversioned_dependency_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            appdir = root / "app"
            appdir.mkdir()
            (appdir / "plugin.so").write_bytes(b"\x7fELF")
            with patch("check_bundle.subprocess.run", side_effect=[
                subprocess.CompletedProcess([], 0, "(NEEDED) Shared library: [libpcre2-8.so.0]", ""),
                subprocess.CompletedProcess([], 0, "libpcre2-8.so.0: no version information available (required by libglib-2.0.so.0)", ""),
            ]):
                report = inspect_bundle(appdir, root)
            self.assertEqual(report["status"], "failed")

    def test_packaging_preflight_rejects_a_bundled_host_library(self):
        with tempfile.TemporaryDirectory() as temporary:
            appdir = Path(temporary)
            (appdir / "AppRun").write_text("#!/bin/sh\n")
            (appdir / "libmount.so.1").write_text("forbidden fixture")
            process = subprocess.run([sys.executable, str(ROOT / "check_bundle.py"),
                                      "--appdir", str(appdir)], capture_output=True, text=True)
            self.assertEqual(process.returncode, 1)
            self.assertIn("Bundled host library: libmount.so.1", process.stdout)


GTK_FIXTURE = '''#!/usr/bin/python3
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk
window = Gtk.Window(title="Import wallet")
window.set_default_size(800, 600)
window.connect("destroy", Gtk.main_quit)
provider = Gtk.CssProvider()
provider.load_from_data(b"window {background: black;} button, label {font-size: 26px;}")
Gtk.StyleContext.add_provider_for_screen(window.get_screen(), provider, 800)
if MODE != "black":
    button = Gtk.Button(label="Import wallet")
    button.set_margin_top(200)
    button.set_margin_bottom(200)
    button.set_margin_start(180)
    button.set_margin_end(180)
    def navigate(button):
        window.remove(button)
        window.add(Gtk.Label(label="Import secret passphrase"))
        window.show_all()
    button.connect("clicked", navigate)
    window.add(button)
if MODE == "render-error":
    print("Failed to create EGL context for rendering", flush=True)
window.show_all()
Gtk.main()
'''


@unittest.skipUnless(os.environ.get("VIZOR_SMOKE_NATIVE_CONTROLS") == "1", "Run in the Xvfb smoke image")
class NativeControlTest(unittest.TestCase):
    def run_control(self, mode: str, forbidden: bool = False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            appdir = root / "app"
            appdir.mkdir()
            fixture = appdir / "fixture.py"
            fixture.write_text(GTK_FIXTURE.replace('import gi', f'MODE = {mode!r}\nimport gi', 1))
            launcher = appdir / "AppRun"
            # Like a FUSE AppImage runtime, keep a parent alive while its child
            # owns the window. A PID-only window lookup would miss this frame.
            launcher.write_text(f'#!/bin/sh\npython3 "{fixture}" &\nwait\n')
            launcher.chmod(0o755)
            if mode == "missing-launcher":
                launcher.unlink()
            if forbidden:
                (appdir / "libX11.so.6").write_text("forbidden fixture")
            evidence = root / "evidence"
            process = subprocess.run(
                ["dbus-run-session", "--", sys.executable, str(ROOT / "smoke.py"), "--appdir", str(appdir),
                 "--output", str(evidence), "--timeout", "8"], capture_output=True, text=True, timeout=60,
            )
            self.assertTrue((evidence / "result.json").exists(), process.stderr)
            report = json.loads((evidence / "result.json").read_text())
            report["control_app_log"] = (evidence / "app.log").read_text() if (evidence / "app.log").exists() else ""
            return process.returncode, report, sorted(path.name for path in evidence.glob("*.png") if not path.name.endswith("-ocr.png"))

    def test_rendered_app_navigates(self):
        code, report, images = self.run_control("working")
        self.assertEqual(code, 0, report)
        self.assertEqual(report["status"], "passed")
        self.assertEqual(images, ["import-method.png", "welcome.png"])

    def test_invalid_bundle_retains_a_failed_result(self):
        code, report, images = self.run_control("missing-launcher")
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "failed")
        self.assertIn("No AppRun in extracted bundle", report["failures"])
        self.assertEqual(images, [])

    def test_live_black_window_with_matching_title_fails(self):
        code, report, _ = self.run_control("black")
        self.assertEqual(code, 1)
        self.assertEqual(report["ui"]["status"], "failed")
        self.assertTrue(any("No rendered welcome" in error for error in report["failures"]), report)

    def test_render_error_fails_even_when_ui_is_visible(self):
        code, report, _ = self.run_control("render-error")
        self.assertEqual(code, 1)
        self.assertEqual(report["ui"]["status"], "passed", report)
        self.assertIn("Failed to create EGL context for rendering", report["failures"])

    def test_forbidden_bundle_still_collects_ui_evidence(self):
        code, report, images = self.run_control("working", forbidden=True)
        self.assertEqual(code, 1)
        self.assertEqual(report["ui"]["status"], "passed", report)
        self.assertEqual(len(images), 2)
        self.assertEqual(report["bundle"]["status"], "failed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
