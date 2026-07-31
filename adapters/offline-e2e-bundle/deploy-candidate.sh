#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: deploy-candidate.sh --bundle-dir PATH --candidate-dir PATH
                           --runner-image NAME --cluster-name NAME
                           --state-dir PATH --report-dir PATH

Render and install the candidate checkout's own Helm chart into the dedicated
cluster. Every Volcano component image must use the candidate commit tag.
EOF
}

bundle_dir=""; candidate_dir=""; runner_image=""; cluster_name=""; state_dir=""; report_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir) bundle_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --cluster-name) cluster_name="${2:?}"; shift 2 ;;
    --state-dir) state_dir="${2:?}"; shift 2 ;;
    --report-dir) report_dir="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -n "$bundle_dir" && -n "$candidate_dir" && -n "$runner_image" && -n "$cluster_name" && -n "$state_dir" && -n "$report_dir" ]] || \
  die "All path, image, and cluster arguments are required"
require_cmd git grep
bundle_dir="$(resolve_directory "$bundle_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
state_dir="$(resolve_directory "$state_dir")"
mkdir -p -- "$report_dir"
report_dir="$(resolve_directory "$report_dir")"
candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
grep -Fx "CLUSTER_NAME=$cluster_name" "$state_dir/cluster.marker" >/dev/null || die "Cluster marker mismatch"
grep -Fx "CANDIDATE_COMMIT=$candidate_commit" "$state_dir/cluster.marker" >/dev/null || die "Candidate marker mismatch"

run_candidate=(
  "$script_dir/run-candidate.sh"
  --bundle-dir "$bundle_dir"
  --candidate-dir "$candidate_dir"
  --runner-image "$runner_image"
  --state-dir "$state_dir"
  --network host
  --with-docker-socket
  --
)

chart=/workspace/volcano/installer/helm/chart/volcano
helm_args=(
  --namespace volcano-system
  --set-string "basic.image_tag_version=$candidate_commit"
  --set basic.image_pull_policy=Always
  --set custom.metrics_enable=false
)

"${run_candidate[@]}" helm template volcano "$chart" "${helm_args[@]}" >"$report_dir/rendered-candidate.yaml"
mapfile -t rendered_images < <(grep -E '^[[:space:]]+image: .*/volcanosh/vc-' "$report_dir/rendered-candidate.yaml" | awk '{print $2}' | sort -u)
((${#rendered_images[@]} > 0)) || die "Rendered candidate chart did not contain Volcano component images"
for image in "${rendered_images[@]}"; do
  [[ "$image" == *":$candidate_commit" ]] || die "Rendered chart contains a mixed-version image: $image"
done
for component in scheduler controller-manager webhook-manager; do
  printf '%s\n' "${rendered_images[@]}" | grep -E "/volcanosh/vc-${component}:$candidate_commit$" >/dev/null || \
    die "Rendered candidate chart is missing the enabled core component: vc-$component"
done
date +%s >"$report_dir/deploy-start.epoch"
"${run_candidate[@]}" helm upgrade --install volcano "$chart" \
  --namespace volcano-system \
  --create-namespace \
  --wait \
  --timeout 5m \
  --set-string "basic.image_tag_version=$candidate_commit" \
  --set basic.image_pull_policy=Always \
  --set custom.metrics_enable=false
"${run_candidate[@]}" kubectl get all -n volcano-system -o wide >"$report_dir/volcano-system.txt"
log_info "Candidate chart deployed from commit $candidate_commit"
