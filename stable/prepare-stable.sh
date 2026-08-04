#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/stable/stable.env"
assets_dir="${PERFORMANCE_GUARD_ASSETS_DIR:-$ROOT_DIR/release-assets}"
target="$ROOT_DIR/$STABLE_DIRECTORY"

if [[ -d "$target/.git" ]]; then
  git -C "$target" config core.filemode false
  if [[ "$(git -C "$target" rev-parse HEAD 2>/dev/null || true)" == "$STABLE_COMMIT" ]] \
      && [[ -z "$(git -C "$target" status --porcelain 2>/dev/null)" ]]; then
    echo "Stable Volcano is ready: $target ($STABLE_COMMIT)"
    exit 0
  fi
fi
[[ ! -e "$target" ]] || { echo "Refusing to replace invalid stable directory: $target" >&2; exit 1; }
archive="$assets_dir/$STABLE_ARCHIVE"
if [[ ! -f "$archive" ]]; then
  bash "$ROOT_DIR/release-assets/download-release-assets.sh"
fi
[[ -f "$archive" ]] || { echo "Missing stable Release asset: $archive" >&2; exit 1; }
mkdir -p "$(dirname "$target")"
temporary="$(dirname "$target")/.volcano.extract.$$"
mkdir -p "$temporary"
trap 'rm -rf -- "$temporary"' EXIT
tar -xzf "$archive" -C "$temporary"
[[ -d "$temporary/volcano/.git" ]] || { echo "Stable archive has no volcano/.git" >&2; exit 1; }
git -C "$temporary/volcano" config core.filemode false
[[ "$(git -C "$temporary/volcano" rev-parse HEAD)" == "$STABLE_COMMIT" ]] || { echo "Stable commit mismatch" >&2; exit 1; }
[[ -z "$(git -C "$temporary/volcano" status --porcelain)" ]] || { echo "Stable archive is dirty" >&2; exit 1; }
mv "$temporary/volcano" "$target"
echo "Stable Volcano prepared: $target ($STABLE_COMMIT)"
