#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"
usage() {
  cat <<'EOF'
Usage: run-candidate-e2e.sh --runtime-dir PATH --candidate-dir PATH
                            --runner-image NAME --cluster-name NAME
                            --state-dir PATH --output-dir PATH
                            [--suite NAME] [--asset-dir PATH]

Run one upstream E2E target (or ALL) from a writable disposable candidate
copy. KWOK is installed only from the supplied offline charts.
EOF
}
runtime_dir=""; candidate_dir=""; runner_image=""; cluster_name=""; state_dir=""; output_dir=""; asset_dir=""; suite="SCHEDULINGBASE"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --cluster-name) cluster_name="${2:?}"; shift 2 ;;
    --state-dir) state_dir="${2:?}"; shift 2 ;;
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    --asset-dir) asset_dir="${2:?}"; shift 2 ;;
    --suite) suite="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ -n "$runtime_dir" && -n "$candidate_dir" && -n "$runner_image" && -n "$cluster_name" && -n "$state_dir" && -n "$output_dir" ]] || die "All arguments are required"
[[ "$suite" =~ ^(ALL|JOBP|JOBSEQ|SCHEDULINGBASE|SCHEDULINGACTION|VCCTL|CRONJOB|DRA|ADMISSION_POLICY|ADMISSION_WEBHOOK|HYPERNODE)$ ]] || die "Unsupported E2E suite: $suite"
require_cmd git bash
runtime_dir="$(resolve_directory "$runtime_dir")"; candidate_dir="$(resolve_directory "$candidate_dir")"; state_dir="$(resolve_directory "$state_dir")"
mkdir -p -- "$output_dir"; output_dir="$(resolve_directory "$output_dir")"
candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
grep -Fx "CLUSTER_NAME=$cluster_name" "$state_dir/cluster.marker" >/dev/null || die "Cluster marker mismatch"
grep -Fx "CANDIDATE_COMMIT=$candidate_commit" "$state_dir/cluster.marker" >/dev/null || die "Candidate marker mismatch"
[[ -n "$asset_dir" ]] || die "--asset-dir is required for offline KWOK setup"
asset_dir="$(resolve_directory "$asset_dir")"
[[ -f "$asset_dir/charts/kwok-chart-0.3.0.tgz" && -f "$asset_dir/charts/kwok-stage-fast-chart-0.3.0.tgz" ]] || die "KWOK charts are missing"
cp "$asset_dir/charts/kwok-chart-0.3.0.tgz" "$output_dir/"
cp "$asset_dir/charts/kwok-stage-fast-chart-0.3.0.tgz" "$output_dir/"
run_candidate=("$script_dir/run-candidate.sh" --runtime-dir "$runtime_dir" --candidate-dir "$candidate_dir" --runner-image "$runner_image" --state-dir "$state_dir" --output-dir "$output_dir" --network host --with-docker-socket --)
inner_script='set -euo pipefail
work="$(mktemp -d)"
cp -a /workspace/volcano "$work/volcano"
cd "$work/volcano"
export FORCE_REBUILD=true GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOFLAGS=-mod=readonly
helm upgrade --install kwok-controller /workspace/output/kwok-chart-0.3.0.tgz --namespace kube-system --create-namespace --set hostNetwork=true --wait
helm upgrade --install kwok-stage-fast /workspace/output/kwok-stage-fast-chart-0.3.0.tgz --namespace kube-system --wait
kubectl delete stage pod-complete --ignore-not-found=true >/dev/null 2>&1 || true
KWOK_NODE_COUNT=4 CPU_PER_NODE=8 MEMORY_PER_NODE=8Gi bash benchmark/scripts/create-kwok-nodes.sh
suite="$1"
case "$suite" in
  ALL)
    ginkgo -r --nodes=4 --compilers=4 --randomize-all --randomize-suites --fail-on-pending --cover --trace --race --slow-spec-threshold=30s --progress ./test/e2e/jobp/
    ginkgo -r --slow-spec-threshold=30s --progress ./test/e2e/jobseq/
    ginkgo -r --slow-spec-threshold=30s --progress ./test/e2e/schedulingbase/
    ginkgo -r --skip="\\[sig-.*\\]" --slow-spec-threshold=30s --progress ./test/e2e/schedulingaction/
    ginkgo -r --slow-spec-threshold=30s --progress ./test/e2e/vcctl/
    ginkgo -r --slow-spec-threshold=30s --progress ./test/e2e/cronjob/
    ginkgo -r --slow-spec-threshold=30s --progress --focus="DRA (Quota )?E2E Test" ./test/e2e/dra/
    ginkgo -r --slow-spec-threshold=30s --progress ./test/e2e/admission/
    ginkgo -r --slow-spec-threshold=30s --progress ./test/e2e/hypernode/
    ;;
  JOBP) ginkgo -v -r --nodes=4 --compilers=4 --randomize-all --randomize-suites --fail-on-pending --cover --trace --race --slow-spec-threshold=30s --progress ./test/e2e/jobp/ ;;
  JOBSEQ) ginkgo -v -r --slow-spec-threshold=30s --progress ./test/e2e/jobseq/ ;;
  SCHEDULINGBASE) ginkgo -v -r --skip="\[sig-.*\]" --slow-spec-threshold=30s --progress ./test/e2e/schedulingbase/ ;;
  SCHEDULINGACTION) ginkgo -v -r --slow-spec-threshold=30s --progress ./test/e2e/schedulingaction/ ;;
  VCCTL) ginkgo -v -r --slow-spec-threshold=30s --progress ./test/e2e/vcctl/ ;;
  CRONJOB) ginkgo -v -r --slow-spec-threshold=30s --progress ./test/e2e/cronjob/ ;;
  DRA) ginkgo -v -r --slow-spec-threshold=30s --progress --focus="DRA (Quota )?E2E Test" ./test/e2e/dra/ ;;
  ADMISSION_POLICY|ADMISSION_WEBHOOK) ginkgo -v -r --slow-spec-threshold=30s --progress ./test/e2e/admission/ ;;
  HYPERNODE) ginkgo -r --slow-spec-threshold=30s --progress ./test/e2e/hypernode/ ;;
esac
rm -rf "$work"'
printf '%s\n' "$inner_script" >"$output_dir/inner-script.sh"
set +e
"${run_candidate[@]}" bash -c "$inner_script" -- "$suite" >"$output_dir/$suite.log" 2>&1
status=$?
set -e
"${run_candidate[@]}" kind export logs /workspace/output/kind-logs --name "$cluster_name" >/dev/null 2>&1 || true
printf 'candidateCommit=%s\nclusterName=%s\nsuite=%s\nstatus=%s\n' "$candidate_commit" "$cluster_name" "$suite" "$status" >"$output_dir/e2e-metadata.env"
((status == 0)) || die "Candidate E2E suite failed; diagnostics retained in $output_dir"
log_info "Candidate E2E suite passed: $suite"
