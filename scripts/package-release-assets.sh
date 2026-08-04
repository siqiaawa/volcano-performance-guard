#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/runtime/runtime.env"
source "$ROOT_DIR/stable/stable.env"
output_dir="$ROOT_DIR/release-assets"
stable_dir="$ROOT_DIR/$STABLE_DIRECTORY"
benchmark_archive="$ROOT_DIR/.work/offline-assets/benchmark-tools/$STABLE_COMMIT/benchmark-images.tar"

usage() {
  cat <<'EOF'
Usage: scripts/package-release-assets.sh [OPTIONS]

  --output-dir PATH          Flat Release asset directory
  --stable-dir PATH          Clean stable Volcano Git checkout
  --benchmark-archive PATH   Prebuilt performance tools/monitoring image tar
EOF
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    --stable-dir) stable_dir="${2:?}"; shift 2 ;;
    --benchmark-archive) benchmark_archive="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
for command in docker git sha256sum tar; do command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }; done
stable_dir="$(cd -- "$stable_dir" && pwd -P)"
[[ "$(git -C "$stable_dir" rev-parse HEAD)" == "$STABLE_COMMIT" ]] || { echo "Stable commit mismatch" >&2; exit 1; }
[[ -z "$(git -C "$stable_dir" status --porcelain)" ]] || { echo "Stable checkout is dirty" >&2; exit 1; }
[[ -f "$benchmark_archive" ]] || { echo "Missing Benchmark archive: $benchmark_archive" >&2; exit 1; }
mkdir -p "$output_dir"

components=(scheduler controller-manager webhook-manager agent-scheduler agent)
base_images=()
for component in "${components[@]}"; do base_images+=("volcanosh/vc-$component:$RUNTIME_BASE_COMMIT"); done
required_images=("$RUNNER_IMAGE" "$KIND_NODE_IMAGE" "$REGISTRY_IMAGE" busybox:latest "${base_images[@]}")
for image in "${required_images[@]}"; do docker image inspect "$image" >/dev/null 2>&1 || { echo "Missing image: $image" >&2; exit 1; }; done

docker save -o "$output_dir/$RUNTIME_RUNNER_ARCHIVE" "$RUNNER_IMAGE"
docker save -o "$output_dir/$RUNTIME_KIND_ARCHIVE" "$KIND_NODE_IMAGE"
docker save -o "$output_dir/$RUNTIME_BASES_ARCHIVE" "${base_images[@]}"
docker save -o "$output_dir/$RUNTIME_SUPPORT_ARCHIVE" "$REGISTRY_IMAGE" busybox:latest
cp -- "$benchmark_archive" "$output_dir/$BENCHMARK_IMAGES_ARCHIVE"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/volcano"
git -C "$temporary/volcano" init -q
git -C "$temporary/volcano" fetch -q --depth=1 --no-tags "$stable_dir" "$STABLE_COMMIT"
git -C "$temporary/volcano" checkout -q --detach FETCH_HEAD
git -C "$temporary/volcano" remote remove origin 2>/dev/null || true
tar -czf "$output_dir/$STABLE_ARCHIVE" -C "$temporary" volcano
(
  cd "$output_dir"
  rm -f SHA256SUMS
  sha256sum \
    "$RUNTIME_RUNNER_ARCHIVE" \
    "$RUNTIME_KIND_ARCHIVE" \
    "$RUNTIME_BASES_ARCHIVE" \
    "$RUNTIME_SUPPORT_ARCHIVE" \
    "$BENCHMARK_IMAGES_ARCHIVE" \
    "$STABLE_ARCHIVE" >SHA256SUMS
)
echo "Release assets packaged in $output_dir"
