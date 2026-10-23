# Linux AppImage smoke checks

Test the **final AppImage**, without rebuilding Flutter or opening a host wallet.
The initial matrix is Ubuntu 22.04, Ubuntu 24.04, and Fedora 44. These are test
targets, not a declaration that every derivative or GPU configuration is supported.

```bash
scripts/linux-smoke/run.sh --appimage /path/to/Vizor-linux-x86_64.AppImage

# One environment; native ARM64 artifact on an ARM64 Docker engine:
scripts/linux-smoke/run.sh --appimage /path/to/Vizor-linux-aarch64.AppImage \
  --platform linux/arm64 --distro ubuntu-24.04
```

Requires Docker with a running engine, Bash, and Python 3 on the host. First runs
download distribution images and runtime packages; later runs reuse cached image
layers. Targets run serially. The platform must match the AppImage. An emulated
run on a different CPU is useful for diagnosis, but does not replace a native
architecture release check.
On Apple Silicon, an amd64 container can run its system tools yet reject the
x86_64 AppImage runtime with `Exec format error` before extraction. That leaves
the app's x86_64 rendering unverified; use an x86_64 Linux machine or a full
x86_64 VM for that check. Record CPU emulation separately from native execution.

## What passes

1. Extract the input with `--appimage-extract`; keep its SHA-256 in `result.json`.
2. Inventory ELF dependencies and reject unresolved dependencies and bundled
   host libraries, including renamed files with forbidden SONAMEs. The explicit
   Vizor policy in `check_bundle.py` covers the desktop/graphics boundary from
   [#1036](https://github.com/chainapsis/vizor-wallet/issues/1036); it intentionally
   differs from linuxdeploy's default excludes. `host-libraries.txt` is shared
   with the packager's linuxdeploy exclusions and GStreamer dependency copier.
   App/Flutter/GStreamer libraries are allowed. The legacy `libjpeg.so.8` and
   `libbz2.so.1.0` ABIs remain bundled for camera/GStreamer dependencies; Fedora
   supplies different JPEG/bzip2 SONAMEs. This check does not rewrite the input.
3. Launch the extracted **AppRun** on a private Xvfb display and D-Bus session,
   with Mesa llvmpipe. Use OCR to find `Import wallet` in the client screenshot,
   click it, and require `Import secret passphrase` on the next screen. The app
   must stay alive. Native window titles are not evidence of a Flutter frame.
4. Fail on library-symbol and GL-rendering errors even if the screens appeared.

The container runs as an unprivileged user with a disposable HOME/keyring, no
network, no host display/device access, and only the input file mounted read-only.
It creates no wallet, imports no seed, and sends no transactions. Onboarding copy
changes may require updating the two OCR phrases; keep screenshots when a match
fails rather than relaxing the check to process liveness.

## Evidence and failures

The runner prints a new directory below `build/linux-smoke/` (ignored by Git).
`--output <new-directory>` chooses another location and refuses an existing path.
The run's top-level `host.json` records the requested platform and Docker engine
architecture so an emulated run can be distinguished from a native one.
Each target retains:

- `result.json`: pass/fail, input hash, environment, bundle/UI verdicts, failures.
- `bundle.json`: bundled-library violations and per-ELF `ldd` results.
- `welcome.png`, `import-method.png` and OCR TSVs: actual client screenshots.
  A failed capture retains its most recent screenshot when a window existed.
  `*-ocr.png` holds enlarged grayscale OCR input; TSV coordinates are at 3x scale.
- `app.log`, `keyring.log`, `openbox.log`, `extract.log`, `glxinfo.txt`, and
  `os-release.txt`: runtime evidence.
- `build.log`, `container.log`, `image.json`: infrastructure logs and image IDs.

Nonzero exit blocks the check. A build/setup error is an infrastructure failure,
not proof of an app regression; inspect the retained logs. Bundle failures do not
skip the UI check, so one run can expose both packaging and rendering failures.
Runtime-loaded modules still require execution; `ldd` alone cannot cover them.

Containers are removed after evidence is copied, including on failure/interruption.
The named `vizor-linux-smoke:*` images are retained as a cache. Remove only those
images explicitly when no longer needed; do not prune unrelated Docker resources.

## Before a release

Run the local command after packaging and before publishing, against each
architecture/flavor artifact:

```bash
scripts/linux-smoke/run.sh \
  --appimage dist/linux/appimage/Vizor-linux-x86_64.AppImage \
  --output build/linux-smoke-release
```

Run aarch64 candidates with `--platform linux/arm64` on an ARM64 machine. Preserve
evidence with the candidate's hash, and run the native positive/negative window
controls in each image as shown below. Keep their output as `controls.log` to
distinguish a broken test environment from a failing candidate.

Before a release, also check the **unextracted AppImage** on clean desktop systems:
X11 and Wayland sessions, Intel/AMD Mesa and NVIDIA hardware (including PRIME when
available). Confirm launch/unlock, keyring persistence across restart, camera QR,
and any hardware-wallet flow in scope. Containers do not validate FUSE, native
Wayland, actual GPU drivers, USB permissions, or existing-wallet recovery. The
fresh offline onboarding check does not claim to reproduce the locked-wallet
state from #1036.

## Run inside a test VM

UTM can run a full x86_64 guest on Apple Silicon, including the original AppImage
runtime and FUSE. Use a disposable VM clone and a fresh Linux test account, then
copy the candidate and this directory into it. On Ubuntu 24.04, install:

```bash
sudo apt-get update
sudo apt-get install -y libfuse2t64 libgles2 xvfb xauth dbus-x11 openbox mesa-utils \
  xdotool scrot tesseract-ocr python3-pil python3-gi gir1.2-gtk-3.0 \
  gnome-keyring binutils

# Run as the test user, never root. Choose a new evidence directory.
GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a -s '-screen 0 1600x1000x24' \
  dbus-run-session -- python3 scripts/linux-smoke/smoke.py \
  --appimage /path/to/Vizor-linux-x86_64.AppImage --launch-appimage \
  --output /tmp/vizor-appimage-evidence --timeout 180
```

The same bundle and rendered-navigation checks run, but `--launch-appimage`
executes the unextracted AppImage via FUSE after inspecting its extracted copy.
Keep the VM configuration, OS version and emulator/native CPU distinction beside
the evidence. This remains an isolated X11/software-rendering check. For desktop
session checks, log into the test account under X11 and Wayland separately and
launch the original candidate there. UTM's virtual display does not validate
Intel/NVIDIA/AMD driver combinations; unlock/persistence, camera and USB need
their own observed results.

For a small reusable desktop matrix, keep Ubuntu 24.04 GNOME X11, Mint 22.3
Cinnamon X11 (the reported distribution), and Fedora 44 GNOME Wayland guests.
Install each OS to its own virtual disk and detach the installer ISO before
using it as a persistent fixture. A live session's automatic login may leave
the login keyring unavailable; use a fresh test account with ordinary password
login for the persistence checks.

Use the exact same candidate SHA-256 in every guest and record these separately
from the isolated Xvfb result:

1. Record the OS, architecture, desktop, X11/Wayland backend and renderer.
2. Launch the unextracted AppImage and observe both welcome and import screens.
3. Create an empty disposable wallet through the UI. Keep its public test name
   and account UUID as evidence; do not retain secret-phrase screenshots or copy
   the keyring into the evidence directory.
4. Close the app normally, reopen it, require the unlock screen, and unlock to
   the same account's home screen.
5. Reboot the guest, log in normally, and repeat the unlock/account check.
6. Preserve screenshots, logs and bundle results. Record graphics warnings even
   when a later frame renders successfully; a partial UI check is not a clean
   rendering pass.

If the desktop Secret Service advertises a login collection but reports that
its object does not exist, retain that error as a fixture failure. An ordinary
password login alone may not resolve a first-login keyring problem (see
[GNOME Keyring first-run report](https://bugs.debian.org/1035061)). Record any
keyring-service restart or test-profile repair, then repeat the persistence
checks after a guest reboot. A successful repaired fixture is not evidence
that an untouched first-login environment passed. Never repair a user wallet
or erase its keyring as part of this smoke check.

Also run an **existing-wallet replacement** check in a separate disposable
account: create an empty wallet with the previous release, close it normally,
and launch the candidate with the same application identity, HOME and keyring.
Require the existing password to unlock the same account, verify backup-phrase
access without retaining words or private screenshots, then reboot and repeat.
Read-only fingerprints can establish that the mnemonic/password records were
preserved; a public UUID alone cannot. Restarting a container or Secret Service
session is useful persistence evidence, but is not an OS-reboot check.

Installed guests can be reused for later candidates, with a fresh test account
or restored clean snapshot. Preserve the original wallet fixture when checking
an upgrade. These VM checks cover distribution/session differences; physical
GPU, camera and hardware-wallet checks remain separate release evidence.

## Test the harness

```bash
python3 scripts/linux-smoke/test_smoke.py

# After the Ubuntu image has been built by run.sh:
docker run --rm --init --network none \
  --env VIZOR_SMOKE_NATIVE_CONTROLS=1 \
  --entrypoint xvfb-run vizor-linux-smoke:ubuntu-24.04-arm64 \
  -a -s '-screen 0 1600x1000x24' dbus-run-session -- \
  python3 /opt/linux-smoke/test_smoke.py
```

The native controls exercise a working GTK app, a live black window with a
matching title, rendering errors despite visible UI, and a forbidden bundled
library despite working UI. They verify the harness, not Flutter compatibility.

References: [AppImage testing](https://docs.appimage.org/packaging-guide/testing.html),
[Mesa software rendering](https://docs.mesa3d.org/envvars.html),
[Tesseract CLI](https://tesseract-ocr.github.io/tessdoc/Command-Line-Usage.html).
