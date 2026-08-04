#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
skip_download=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-download) skip_download=true; shift ;;
    -h|--help) echo "Usage: setup.sh [--skip-download]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
if [[ "$skip_download" == false ]]; then bash "$ROOT_DIR/release-assets/download-release-assets.sh"; fi
bash "$ROOT_DIR/runtime/install-runtime.sh"
bash "$ROOT_DIR/stable/prepare-stable.sh"
echo "Volcano Performance Guard setup completed"
