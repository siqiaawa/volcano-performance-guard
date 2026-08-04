#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: build-candidate-binaries.sh --runtime-dir PATH --candidate-dir PATH
                                   --runner-image NAME --output-dir PATH
                                   [--expected-commit SHA]

Build candidate component binaries in the project Runtime Runner. Network mode is none
unless PERFORMANCE_GUARD_NETWORK_MODE=host is explicitly set. Candidate source
is read-only and all outputs are external.
EOF
}

runtime_dir=""
candidate_dir=""
runner_image=""
output_dir=""
expected_commit=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    --expected-commit) expected_commit="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$runtime_dir" ]] || die "--runtime-dir is required"
[[ -n "$candidate_dir" ]] || die "--candidate-dir is required"
[[ -n "$runner_image" ]] || die "--runner-image is required"
[[ -n "$output_dir" ]] || die "--output-dir is required"
require_cmd git sha256sum
network_mode="${PERFORMANCE_GUARD_NETWORK_MODE:-none}"
[[ "$network_mode" == "none" || "$network_mode" == "host" ]] || \
  die "PERFORMANCE_GUARD_NETWORK_MODE must be none or host"
candidate_dir="$(resolve_directory "$candidate_dir")"
candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
[[ -z "$expected_commit" || "$candidate_commit" == "$expected_commit" ]] || \
  die "Candidate commit mismatch: expected=$expected_commit actual=$candidate_commit"
[[ -z "$(git -C "$candidate_dir" status --porcelain)" ]] || die "Candidate working tree is not clean"
build_date="$(git -C "$candidate_dir" show -s --format=%cI HEAD)"

mkdir -p -- "$output_dir"
output_dir="$(resolve_directory "$output_dir")"
rm -rf -- "$output_dir/bin" "$output_dir/assets"
mkdir -p -- "$output_dir/bin" "$output_dir/assets"

"$script_dir/run-candidate.sh" \
  --runtime-dir "$runtime_dir" \
  --candidate-dir "$candidate_dir" \
  --runner-image "$runner_image" \
  --output-dir "$output_dir" \
  --network "$network_mode" \
  -- make image_bins \
    OUTPUT_DIR=/workspace/output \
    "TAG=$candidate_commit" \
    "RELEASE_VER=$candidate_commit" \
    "Date=$build_date"

expected_binaries=(
  vc-scheduler
  vc-controller-manager
  vc-webhook-manager
  vc-agent-scheduler
  vc-agent
  network-qos
)
for binary in "${expected_binaries[@]}"; do
  [[ -x "$output_dir/bin/$binary" ]] || die "Candidate binary is missing or not executable: $binary"
done

cp -- "$candidate_dir/installer/dockerfile/webhook-manager/gen-admission-secret.sh" \
  "$output_dir/assets/gen-admission-secret.sh"
cp -- "$candidate_dir/installer/build/volcano-agent/install.sh" \
  "$output_dir/assets/volcano-agent-install.sh"
chmod +x "$output_dir/assets/gen-admission-secret.sh" "$output_dir/assets/volcano-agent-install.sh"

(
  cd -- "$output_dir"
  sha256sum bin/* assets/* >SHA256SUMS
)
cat >"$output_dir/build-metadata.env" <<EOF
CANDIDATE_COMMIT=$candidate_commit
CANDIDATE_TREE=$(git -C "$candidate_dir" rev-parse 'HEAD^{tree}')
CANDIDATE_BUILD_DATE=$build_date
CANDIDATE_RUNNER_IMAGE=$runner_image
BUILD_NETWORK=$network_mode
SOURCE_MOUNT=read-only
EOF
log_info "Candidate binaries written to $output_dir"
