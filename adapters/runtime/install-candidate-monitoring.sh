#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: install-candidate-monitoring.sh --runtime-dir PATH --candidate-dir PATH
                                      --runner-image NAME --state-dir PATH
                                      --asset-dir PATH --report-dir PATH
EOF
}

runtime_dir=""; candidate_dir=""; runner_image=""; state_dir=""; asset_dir=""; report_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --state-dir) state_dir="${2:?}"; shift 2 ;;
    --asset-dir) asset_dir="${2:?}"; shift 2 ;;
    --report-dir) report_dir="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -n "$runtime_dir" && -n "$candidate_dir" && -n "$runner_image" && -n "$state_dir" && -n "$asset_dir" && -n "$report_dir" ]] || die "All arguments are required"
require_cmd git docker
runtime_dir="$(resolve_directory "$runtime_dir")"; candidate_dir="$(resolve_directory "$candidate_dir")"; state_dir="$(resolve_directory "$state_dir")"; asset_dir="$(resolve_directory "$asset_dir")"
mkdir -p -- "$report_dir"; report_dir="$(resolve_directory "$report_dir")"
candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
grep -Fx "CANDIDATE_COMMIT=$candidate_commit" "$state_dir/cluster.marker" >/dev/null || die "Cluster marker mismatch"
grep -Fx 'AUDIT_ENABLED=true' "$state_dir/cluster.marker" >/dev/null || die "Cluster is not audit-enabled"
[[ -f "$candidate_dir/installer/volcano-monitoring.yaml" ]] || die "Candidate monitoring manifest is missing"
[[ -f "$candidate_dir/benchmark/manifests/audit-exporter/daemonset.yaml" ]] || die "Candidate audit manifest is missing"
[[ -f "$asset_dir/imported-manifest.json" ]] || die "Imported asset manifest is missing"

bash "$script_dir/../../scripts/run-performance-tools.sh" "$script_dir/../../scripts/render-monitoring-manifest.py" \
  --manifest "$candidate_dir/installer/volcano-monitoring.yaml" \
  --audit-manifest "$candidate_dir/benchmark/manifests/audit-exporter/daemonset.yaml" \
  --assets "$asset_dir/imported-manifest.json" \
  --output "$report_dir/monitoring.yaml" \
  --audit-output "$report_dir/audit-exporter.yaml"

run_candidate=("$script_dir/run-candidate.sh" --runtime-dir "$runtime_dir" --candidate-dir "$candidate_dir" --runner-image "$runner_image" --state-dir "$state_dir" --output-dir "$report_dir" --network host --with-docker-socket --)
"${run_candidate[@]}" kubectl create namespace volcano-monitoring --dry-run=client -o yaml | "${run_candidate[@]}" kubectl apply -f -
"${run_candidate[@]}" kubectl apply -f /workspace/output/monitoring.yaml
"${run_candidate[@]}" kubectl create configmap grafana-benchmark-dashboard \
  --from-file=volcano-benchmark.json=/workspace/volcano/benchmark/manifests/monitoring/grafana-dashboard.json \
  -n volcano-monitoring --dry-run=client -o yaml | "${run_candidate[@]}" kubectl apply -f -
"${run_candidate[@]}" kubectl apply -f /workspace/output/audit-exporter.yaml
patch='{"spec":{"template":{"spec":{"volumes":[{"name":"grafana-benchmark-dashboard","configMap":{"name":"grafana-benchmark-dashboard"}}],"containers":[{"name":"grafana","volumeMounts":[{"name":"grafana-benchmark-dashboard","mountPath":"/var/lib/grafana/dashboards/benchmark"}]}]}}}}'
"${run_candidate[@]}" kubectl patch deployment grafana -n volcano-monitoring --type=strategic -p "$patch" >/dev/null 2>&1 || true
"${run_candidate[@]}" kubectl rollout status deployment/prometheus-deployment -n volcano-monitoring --timeout=180s
"${run_candidate[@]}" kubectl rollout status deployment/kube-state-metrics -n volcano-monitoring --timeout=180s
"${run_candidate[@]}" kubectl rollout status deployment/grafana -n volcano-monitoring --timeout=180s
"${run_candidate[@]}" kubectl rollout status daemonset/kube-apiserver-audit-exporter -n volcano-monitoring --timeout=180s
"${run_candidate[@]}" kubectl get pods -n volcano-monitoring -o wide >"$report_dir/monitoring-pods.txt"
"${run_candidate[@]}" kubectl get --raw '/api/v1/namespaces/volcano-monitoring/services/http:kube-apiserver-audit-exporter:8080/proxy/metrics' >"$report_dir/audit-exporter-metrics.txt"
grep -F 'pod_scheduling_latency_seconds' "$report_dir/audit-exporter-metrics.txt" >/dev/null || die "Audit exporter did not expose scheduling metrics"
log_info "Candidate Prometheus, Grafana, kube-state-metrics, and Audit Exporter are ready"
