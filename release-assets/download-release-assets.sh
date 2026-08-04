#!/usr/bin/env bash
set -euo pipefail

ASSETS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$ASSETS_DIR/release.env"
repository="${PERFORMANCE_GUARD_RELEASE_REPOSITORY:-$RELEASE_REPOSITORY}"
tag="${PERFORMANCE_GUARD_RELEASE_TAG:-$RELEASE_TAG}"

expected_hash() {
  awk -v wanted="$1" '$2 == wanted {print $1; found=1} END {if (!found) exit 1}' \
    "$ASSETS_DIR/SHA256SUMS"
}

checksum_file="$ASSETS_DIR/SHA256SUMS"
if [[ ! -s "$checksum_file" ]]; then
  temporary="$checksum_file.part"
  echo "Downloading SHA256SUMS from $repository $tag"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 15 \
    -o "$temporary" "https://github.com/$repository/releases/download/$tag/SHA256SUMS"
  mv "$temporary" "$checksum_file"
fi

for asset in $RELEASE_ASSETS; do
  destination="$ASSETS_DIR/$asset"
  expected="$(expected_hash "$asset")"
  if [[ -f "$destination" ]] \
      && printf '%s  %s\n' "$expected" "$destination" | sha256sum -c - >/dev/null 2>&1; then
    continue
  fi
  temporary="$destination.part"
  echo "Downloading $asset from $repository $tag"
  curl -fL --retry 5 --retry-all-errors --connect-timeout 15 \
    -o "$temporary" "https://github.com/$repository/releases/download/$tag/$asset"
  mv "$temporary" "$destination"
done
(cd "$ASSETS_DIR" && sha256sum -c SHA256SUMS)
echo "Release assets are ready: $ASSETS_DIR"
