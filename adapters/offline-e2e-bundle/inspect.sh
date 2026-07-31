#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: inspect.sh --bundle-dir PATH [--output PATH]

Read and validate the known offline E2E bundle structure without loading
images, creating a cluster, or changing the bundled Volcano checkout.
EOF
}

bundle_dir=""
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir)
      [[ $# -ge 2 ]] || die "--bundle-dir requires a value"
      bundle_dir="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value"
      output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$bundle_dir" ]] || die "--bundle-dir is required"
require_cmd awk find git sha256sum sort
bundle_dir="$(resolve_directory "$bundle_dir")"

required_paths=(
  README-离线部署.md
  offline.env
  verify-bundle.sh
  install-offline.sh
  run-env.sh
  volcano-shell.sh
  make-e2e.sh
  run-full-e2e.sh
  manifest/images-required.txt
  runner/bin/kind
  runner/bin/helm
  source/volcano/.git
)
for relative_path in "${required_paths[@]}"; do
  [[ -e "$bundle_dir/$relative_path" ]] || die "Required bundle path is missing: $relative_path"
done

env_value() {
  local key="$1" value
  value="$(awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' "$bundle_dir/offline.env" | tr -d '\r')" || \
    die "offline.env is missing $key"
  [[ "$value" =~ ^[A-Za-z0-9_./:@-]+$ ]] || die "offline.env contains an unsafe $key value"
  printf '%s\n' "$value"
}

volcano_commit="$(env_value VOLCANO_COMMIT)"
runner_image="$(env_value RUNNER_IMAGE)"
kind_node_image="$(env_value KIND_NODE_IMAGE)"
kubernetes_version="$(env_value KUBERNETES_VERSION)"
kind_version="$(env_value KIND_VERSION)"
ginkgo_version="$(env_value GINKGO_VERSION)"

source_commit="$(git -C "$bundle_dir/source/volcano" rev-parse HEAD)"
[[ "$source_commit" == "$volcano_commit" ]] || \
  die "Reference source commit mismatch: offline.env=$volcano_commit source=$source_commit"

source_clean=true
if [[ -n "$(git -C "$bundle_dir/source/volcano" status --porcelain --untracked-files=no)" ]]; then
  source_clean=false
fi
source_shallow="$(git -C "$bundle_dir/source/volcano" rev-parse --is-shallow-repository)"

required_image_count="$(awk 'NF && $1 !~ /^#/ {count++} END {print count+0}' "$bundle_dir/manifest/images-required.txt")"
image_archive_count="$(find "$bundle_dir/images" -maxdepth 1 -type f -name '*.tar' -print | awk 'END {print NR+0}')"
chart_archive_count="$(find "$bundle_dir/charts" -maxdepth 1 -type f -name '*.tgz' -print | awk 'END {print NR+0}')"

mapfile -t identity_files < <(
  {
    printf '%s\n' "$bundle_dir/offline.env" "$bundle_dir/manifest/images-required.txt"
    find "$bundle_dir/images" -maxdepth 1 -type f -name '*.sha256' -print
    find "$bundle_dir/charts" -maxdepth 1 -type f -name '*.tgz' -print
  } | sort
)
bundle_fingerprint="$(
  for identity_file in "${identity_files[@]}"; do
    sha256sum "$identity_file" | awk '{print $1}'
  done | sort | sha256sum | awk '{print "sha256:" $1}'
)"

render() {
  cat <<EOF
schemaVersion: v1
bundle:
  name: volcano-offline-e2e-bundle
  semanticVersion: null
  fingerprint: $bundle_fingerprint
  platform: linux/amd64
referenceVolcano:
  commit: $source_commit
  trackedSourceClean: $source_clean
  shallowCheckout: $source_shallow
toolchain:
  kubernetesVersion: $kubernetes_version
  kindVersion: $kind_version
  ginkgoVersion: $ginkgo_version
  runnerImage: $runner_image
  kindNodeImage: $kind_node_image
assets:
  imageArchives: $image_archive_count
  requiredImageTags: $required_image_count
  kwokChartArchives: $chart_archive_count
capabilities:
  checksumVerificationEntrypoint: true
  offlineInstallEntrypoint: true
  localRegistryMirror: true
  clusterDestroy: true
  nativeExternalCandidateSourceMount: false
performanceToolDelta:
  alreadyProvided:
    - kwok-v0.7.0
    - kwok-v0.8.0
    - kwok-chart-0.3.0
    - kwok-stage-fast-chart-0.3.0
  absentFromRequiredImageManifest:
    - prometheus
    - grafana
    - kube-state-metrics
    - kube-apiserver-audit-exporter
EOF
}

if [[ -n "$output" ]]; then
  mkdir -p -- "$(dirname -- "$output")"
  temporary_output="${output}.tmp.$$"
  render >"$temporary_output"
  mv -- "$temporary_output" "$output"
  cat -- "$output"
  log_info "Bundle inspection written to $output"
else
  render
fi
