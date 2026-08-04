#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: create-candidate-cluster.sh --runtime-dir PATH --candidate-dir PATH
                                   --runner-image NAME --cluster-name NAME
                                   --state-dir PATH

Create a dedicated one-node Kind cluster, configure the project registry
mirror, and reject public IPv4 egress from every Kind node.
EOF
}

runtime_dir=""
candidate_dir=""
runner_image=""
cluster_name=""
state_dir=""
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

[[ -n "$runtime_dir" && -n "$candidate_dir" && -n "$runner_image" && -n "$cluster_name" && -n "$state_dir" ]] || \
  die "--runtime-dir, --candidate-dir, --runner-image, --cluster-name, and --state-dir are required"
[[ "$cluster_name" =~ ^volcano-candidate-[a-z0-9-]+$ ]] || \
  die "Cluster name must start with volcano-candidate- and contain lowercase letters, digits, or hyphens"
require_cmd awk docker git
runtime_dir="$(resolve_directory "$runtime_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
mkdir -p -- "$state_dir"
state_dir="$(resolve_directory "$state_dir")"
[[ ! -e "$state_dir/cluster.marker" ]] || die "Cluster marker already exists: $state_dir/cluster.marker"

candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
kind_node_image="$(awk -F= '$1 == "KIND_NODE_IMAGE" {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' \
  "$runtime_dir/runtime.env" | tr -d '\r')"
docker image inspect "$kind_node_image" >/dev/null 2>&1 || die "Kind node image is missing: $kind_node_image"

run_candidate=(
  "$script_dir/run-candidate.sh"
  --runtime-dir "$runtime_dir"
  --candidate-dir "$candidate_dir"
  --runner-image "$runner_image"
  --state-dir "$state_dir"
  --network host
  --with-docker-socket
  --
)

existing="$(${run_candidate[@]} kind get clusters 2>/dev/null || true)"
if grep -Fx "$cluster_name" <<<"$existing" >/dev/null; then
  die "Dedicated cluster already exists: $cluster_name"
fi

"${run_candidate[@]}" kind create cluster \
  --name "$cluster_name" \
  --image "$kind_node_image" \
  --wait 180s

mapfile -t nodes < <("${run_candidate[@]}" kind get nodes --name "$cluster_name")
((${#nodes[@]} > 0)) || die "Kind created no nodes for $cluster_name"
for node in "${nodes[@]}"; do
  docker exec "$node" bash -c '
    set -euo pipefail
    iptables -N VOLCANO_OFFLINE_EGRESS 2>/dev/null || iptables -F VOLCANO_OFFLINE_EGRESS
    iptables -C OUTPUT -j VOLCANO_OFFLINE_EGRESS 2>/dev/null || iptables -I OUTPUT 1 -j VOLCANO_OFFLINE_EGRESS
    iptables -A VOLCANO_OFFLINE_EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    iptables -A VOLCANO_OFFLINE_EGRESS -d 127.0.0.0/8 -j RETURN
    iptables -A VOLCANO_OFFLINE_EGRESS -d 10.0.0.0/8 -j RETURN
    iptables -A VOLCANO_OFFLINE_EGRESS -d 172.16.0.0/12 -j RETURN
    iptables -A VOLCANO_OFFLINE_EGRESS -d 192.168.0.0/16 -j RETURN
    iptables -A VOLCANO_OFFLINE_EGRESS -d 169.254.0.0/16 -j RETURN
    iptables -A VOLCANO_OFFLINE_EGRESS -d 0.0.0.0/0 -j REJECT
  '
  if docker exec "$node" bash -c 'timeout 3 bash -c "</dev/tcp/1.1.1.1/443"' >/dev/null 2>&1; then
    die "Public IPv4 egress is still reachable from Kind node: $node"
  fi
  log_info "Public IPv4 egress rejected on Kind node: $node"
done

cat >"$state_dir/cluster.marker" <<EOF
CLUSTER_NAME=$cluster_name
CANDIDATE_COMMIT=$candidate_commit
KIND_NODE_IMAGE=$kind_node_image
PUBLIC_IPV4_EGRESS=blocked
EOF
"${run_candidate[@]}" kubectl get nodes -o wide
log_info "Dedicated candidate cluster is ready: $cluster_name"
