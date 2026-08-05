#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: import-version-deps.sh --runtime-dir PATH --asset-dir PATH
                              [--runner-image NAME] [--expected-commit SHA]

OFFLINE IMPORT. Verify a version-bound Go module supplement and build a
derived Runner with Docker build networking disabled. The source checkout is
not modified.
EOF
}

runtime_dir=""
asset_dir=""
runner_image=""
expected_commit=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --asset-dir) asset_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --expected-commit) expected_commit="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$runtime_dir" ]] || die "--runtime-dir is required"
[[ -n "$asset_dir" ]] || die "--asset-dir is required"
require_cmd awk docker sha256sum
runtime_dir="$(resolve_directory "$runtime_dir")"
asset_dir="$(resolve_directory "$asset_dir")"

for file in go-mod-supplement.tar.gz go-mod-supplement.tar.gz.sha256 candidate-commit.txt base-runner-image.txt; do
  [[ -f "$asset_dir/$file" ]] || die "Version dependency asset is missing: $file"
done
(
  cd -- "$asset_dir"
  sha256sum -c go-mod-supplement.tar.gz.sha256
)

version_commit="$(tr -d '\r\n' <"$asset_dir/candidate-commit.txt")"
base_runner="$(tr -d '\r\n' <"$asset_dir/base-runner-image.txt")"
[[ "$version_commit" =~ ^[0-9a-f]{40}$ ]] || die "Invalid version commit in dependency asset"
[[ -z "$expected_commit" || "$version_commit" == "$expected_commit" ]] || \
  die "Version dependency asset commit mismatch: expected=$expected_commit asset=$version_commit"
expected_base="$(awk -F= '$1 == "RUNNER_IMAGE" {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' \
  "$runtime_dir/runtime.env" | tr -d '\r')"
[[ "$base_runner" == "$expected_base" ]] || \
  die "Dependency asset base Runner mismatch: asset=$base_runner runtime=$expected_base"
docker image inspect "$base_runner" >/dev/null 2>&1 || die "Offline Runner image is missing: $base_runner"

if [[ -z "$runner_image" ]]; then
  runner_image="volcano-version-runner:$version_commit"
fi

docker buildx build \
  --network=none \
  --load \
  --build-arg "BASE_RUNNER=$base_runner" \
  --build-arg "CANDIDATE_COMMIT=$version_commit" \
  --label "io.volcano.performance-guard.version.commit=$version_commit" \
  --label "io.volcano.performance-guard.asset=go-module-supplement" \
  -t "$runner_image" \
  -f "$script_dir/candidate-deps.Dockerfile" \
  "$asset_dir"

docker image inspect "$runner_image" >/dev/null
log_info "Offline version Runner is available: $runner_image"
