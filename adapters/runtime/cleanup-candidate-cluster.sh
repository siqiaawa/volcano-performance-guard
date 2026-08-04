#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: cleanup-candidate-cluster.sh --runtime-dir PATH --candidate-dir PATH
                                    --runner-image NAME --cluster-name NAME
                                    --state-dir PATH

Delete only a marker-matched volcano-candidate-* Kind cluster.
EOF
}

runtime_dir=""; candidate_dir=""; runner_image=""; cluster_name=""; state_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --cluster-name) cluster_name="${2:?}"; shift 2 ;;
    --state-dir) state_dir="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ "$cluster_name" =~ ^volcano-candidate-[a-z0-9-]+$ ]] || die "Refusing unsafe cluster name"
runtime_dir="$(resolve_directory "$runtime_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
state_dir="$(resolve_directory "$state_dir")"
[[ -f "$state_dir/cluster.marker" ]] || die "Cluster marker is missing"
grep -Fx "CLUSTER_NAME=$cluster_name" "$state_dir/cluster.marker" >/dev/null || die "Cluster marker mismatch"

"$script_dir/run-candidate.sh" \
  --runtime-dir "$runtime_dir" \
  --candidate-dir "$candidate_dir" \
  --runner-image "$runner_image" \
  --state-dir "$state_dir" \
  --network host \
  --with-docker-socket \
  -- kind delete cluster --name "$cluster_name"
mv -- "$state_dir/cluster.marker" "$state_dir/cluster.cleaned.marker"
log_info "Deleted dedicated candidate cluster: $cluster_name"
