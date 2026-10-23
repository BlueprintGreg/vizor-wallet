#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
appimage=""
distro=all
platform=linux/amd64
output=""
container=""

usage() {
  cat <<'USAGE'
Usage: scripts/linux-smoke/run.sh --appimage <path> [options]

Test the final AppImage without building Flutter or accessing a host wallet.

  --distro <name>       all (default), ubuntu-22.04, ubuntu-24.04, fedora-44
  --platform <name>     linux/amd64 (default) or linux/arm64; match the artifact
  --output <directory>  New evidence directory; default: build/linux-smoke/run.XXXXXX
  -h, --help           Show this help

Requires Docker, Python 3, and a running Docker engine. Images build serially.
Nonzero exit means a bundle/UI check or the test infrastructure failed.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --appimage|--distro|--platform|--output)
      [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; exit 2; }
      case "$1" in
        --appimage) appimage="$2" ;;
        --distro) distro="$2" ;;
        --platform) platform="$2" ;;
        --output) output="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -f "$appimage" ]] || { echo '--appimage must name an existing file' >&2; exit 2; }
case "$platform" in linux/amd64|linux/arm64) ;; *) echo 'Unsupported platform' >&2; exit 2 ;; esac
case "$distro" in
  all) distros=(ubuntu-22.04 ubuntu-24.04 fedora-44) ;;
  ubuntu-22.04|ubuntu-24.04|fedora-44) distros=("$distro") ;;
  *) echo "Unsupported distro: $distro" >&2; exit 2 ;;
esac
command -v python3 >/dev/null
command -v docker >/dev/null
docker info >/dev/null
appimage="$(python3 -c 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())' "$appimage")"
# Docker's --mount CSV syntax cannot represent commas in source paths.
[[ "$appimage" != *,* ]] || { echo 'AppImage path must not contain commas' >&2; exit 2; }
if [[ -z "$output" ]]; then
  mkdir -p "$script_dir/../../build/linux-smoke"
  output="$(mktemp -d "$script_dir/../../build/linux-smoke/run.XXXXXX")"
else
  mkdir -p "$(dirname "$output")"
  mkdir "$output" # Refuse to overwrite evidence from a previous run.
fi
output="$(cd "$output" && pwd)"
engine_arch="$(docker info --format '{{.Architecture}}')"
python3 - "$output" "$platform" "$engine_arch" <<'PY'
import json
from pathlib import Path
import sys
Path(sys.argv[1], "host.json").write_text(json.dumps({
    "requested_platform": sys.argv[2], "docker_engine_architecture": sys.argv[3],
}, indent=2) + "\n")
PY
cleanup() {
  if [[ -n "$container" ]]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

status=0
for current in "${distros[@]}"; do
  evidence="$output/$current"
  mkdir "$evidence"
  image="vizor-linux-smoke:$current-${platform#linux/}"
  build_args=()
  case "$current" in
    ubuntu-*) dockerfile=ubuntu.Dockerfile; build_args=(--build-arg "UBUNTU_VERSION=${current#ubuntu-}") ;;
    fedora-44) dockerfile=fedora.Dockerfile ;;
  esac
  echo "Building $current ($platform); log: $evidence/build.log"
  if ! docker build --platform "$platform" ${build_args[@]+"${build_args[@]}"} \
    -f "$script_dir/containers/$dockerfile" -t "$image" "$script_dir" >"$evidence/build.log" 2>&1; then
    echo "FAIL: $current image build; see $evidence/build.log" >&2
    status=1
    continue
  fi
  docker image inspect "$image" >"$evidence/image.json"
  image_id="$(docker image inspect --format '{{.Id}}' "$image")"
  container="vizor-linux-smoke-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
  echo "Testing $current; evidence: $evidence"
  if ! docker run --name "$container" --init --network none --shm-size=256m \
    --cap-drop ALL --security-opt no-new-privileges --platform "$platform" \
    --mount "type=bind,src=$appimage,dst=/input/Vizor.AppImage,readonly" \
    "$image_id" --appimage /input/Vizor.AppImage >"$evidence/container.log" 2>&1; then
    status=1
  fi
  if ! docker cp "$container:/tmp/evidence/." "$evidence/"; then
    echo "FAIL: $current did not produce evidence" >&2
    status=1
  fi
  cleanup
  container=""
  if [[ -f "$evidence/result.json" ]]; then cat "$evidence/result.json"; fi
done
echo "Evidence: $output"
exit "$status"
