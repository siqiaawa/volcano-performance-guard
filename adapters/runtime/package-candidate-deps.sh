#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: package-candidate-deps.sh --runtime-dir PATH --candidate-dir PATH
                                 --missing-modules FILE --output-dir PATH
                                 --allow-network [--expected-commit SHA]
                                 [--goproxy URLS]

ONLINE PACKAGING ONLY. Download exactly the missing path@version entries into
a standalone Go module-cache supplement. This command refuses to run unless
--allow-network is explicit. It does not modify the Runtime or candidate.
EOF
}

runtime_dir=""
candidate_dir=""
missing_modules_file=""
output_dir=""
goproxy="https://proxy.golang.org,direct"
allow_network=false
expected_commit=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --missing-modules) missing_modules_file="${2:?}"; shift 2 ;;
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    --goproxy) goproxy="${2:?}"; shift 2 ;;
    --allow-network) allow_network=true; shift ;;
    --expected-commit) expected_commit="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$allow_network" == true ]] || die "Online packaging requires explicit --allow-network"
[[ -n "$runtime_dir" ]] || die "--runtime-dir is required"
[[ -n "$candidate_dir" ]] || die "--candidate-dir is required"
[[ -n "$missing_modules_file" ]] || die "--missing-modules is required"
[[ -n "$output_dir" ]] || die "--output-dir is required"
require_cmd awk docker git sha256sum

runtime_dir="$(resolve_directory "$runtime_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
[[ -f "$missing_modules_file" ]] || die "Missing module list not found: $missing_modules_file"
mkdir -p -- "$output_dir"
output_dir="$(resolve_directory "$output_dir")"

candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
[[ -z "$expected_commit" || "$candidate_commit" == "$expected_commit" ]] || \
  die "Candidate commit mismatch: expected=$expected_commit actual=$candidate_commit"
[[ -z "$(git -C "$candidate_dir" status --porcelain)" ]] || die "Candidate working tree is not clean"
runner_image="$(awk -F= '$1 == "RUNNER_IMAGE" {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' \
  "$runtime_dir/runtime.env" | tr -d '\r')"
docker image inspect "$runner_image" >/dev/null 2>&1 || die "Offline Runner image is missing: $runner_image"

mapfile -t missing_modules < <(awk 'NF && $1 !~ /^#/ {print}' "$missing_modules_file" | tr -d '\r')
((${#missing_modules[@]} > 0)) || die "Missing module list is empty; no supplement is required"
for module in "${missing_modules[@]}"; do
  [[ "$module" =~ ^[A-Za-z0-9._~+/-]+@[A-Za-z0-9._~+/-]+$ ]] || \
    die "Unsafe module reference: $module"
done

archive="$output_dir/go-mod-supplement.tar.gz"
rm -f -- "$archive" "$archive.sha256"

log_warn "ONLINE PACKAGING: downloading ${#missing_modules[@]} missing Go module(s) via $goproxy"
docker run --rm --network host \
  -e "GOPROXY=$goproxy" \
  -e GOSUMDB=off \
  -e GOTOOLCHAIN=local \
  -e GOFLAGS=-mod=readonly \
  -e GOMODCACHE=/tmp/go-mod-supplement \
  -v "$candidate_dir:/workspace/volcano:ro" \
  -v "$output_dir:/output" \
  -w /workspace/volcano \
  "$runner_image" \
  bash -c 'set -euo pipefail; go mod download "$@"; tar -C "$GOMODCACHE" -czf /output/go-mod-supplement.tar.gz .' \
  package-candidate-deps "${missing_modules[@]}"

(
  cd -- "$output_dir"
  sha256sum go-mod-supplement.tar.gz >go-mod-supplement.tar.gz.sha256
)
printf '%s\n' "$candidate_commit" >"$output_dir/candidate-commit.txt"
printf '%s\n' "$runner_image" >"$output_dir/base-runner-image.txt"
printf '%s\n' "${missing_modules[@]}" >"$output_dir/missing-modules.txt"
log_info "Go module supplement written to $archive"
