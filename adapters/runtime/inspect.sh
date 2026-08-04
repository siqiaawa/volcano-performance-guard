#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: inspect.sh --runtime-dir PATH [--output PATH]

Validate the project-owned Runtime structure and render its identity without
loading images or creating a cluster.
EOF
}

runtime_dir=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --output) output="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -n "$runtime_dir" ]] || die "--runtime-dir is required"
require_cmd awk sha256sum
runtime_dir="$(resolve_directory "$runtime_dir")"
project_dir="$(cd -- "$runtime_dir/.." && pwd -P)"

required_paths=(
  runtime.env
  install-runtime.sh
  verify-runtime.sh
  bin/kind
  bin/docker
  manifest/images-required.txt
  benchmark-assets/manifest.json
  benchmark-assets/SHA256SUMS
)
for relative in "${required_paths[@]}"; do
  [[ -s "$runtime_dir/$relative" ]] || die "Required Runtime path is missing: $relative"
done
[[ -s "$project_dir/stable/stable.env" ]] || die "Stable metadata is missing"

env_value() {
  local file=$1 key=$2 value
  value="$(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' "$file" | tr -d '\r')" || \
    die "$file is missing $key"
  printf '%s\n' "$value"
}
release_tag="$(env_value "$runtime_dir/runtime.env" RUNTIME_RELEASE_TAG)"
runner_image="$(env_value "$runtime_dir/runtime.env" RUNNER_IMAGE)"
kind_image="$(env_value "$runtime_dir/runtime.env" KIND_NODE_IMAGE)"
base_commit="$(env_value "$runtime_dir/runtime.env" RUNTIME_BASE_COMMIT)"
stable_commit="$(env_value "$project_dir/stable/stable.env" STABLE_COMMIT)"
required_count="$(awk 'NF && $1 !~ /^#/ {count++} END {print count+0}' "$runtime_dir/manifest/images-required.txt")"
fingerprint="$(
  sha256sum \
    "$runtime_dir/runtime.env" \
    "$runtime_dir/bin/kind" \
    "$runtime_dir/bin/docker" \
    "$runtime_dir/manifest/images-required.txt" \
    "$project_dir/stable/stable.env" \
    | awk '{print $1}' | sha256sum | awk '{print "sha256:" $1}'
)"

render() {
  cat <<EOF
schemaVersion: v1
runtime:
  name: volcano-performance-guard-runtime
  version: $release_tag
  fingerprint: $fingerprint
  platform: linux/amd64
stableVolcano:
  commit: $stable_commit
runtimeBase:
  commit: $base_commit
toolchain:
  runnerImage: $runner_image
  kindNodeImage: $kind_image
assets:
  requiredImageTags: $required_count
  releaseDirectory: release-assets
capabilities:
  localRegistryMirror: true
  externalVolcanoRepositoryRequired: false
  onlineGoModuleCache: true
  communityBenchmark: true
  upstreamE2E: false
EOF
}
if [[ -n "$output" ]]; then
  mkdir -p -- "$(dirname -- "$output")"
  render >"${output}.tmp.$$"
  mv -- "${output}.tmp.$$" "$output"
  cat -- "$output"
else
  render
fi
