#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: build-candidate-audit-exporter.sh --bundle-dir PATH --candidate-dir PATH
                                        --runner-image NAME --output-dir PATH
                                        [--image NAME] [--expected-commit SHA]

Build the benchmark audit exporter from the candidate checkout with network
access disabled, then package it in an immutable, commit-labelled image.
EOF
}

bundle_dir=""
candidate_dir=""
runner_image=""
output_dir=""
image=""
expected_commit=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir) bundle_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    --image) image="${2:?}"; shift 2 ;;
    --expected-commit) expected_commit="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$bundle_dir" && -n "$candidate_dir" && -n "$runner_image" && -n "$output_dir" ]] || \
  die "--bundle-dir, --candidate-dir, --runner-image, and --output-dir are required"
require_cmd docker git sha256sum
bundle_dir="$(resolve_directory "$bundle_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
mkdir -p -- "$output_dir"
output_dir="$(resolve_directory "$output_dir")"

candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
[[ -z "$expected_commit" || "$candidate_commit" == "$expected_commit" ]] || \
  die "Candidate commit mismatch: expected=$expected_commit actual=$candidate_commit"
[[ -z "$(git -C "$candidate_dir" status --porcelain)" ]] || die "Candidate working tree is not clean"
[[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || die "Candidate HEAD is not a full commit SHA"
if [[ -z "$image" ]]; then
  image="volcanosh/kube-apiserver-audit-exporter:$candidate_commit"
fi
[[ "$image" =~ ^[A-Za-z0-9_./:@-]+$ ]] || die "Unsafe audit exporter image: $image"

binary="$output_dir/kube-apiserver-audit-exporter"
rm -f -- "$binary" "$output_dir/SHA256SUMS" "$output_dir/build-metadata.env"
# Build only the exporter package. The source checkout remains read-only and
# module access is provided by the already verified candidate Runner.
"$script_dir/run-candidate.sh" \
  --bundle-dir "$bundle_dir" \
  --candidate-dir "$candidate_dir" \
  --runner-image "$runner_image" \
  --output-dir "$output_dir" \
  --network none \
  -- bash -c 'set -euo pipefail; CGO_ENABLED=0 go build -o /workspace/output/kube-apiserver-audit-exporter ./third_party/kube-apiserver-audit-exporter/cmd/kube-apiserver-audit-exporter'

[[ -x "$binary" ]] || die "Audit exporter binary was not built: $binary"
(
  cd -- "$output_dir"
  sha256sum kube-apiserver-audit-exporter >SHA256SUMS
)

docker buildx build \
  --network=none \
  --load \
  --build-arg "CANDIDATE_COMMIT=$candidate_commit" \
  -t "$image" \
  -f "$script_dir/audit-exporter.Dockerfile" \
  "$output_dir"

revision="$(docker image inspect --format '{{index .Config.Labels "io.volcano.performance-guard.candidate.commit"}}' "$image")"
[[ "$revision" == "$candidate_commit" ]] || die "Audit exporter commit label mismatch: $image"
image_id="$(docker image inspect --format '{{.Id}}' "$image")"
cat >"$output_dir/build-metadata.env" <<EOF
CANDIDATE_COMMIT=$candidate_commit
IMAGE=$image
IMAGE_ID=$image_id
BUILD_NETWORK=none
SOURCE_MOUNT=read-only
EOF
log_info "Candidate audit exporter image is available: $image ($image_id)"
