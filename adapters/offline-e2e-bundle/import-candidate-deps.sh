#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: import-candidate-deps.sh --bundle-dir PATH --asset-dir PATH
                                [--runner-image NAME] [--expected-commit SHA]

OFFLINE IMPORT. Verify a packaged Go module supplement and build a derived
Runner with Docker build networking disabled.
EOF
}

bundle_dir=""
asset_dir=""
runner_image=""
expected_commit=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir) bundle_dir="${2:?}"; shift 2 ;;
    --asset-dir) asset_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --expected-commit) expected_commit="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$bundle_dir" ]] || die "--bundle-dir is required"
[[ -n "$asset_dir" ]] || die "--asset-dir is required"
require_cmd awk docker sha256sum
bundle_dir="$(resolve_directory "$bundle_dir")"
asset_dir="$(resolve_directory "$asset_dir")"

for file in go-mod-supplement.tar.gz go-mod-supplement.tar.gz.sha256 candidate-commit.txt base-runner-image.txt; do
  [[ -f "$asset_dir/$file" ]] || die "Candidate dependency asset is missing: $file"
done
(
  cd -- "$asset_dir"
  sha256sum -c go-mod-supplement.tar.gz.sha256
)

candidate_commit="$(tr -d '\r\n' <"$asset_dir/candidate-commit.txt")"
base_runner="$(tr -d '\r\n' <"$asset_dir/base-runner-image.txt")"
[[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || die "Invalid candidate commit in dependency asset"
[[ -z "$expected_commit" || "$candidate_commit" == "$expected_commit" ]] || \
  die "Candidate dependency asset commit mismatch: expected=$expected_commit asset=$candidate_commit"
expected_base="$(awk -F= '$1 == "RUNNER_IMAGE" {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' \
  "$bundle_dir/offline.env" | tr -d '\r')"
[[ "$base_runner" == "$expected_base" ]] || \
  die "Dependency asset base Runner mismatch: asset=$base_runner bundle=$expected_base"
docker image inspect "$base_runner" >/dev/null 2>&1 || die "Offline Runner image is missing: $base_runner"

if [[ -z "$runner_image" ]]; then
  runner_image="volcano-candidate-runner:$candidate_commit"
fi

docker buildx build \
  --network=none \
  --load \
  --build-arg "BASE_RUNNER=$base_runner" \
  --build-arg "CANDIDATE_COMMIT=$candidate_commit" \
  --label "io.volcano.performance-guard.candidate.commit=$candidate_commit" \
  -t "$runner_image" \
  -f "$script_dir/candidate-deps.Dockerfile" \
  "$asset_dir"

docker image inspect "$runner_image" >/dev/null
log_info "Offline candidate Runner is available: $runner_image"
