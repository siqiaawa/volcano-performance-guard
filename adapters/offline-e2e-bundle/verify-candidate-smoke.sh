#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: verify-candidate-smoke.sh --bundle-dir PATH --candidate-dir PATH
                                 --runner-image NAME --cluster-name NAME
                                 --state-dir PATH --report-dir PATH

Verify candidate image tags/imageIDs, run a Volcano-scheduled BusyBox Job,
and record Docker pull events since deployment began.
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
[[ -n "$bundle_dir" && -n "$candidate_dir" && -n "$runner_image" && -n "$cluster_name" && -n "$state_dir" && -n "$report_dir" ]] || die "All arguments are required"
require_cmd docker git grep
bundle_dir="$(resolve_directory "$bundle_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
state_dir="$(resolve_directory "$state_dir")"
report_dir="$(resolve_directory "$report_dir")"
candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
grep -Fx "CLUSTER_NAME=$cluster_name" "$state_dir/cluster.marker" >/dev/null || die "Cluster marker mismatch"

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

"${run_candidate[@]}" kubectl get pods -n volcano-system \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\t"}{end}{range .status.containerStatuses[*]}{.imageID}{"\t"}{end}{"\n"}{end}' \
  >"$report_dir/pod-images.tsv"
grep -F ":$candidate_commit" "$report_dir/pod-images.tsv" >/dev/null || die "No running pod reports the candidate image tag"
if grep -E 'volcanosh/vc-[^[:space:]]+:(latest|1cb0a6359032ad5214143e0c22672f15ac7965c2)' "$report_dir/pod-images.tsv" >/dev/null; then
  die "Volcano pods contain a mutable or reference component image"
fi

"${run_candidate[@]}" kubectl delete job candidate-volcano-smoke --ignore-not-found >/dev/null
"${run_candidate[@]}" kubectl create -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: candidate-volcano-smoke
spec:
  backoffLimit: 0
  template:
    spec:
      schedulerName: volcano
      restartPolicy: Never
      containers:
      - name: smoke
        image: busybox:latest
        imagePullPolicy: Always
        command: ["sh", "-c", "echo candidate-volcano-smoke-ok"]
EOF
"${run_candidate[@]}" kubectl wait --for=condition=complete job/candidate-volcano-smoke --timeout=120s
"${run_candidate[@]}" kubectl get job candidate-volcano-smoke -o yaml >"$report_dir/smoke-job.yaml"
"${run_candidate[@]}" kubectl get pods -l job-name=candidate-volcano-smoke -o wide >"$report_dir/smoke-pod.txt"
"${run_candidate[@]}" kubectl logs job/candidate-volcano-smoke >"$report_dir/smoke.log"
grep -Fx 'candidate-volcano-smoke-ok' "$report_dir/smoke.log" >/dev/null || die "Smoke Job output mismatch"

deploy_start="$(cat "$report_dir/deploy-start.epoch")"
docker events --since "$deploy_start" --until "$(date +%s)" --filter type=image --filter event=pull \
  --format '{{json .}}' >"$report_dir/docker-pull-events.jsonl"
pull_count="$(awk 'END {print NR+0}' "$report_dir/docker-pull-events.jsonl")"
printf 'DOCKER_PULL_EVENTS=%s\n' "$pull_count" >"$report_dir/network-audit.env"
[[ "$pull_count" == 0 ]] || die "Docker daemon recorded pull events during candidate deployment: $pull_count"
log_info "Candidate scheduler smoke passed with zero Docker pull events"
