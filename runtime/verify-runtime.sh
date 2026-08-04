#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/runtime/runtime.env"
assets_dir="${PERFORMANCE_GUARD_ASSETS_DIR:-$ROOT_DIR/release-assets}"

usage() { echo "Usage: runtime/verify-runtime.sh [--assets-dir PATH]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --assets-dir) assets_dir="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
assets_dir="$(cd -- "$assets_dir" && pwd -P)"
[[ "$(uname -m)" == x86_64 ]] || { echo "Runtime requires linux/amd64" >&2; exit 1; }
for command in docker sha256sum; do command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }; done
for wrapper in kind docker; do [[ -s "$ROOT_DIR/runtime/bin/$wrapper" ]] || { echo "Missing runtime wrapper: $wrapper" >&2; exit 1; }; done
[[ -f "$assets_dir/SHA256SUMS" ]] || { echo "Missing Release checksum file: $assets_dir/SHA256SUMS" >&2; exit 1; }
(cd "$assets_dir" && sha256sum -c SHA256SUMS)
echo "Runtime Release assets verified: $assets_dir"
