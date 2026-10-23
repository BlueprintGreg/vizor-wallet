# Linux AppImage fastlane

GitHub Actions 기준 Linux AppImage 외부 배포용 fastlane 설정입니다.

실행:

```bash
bundle exec fastlane linux build
bundle exec fastlane linux package
bundle exec fastlane linux release
```

`release` lane 순서:

1. mainnet/testnet flavor별 Linux Flutter bundle 생성
2. flavor별 AppDir 생성
3. flavor별 AppImage 생성
4. flavor별 embedded GPG signature, detached `.asc`, `.sha256` 생성
5. 산출물을 `dist/linux` 아래에 준비

GitHub Release 생성, asset 업로드, multi-arch update feed 생성, draft
publish는 deployment repo의 `Release` workflow가 담당합니다.

최종 AppImage의 배포판별 번들·렌더링 검사는
[`scripts/linux-smoke/README.md`](../../scripts/linux-smoke/README.md)를 참고하세요.
패키징 후 `scripts/linux-smoke/run.sh --appimage <산출물>`로 로컬에서 실행하고,
실행 결과와 스크린샷·로그를 배포 후보의 해시와 함께 보관하세요.

AppImage는 GTK/GLib와 데스크톱·그래픽 의존성을 호스트에서 사용합니다.
`scripts/linux-smoke/host-libraries.txt`를 linuxdeploy, GStreamer 의존성 복사,
최종 AppDir 검사에서 공통으로 사용합니다. 번들 금지 라이브러리나 누락·버전
불일치 의존성이 있으면 서명/패키징 전에 실패합니다. 빌드 환경에는 Python 3,
`readelf`(binutils), `ldd`가 필요합니다.

실행 환경에는 GTK 3, Secret Service 제공자, udev와 EGL/GLES/Mesa 또는
해당 GPU 드라이버가 필요합니다. 최소 설치·서버 환경은 추가 패키지가 필요할 수
있습니다. Ubuntu의 관련 패키지는 `libgtk-3-0`, `libsecret-1-0`, `libudev1`,
`libegl1`, `libgles2`, `libgl1-mesa-dri`이며 최신 배포판은 t64 패키지명을 사용합니다.
Fedora에서는 `gtk3`, `libsecret`, `systemd-libs`, `libglvnd-egl`, `libglvnd-gles`,
`libglvnd-glx`, `mesa-dri-drivers`를 확인하세요. GStreamer/카메라의 별도 ABI 의존성인
`libjpeg.so.8`과 `libbz2.so.1.0`은 번들에 유지합니다.

기본 release flavor는 `mainnet,testnet`입니다. 단일 flavor만 빌드하려면:

```bash
VIZOR_LINUX_FLAVOR=mainnet bundle exec fastlane linux package
VIZOR_LINUX_FLAVOR=testnet bundle exec fastlane linux package
VIZOR_LINUX_FLAVORS=mainnet,testnet bundle exec fastlane linux release
```

## Native build dependencies

Ledger USB uses HIDAPI's `linux-static-hidraw` backend. Install `libudev-dev`
and `pkg-config` in the Linux build environment (or distribution equivalents).
The release build script checks this before building; `libudev` remains a native
runtime dependency. The AppImage dependency collector includes linked libraries.
Bundles include the Ledger udev rule and host setup instructions under
`data/ledger-usb`; packaging never changes host USB permissions automatically.

## Required environment variables

- `RELEASE_REPOSITORY`
- `RELEASE_BUILD_NUMBER`
- `LINUX_APPIMAGE_GPG_PRIVATE_KEY`
- `LINUX_APPIMAGE_GPG_KEY_ID`

태그 기반 워크플로우가 아니면 아래도 필요합니다.

- `RELEASE_TAG`

## Optional environment variables

- `RELEASE_NAME`
- `GITHUB_RELEASE_PRERELEASE`
- `VIZOR_LINUX_FLAVOR`
- `VIZOR_LINUX_FLAVORS`
- `VIZOR_LINUX_ARCH`
- `FVM_BIN`
- `LINUXDEPLOY_BIN`
- `APPIMAGETOOL_BIN`
- `LINUX_APPIMAGE_GPG_PASSPHRASE`

## Asset names

mainnet:

- `Vizor-linux-x86_64.AppImage`
- `Vizor-linux-x86_64.AppImage.zsync`
- `Vizor-linux-x86_64.AppImage.sha256`
- `Vizor-linux-x86_64.AppImage.asc`
- `Vizor-linux-aarch64.AppImage`
- `Vizor-linux-aarch64.AppImage.zsync`
- `Vizor-linux-aarch64.AppImage.sha256`
- `Vizor-linux-aarch64.AppImage.asc`

testnet:

- `Vizor-Testnet-linux-x86_64.AppImage`
- `Vizor-Testnet-linux-x86_64.AppImage.zsync`
- `Vizor-Testnet-linux-x86_64.AppImage.sha256`
- `Vizor-Testnet-linux-x86_64.AppImage.asc`
- `Vizor-Testnet-linux-aarch64.AppImage`
- `Vizor-Testnet-linux-aarch64.AppImage.zsync`
- `Vizor-Testnet-linux-aarch64.AppImage.sha256`
- `Vizor-Testnet-linux-aarch64.AppImage.asc`

Stable AppImage update information uses GitHub Releases `latest` zsync entries
so stable AppImages can be updated by external AppImage update tools. Each
Linux CI job builds one native architecture by setting `VIZOR_LINUX_ARCH` to
`x86_64` or `aarch64`. Prerelease builds do not embed update information and do
not generate zsync assets.
