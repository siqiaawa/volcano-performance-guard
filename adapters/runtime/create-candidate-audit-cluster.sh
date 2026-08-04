#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: create-candidate-audit-cluster.sh --runtime-dir PATH --candidate-dir PATH
                                        --runner-image NAME --cluster-name NAME
                                        --state-dir PATH --asset-dir PATH
                                        [--workers N] [--prometheus-port N]
                                        [--grafana-port N]

Create an isolated audit-enabled Kind cluster with public node egress blocked.
The cluster is protected by a marker and cannot reuse the smoke cluster name.
EOF
}

runtime_dir=""; candidate_dir=""; runner_image=""; cluster_name=""; state_dir=""; asset_dir=""
workers=1; prometheus_port=30013; grafana_port=30014
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --cluster-name) cluster_name="${2:?}"; shift 2 ;;
    --state-dir) state_dir="${2:?}"; shift 2 ;;
    --asset-dir) asset_dir="${2:?}"; shift 2 ;;
    --workers) workers="${2:?}"; shift 2 ;;
    --prometheus-port) prometheus_port="${2:?}"; shift 2 ;;
    --grafana-port) grafana_port="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -n "$runtime_dir" && -n "$candidate_dir" && -n "$runner_image" && -n "$cluster_name" && -n "$state_dir" && -n "$asset_dir" ]] || die "All arguments are required"
[[ "$cluster_name" =~ ^volcano-candidate-audit(-[a-z0-9-]+)?$ ]] || die "Cluster name must start with volcano-candidate-audit"
[[ "$workers" =~ ^[0-9]+$ && "$prometheus_port" =~ ^[0-9]+$ && "$grafana_port" =~ ^[0-9]+$ ]] || die "workers and ports must be numeric"
[[ "$cluster_name" != "volcano-candidate-smoke" ]] || die "Audit cluster cannot reuse the smoke cluster"
require_cmd awk docker git sha256sum
runtime_dir="$(resolve_directory "$runtime_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
asset_dir="$(resolve_directory "$asset_dir")"
mkdir -p -- "$state_dir/audit-logs" "$state_dir/home" "$state_dir/go-build"
state_dir="$(resolve_directory "$state_dir")"
[[ ! -e "$state_dir/cluster.marker" ]] || die "Cluster marker already exists: $state_dir/cluster.marker"
[[ -f "$asset_dir/imported-manifest.json" ]] || die "Imported benchmark asset manifest is missing"
candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
kind_node_image="$(awk -F= '$1 == "KIND_NODE_IMAGE" {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' "$runtime_dir/runtime.env" | tr -d '\r')"
docker image inspect "$kind_node_image" >/dev/null 2>&1 || die "Kind node image is missing: $kind_node_image"

run_candidate=("$script_dir/run-candidate.sh" --runtime-dir "$runtime_dir" --candidate-dir "$candidate_dir" --runner-image "$runner_image" --state-dir "$state_dir" --output-dir "$state_dir" --network host --with-docker-socket --)
existing="$(${run_candidate[@]} kind get clusters 2>/dev/null || true)"
if grep -Fx "$cluster_name" <<<"$existing" >/dev/null; then
  die "Dedicated cluster already exists: $cluster_name"
fi

config="$state_dir/audit-kind-config.yaml"
bash "$script_dir/../../scripts/run-performance-tools.sh" "$script_dir/../../scripts/render-audit-kind-config.py" \
  --template "$candidate_dir/benchmark/config/kind-config.yaml" \
  --output "$config" \
  --policy-path "$candidate_dir/third_party/kube-apiserver-audit-exporter/audit-policy.yaml" \
  --audit-log-dir "$state_dir/audit-logs" \
  --prometheus-port "$prometheus_port" --grafana-port "$grafana_port" --workers "$workers"

"${run_candidate[@]}" kind create cluster --name "$cluster_name" --config /workspace/output/audit-kind-config.yaml --image "$kind_node_image" --wait 180s
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
    die "Public IPv4 egress is reachable from Kind node: $node"
  fi
done

asset_manifest_sha="$(sha256sum "$asset_dir/imported-manifest.json" | awk '{print $1}')"
cat >"$state_dir/cluster.marker" <<EOF
CLUSTER_NAME=$cluster_name
CANDIDATE_COMMIT=$candidate_commit
KIND_NODE_IMAGE=$kind_node_image
PUBLIC_IPV4_EGRESS=blocked
AUDIT_ENABLED=true
ASSET_MANIFEST_SHA256=$asset_manifest_sha
PROMETHEUS_PORT=$prometheus_port
GRAFANA_PORT=$grafana_port
EOF
"${run_candidate[@]}" kubectl get nodes -o wide
log_info "Audit-enabled candidate cluster is ready: $cluster_name"
