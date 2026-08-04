#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: build-candidate-images.sh --runtime-dir PATH --candidate-dir PATH
                                 --build-dir PATH [--expected-commit SHA]

Build candidate images offline by rebasing candidate binaries onto the
project's version-pinned component base images. Docker build network is none.
EOF
}

runtime_dir=""
candidate_dir=""
build_dir=""
expected_commit=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --build-dir) build_dir="${2:?}"; shift 2 ;;
    --expected-commit) expected_commit="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$runtime_dir" ]] || die "--runtime-dir is required"
[[ -n "$candidate_dir" ]] || die "--candidate-dir is required"
[[ -n "$build_dir" ]] || die "--build-dir is required"
require_cmd awk docker git sha256sum
runtime_dir="$(resolve_directory "$runtime_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
build_dir="$(resolve_directory "$build_dir")"

candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
[[ -z "$expected_commit" || "$candidate_commit" == "$expected_commit" ]] || \
  die "Candidate commit mismatch: expected=$expected_commit actual=$candidate_commit"
grep -Fx "CANDIDATE_COMMIT=$candidate_commit" "$build_dir/build-metadata.env" >/dev/null || \
  die "Binary build metadata does not match candidate commit"
(
  cd -- "$build_dir"
  sha256sum -c SHA256SUMS
)

reference_commit="$(awk -F= '$1 == "RUNTIME_BASE_COMMIT" {print $2; found=1} END {if (!found) exit 1}' \
  "$runtime_dir/runtime.env" | tr -d '\r')"
components=(scheduler controller-manager webhook-manager agent-scheduler agent)
: >"$build_dir/images.env"
for component in "${components[@]}"; do
  base_image="volcanosh/vc-$component:$reference_commit"
  candidate_image="volcanosh/vc-$component:$candidate_commit"
  docker image inspect "$base_image" >/dev/null 2>&1 || die "Reference runtime image is missing: $base_image"
  base_id="$(docker image inspect --format '{{.Id}}' "$base_image")"
  log_info "Building $candidate_image from offline runtime base $base_image"
  docker buildx build \
    --network=none \
    --load \
    --build-arg "BASE_IMAGE=$base_image" \
    --label "org.opencontainers.image.revision=$candidate_commit" \
    --label "io.volcano.performance-guard.reference-base=$base_image" \
    --label "io.volcano.performance-guard.reference-base-id=$base_id" \
    -t "$candidate_image" \
    -f "$script_dir/runtime-images/$component.Dockerfile" \
    "$build_dir"
  candidate_id="$(docker image inspect --format '{{.Id}}' "$candidate_image")"
  component_key="${component^^}"
  component_key="${component_key//-/_}"
  printf 'CANDIDATE_IMAGE_%s=%s\n' "$component_key" "$candidate_image" >>"$build_dir/images.env"
  printf 'CANDIDATE_IMAGE_ID_%s=%s\n' "$component_key" "$candidate_id" >>"$build_dir/images.env"
  printf 'REFERENCE_BASE_ID_%s=%s\n' "$component_key" "$base_id" >>"$build_dir/images.env"
done
log_info "Candidate images built with Docker build network disabled"
