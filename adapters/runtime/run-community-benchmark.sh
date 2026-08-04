#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: run-community-benchmark.sh --runtime-dir PATH --candidate-dir PATH
                                  --runner-image NAME --state-dir PATH
                                  --output-dir PATH --cluster-name NAME
                                  [--scenario pod|gang] [--count N]
                                   [--scheduler NAME] [--asset-dir PATH]
                                   [--use-kwok] [--prometheus-url URL]
                                   [--require-audit]

Run a small upstream community Benchmark scenario on an existing candidate
cluster. The candidate checkout is copied to a disposable container workspace;
the checkout itself remains read-only and all results are exported externally.
This path can reuse packaged KWOK charts. With --require-audit it also consumes
the imported Prometheus/Audit Exporter stack and refuses to pass without an
audit-derived latency report.
EOF
}

runtime_dir=""
candidate_dir=""
runner_image=""
state_dir=""
output_dir=""
cluster_name=""
scenario="pod"
count=10
scheduler="volcano"
asset_dir=""
use_kwok=false
prometheus_url=""
require_audit=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --state-dir) state_dir="${2:?}"; shift 2 ;;
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    --cluster-name) cluster_name="${2:?}"; shift 2 ;;
    --scenario) scenario="${2:?}"; shift 2 ;;
    --count) count="${2:?}"; shift 2 ;;
    --scheduler) scheduler="${2:?}"; shift 2 ;;
    --asset-dir) asset_dir="${2:?}"; shift 2 ;;
    --use-kwok) use_kwok=true; shift ;;
    --prometheus-url) prometheus_url="${2:?}"; shift 2 ;;
    --require-audit) require_audit=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$runtime_dir" && -n "$candidate_dir" && -n "$runner_image" && -n "$state_dir" && -n "$output_dir" && -n "$cluster_name" ]] || \
  die "All Runtime, candidate, Runner, state, output, and cluster arguments are required"
[[ "$scenario" == "pod" || "$scenario" == "gang" ]] || die "Scenario must be pod or gang"
[[ "$count" =~ ^[1-9][0-9]*$ ]] || die "Count must be a positive integer"
[[ "$scheduler" =~ ^[A-Za-z0-9._-]+$ ]] || die "Unsafe scheduler name"
[[ "$scenario" != "gang" || "$scheduler" == "volcano" ]] || \
  die "The upstream gang template is fixed to schedulerName=volcano"
require_cmd bash git docker
runtime_dir="$(resolve_directory "$runtime_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
state_dir="$(resolve_directory "$state_dir")"
mkdir -p -- "$output_dir"
output_dir="$(resolve_directory "$output_dir")"
rm -f -- \
  "$output_dir/benchmark-pods.json" \
  "$output_dir/benchmark-vcjobs.json" \
  "$output_dir/result.json" \
  "$output_dir/run-metadata.env" \
  "$output_dir/scheduler-before.json" \
  "$output_dir/scheduler-after.json" \
  "$output_dir/summary.md" \
  "$output_dir/test-pod.jsonl" \
  "$output_dir/test-pod.log" \
  "$output_dir/test-gang.jsonl" \
  "$output_dir/test-gang.log" \
  "$output_dir/audit-report.json" \
  "$output_dir/scheduler-samples.jsonl"
if [[ "$use_kwok" == true ]]; then
  [[ -n "$asset_dir" ]] || die "--asset-dir is required with --use-kwok"
  asset_dir="$(resolve_directory "$asset_dir")"
  [[ -f "$asset_dir/charts/kwok-chart-0.3.0.tgz" ]] || die "KWOK chart is missing"
  [[ -f "$asset_dir/charts/kwok-stage-fast-chart-0.3.0.tgz" ]] || die "KWOK stage chart is missing"
  rm -rf -- "$output_dir/asset-charts"
  mkdir -p -- "$output_dir/asset-charts"
  cp -- "$asset_dir/charts/kwok-chart-0.3.0.tgz" "$output_dir/asset-charts/"
  cp -- "$asset_dir/charts/kwok-stage-fast-chart-0.3.0.tgz" "$output_dir/asset-charts/"
fi

candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
[[ -z "$(git -C "$candidate_dir" status --porcelain)" ]] || die "Candidate working tree is not clean"
if [[ "$require_audit" == true && -z "$prometheus_url" ]]; then
  die "--prometheus-url is required with --require-audit"
fi
if [[ "$require_audit" == true ]]; then
  cp "$script_dir/../../scripts/collect-audit-report.py" "$output_dir/collect-audit-report.py"
  cp "$script_dir/../../scripts/extract-scheduler-sample.py" "$output_dir/extract-scheduler-sample.py"
  cp "$script_dir/../../scripts/prometheus-time.py" "$output_dir/prometheus-time.py"
fi

run_candidate=(
  "$script_dir/run-candidate.sh"
  --runtime-dir "$runtime_dir"
  --candidate-dir "$candidate_dir"
  --runner-image "$runner_image"
  --state-dir "$state_dir"
  --output-dir "$output_dir"
  --network host
  --
)

inner_script='set -euo pipefail
scenario="$1"
count="$2"
scheduler="$3"
candidate_commit="$4"
use_kwok="$5"
cluster_name="$6"
prometheus_url="$7"
require_audit="$8"
work="$(mktemp -d)"
cp -a /workspace/volcano "$work/volcano"
export USE_EXISTING_CLUSTER=true
export SKIP_KWOK=true
export SKIP_INSTALL_VOLCANO=true
export SKIP_INSTALL_MONITORING=true
export SCHEDULER_NAME="$scheduler"
export DRY_RUN=true
cd "$work/volcano"
mkdir -p /workspace/output
cleanup_benchmark() {
  kubectl delete jobs.batch.volcano.sh -n default -l volcano.sh/benchmark=true \
    --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  kubectl delete pods -n default -l volcano.sh/benchmark=true \
    --ignore-not-found=true --wait=true --timeout=60s >/dev/null 2>&1 || true
}
cleanup_all() {
  cleanup_benchmark
  rm -rf "$work"
}
trap cleanup_all EXIT
cleanup_benchmark
prom_time_query() {
  python3 /workspace/output/prometheus-time.py "$prometheus_url"
}
audit_before=""
if [[ "$require_audit" == "true" ]]; then
  audit_before="$(prom_time_query)" || { echo "Prometheus is not reachable at $prometheus_url" >&2; exit 1; }
fi
if [[ "$use_kwok" == "true" ]]; then
  export SKIP_KWOK=false
  helm upgrade --install kwok-controller \
    /workspace/output/asset-charts/kwok-chart-0.3.0.tgz \
    --namespace kube-system --create-namespace --set hostNetwork=true --wait
  helm upgrade --install kwok-stage-fast \
    /workspace/output/asset-charts/kwok-stage-fast-chart-0.3.0.tgz \
    --namespace kube-system --wait
  KWOK_NODE_COUNT=10 CPU_PER_NODE=4 MEMORY_PER_NODE=16Gi \
    bash benchmark/scripts/create-kwok-nodes.sh
else
  export SKIP_KWOK=true
fi
kubectl get pods -n volcano-system -l app=volcano-scheduler -o json \
  > /workspace/output/scheduler-before.json
if [[ "$scenario" == "pod" ]]; then
  cat > "$work/pod-profile.yaml" <<EOF
pods: $count
podTemplate:
  name: pod-test
  schedulerName: $scheduler
  image: busybox:1.36
  cpu: "1"
  memory: "1Gi"
EOF
  profile="$work/pod-profile.yaml"
else
  cat > "$work/gang-profile.yaml" <<EOF
jobs: $count
jobTemplate:
  name: gang-test
  minAvailable: 1
  queue: default
  tasks:
    - name: worker
      replicas: 1
      cpu: "1"
      memory: "1Gi"
EOF
  profile="$work/gang-profile.yaml"
fi
expected_pods="$count"
set +e
sample_scheduler() {
  while kill -0 "$1" 2>/dev/null; do
    node="$(kubectl get pod -n volcano-system -l app=volcano-scheduler -o jsonpath="{.items[0].spec.nodeName}" 2>/dev/null || true)"
    if [[ -n "$node" ]]; then
      kubectl get --raw "/api/v1/nodes/$node/proxy/stats/summary" 2>/dev/null \
        | python3 /workspace/output/extract-scheduler-sample.py \
        >> /workspace/output/scheduler-samples.jsonl || true
    fi
    sleep 0.2
  done
}
: > /workspace/output/scheduler-samples.jsonl
BENCHMARK_CONFIG="$profile" go test -json -count=1 -timeout 1800s \
  "./benchmark/testcases/$scenario/..." -run TestFromConfig \
  > "/workspace/output/test-$scenario.jsonl" 2>&1 &
test_pid=$!
sample_scheduler "$test_pid" &
sampler_pid=$!
wait "$test_pid"
test_status=$?
wait "$sampler_pid" || true
set -e
kubectl get pods -n default -l volcano.sh/benchmark=true -o json \
  > /workspace/output/benchmark-pods.json
kubectl get pods -n volcano-system -l app=volcano-scheduler -o json \
  > /workspace/output/scheduler-after.json
if [[ "$scenario" == "gang" ]]; then
  kubectl get jobs.batch.volcano.sh -n default -l volcano.sh/benchmark=true -o json \
    > /workspace/output/benchmark-vcjobs.json
fi
if [[ "$require_audit" == "true" ]]; then
  sleep 15
  audit_after="$(prom_time_query)" || { echo "Prometheus stopped responding at $prometheus_url" >&2; exit 1; }
  python3 /workspace/output/collect-audit-report.py --prometheus-url "$prometheus_url" --before "$audit_before" --after "$audit_after" --output /workspace/output/audit-report.json
  [[ -s /workspace/output/audit-report.json ]] || { echo "Audit report was not generated" >&2; exit 1; }
fi
printf "candidateCommit=%s\nclusterName=%s\nscenario=%s\nrequestedCount=%s\nexpectedPods=%s\nscheduler=%s\nkwok=%s\ntestStatus=%s\n" \
  "$candidate_commit" "$cluster_name" "$scenario" "$count" "$expected_pods" "$scheduler" "$use_kwok" "$test_status" \
  > /workspace/output/run-metadata.env
exit "$test_status"'

set +e
"${run_candidate[@]}" bash -c "$inner_script" -- \
  "$scenario" "$count" "$scheduler" "$candidate_commit" "$use_kwok" "$cluster_name" "$prometheus_url" "$require_audit"
test_status=$?
set -e

set +e
metrics_args=(bash "$script_dir/../../scripts/run-performance-tools.sh" "$script_dir/../../scripts/collect-community-benchmark-metrics.py" \
  --metadata "$output_dir/run-metadata.env" \
  --pods "$output_dir/benchmark-pods.json" \
  --events "$output_dir/test-$scenario.jsonl" \
  --scheduler-before "$output_dir/scheduler-before.json" \
  --scheduler-after "$output_dir/scheduler-after.json" \
  --output "$output_dir/result.json" \
  --markdown-output "$output_dir/summary.md" \
  --log-output "$output_dir/test-$scenario.log" \
  --scheduler-samples "$output_dir/scheduler-samples.jsonl")
if [[ "$require_audit" == true ]]; then
  metrics_args+=(--audit-report "$output_dir/audit-report.json")
fi
"${metrics_args[@]}"
metrics_status=$?
set -e

if ((test_status != 0)); then
  die "Community Benchmark test failed; metrics and diagnostics were retained in $output_dir"
fi
if ((metrics_status != 0)); then
  die "Community Benchmark performance checks failed; see $output_dir/result.json"
fi
log_info "Community Benchmark performance detection completed: cluster=$cluster_name commit=$candidate_commit scenario=$scenario count=$count"
