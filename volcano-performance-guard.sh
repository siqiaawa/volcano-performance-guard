#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$ROOT_DIR/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage:
  volcano-performance-guard.sh fixed-compare [OPTIONS]
  volcano-performance-guard.sh version-compare [OPTIONS]

fixed-compare compares a candidate with the fixed Volcano version. It supports
either an existing stable metrics file or a fresh stable run:

  --candidate-path PATH       Run the candidate from this local Git checkout
  --candidate-metrics PATH    Use an already aggregated candidate metrics file
  --baseline-metrics PATH     Use an already aggregated fixed-version metrics file
  --fixed-path PATH           Override the built-in stable checkout

version-compare always runs both local checkouts:

  --stable-path PATH          Local Git checkout used as the baseline
  --candidate-path PATH       Local Git checkout used as the candidate

Common options:
  --runtime-dir PATH          Runtime override (default: <project>/runtime)
  --stable-deps-dir PATH      Stable offline Go supplement directory
  --stable-runner-image NAME  Derived Runner image for stable offline builds
  --output-dir PATH           Report directory (default: .work/comparisons/<run-id>)
  --profile PATH              Timestamp profile (default: profiles/performance-compare.yaml)
  --thresholds PATH           Relative regression thresholds
  --goproxy URL               Go proxy for online module downloads
  --run-id ID                 1-15 lowercase letters, digits, or hyphens
  --keep-clusters              Do not delete clusters after a completed run
  -h, --help                  Show this help

The project owns its Runner, Kind, registry, stable checkout, and Release asset
contract. Stable builds require a version-bound offline Go supplement; only
candidate Go modules may be downloaded online. Run ./setup.sh once to prepare
a fresh clone; fixed-compare uses stable/volcano by default.
EOF
}

command_name="${1:-}"
if [[ "$command_name" == "-h" || "$command_name" == "--help" || -z "$command_name" ]]; then
  usage
  exit 0
fi
shift

case "$command_name" in
  fixed-compare|version-compare) ;;
  *) die "Unknown command: $command_name" ;;
esac

runtime_dir="${RUNTIME_DIR:-$ROOT_DIR/runtime}"
stable_path=""
stable_deps_dir="${STABLE_DEPS_ASSET_DIR:-}"
stable_runner_image="${STABLE_RUNNER_IMAGE:-}"
fixed_path=""
candidate_path=""
baseline_metrics=""
candidate_metrics=""
output_dir=""
profile="$ROOT_DIR/profiles/performance-compare.yaml"
thresholds="$ROOT_DIR/configs/timestamp-thresholds.example.yaml"
goproxy="${PERFORMANCE_GUARD_GO_PROXY:-https://goproxy.cn,direct}"
run_id="$(date -u +%Y%m%d%H%M%S)"
keep_clusters=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --stable-deps-dir) stable_deps_dir="${2:?}"; shift 2 ;;
    --stable-runner-image) stable_runner_image="${2:?}"; shift 2 ;;
    --stable-path) stable_path="${2:?}"; shift 2 ;;
    --fixed-path) fixed_path="${2:?}"; shift 2 ;;
    --candidate-path) candidate_path="${2:?}"; shift 2 ;;
    --baseline-metrics) baseline_metrics="${2:?}"; shift 2 ;;
    --candidate-metrics) candidate_metrics="${2:?}"; shift 2 ;;
    --output-dir) output_dir="${2:?}"; shift 2 ;;
    --profile) profile="${2:?}"; shift 2 ;;
    --thresholds) thresholds="${2:?}"; shift 2 ;;
    --goproxy) goproxy="${2:?}"; shift 2 ;;
    --run-id) run_id="${2:?}"; shift 2 ;;
    --keep-clusters) keep_clusters=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

metrics_only=false
if [[ "$command_name" == "fixed-compare" && -n "$candidate_metrics" ]]; then
  metrics_only=true
fi

if [[ "$metrics_only" == true ]]; then
  require_cmd bash date make
else
  require_cmd bash curl date docker git make
  runtime_dir="$(resolve_directory "$runtime_dir")"
fi
profile="$(realpath -m -- "$profile")"
thresholds="$(realpath -m -- "$thresholds")"
if [[ -n "$baseline_metrics" ]]; then
  baseline_metrics="$(realpath -m -- "$baseline_metrics")"
fi
if [[ -n "$candidate_metrics" ]]; then
  candidate_metrics="$(realpath -m -- "$candidate_metrics")"
fi
if [[ "$metrics_only" != true ]]; then
  [[ -f "$profile" ]] || die "Profile not found: $profile"
fi
[[ -f "$thresholds" ]] || die "Thresholds not found: $thresholds"
[[ "$run_id" =~ ^[a-z0-9][a-z0-9-]{0,14}$ ]] || \
  die "Run id must use 1-15 lowercase letters, digits, or hyphens: $run_id"

if [[ -z "$output_dir" ]]; then
  output_dir="$ROOT_DIR/.work/comparisons/$run_id"
fi
mkdir -p -- "$output_dir"
output_dir="$(resolve_directory "$output_dir")"

run_make() {
  make -C "$ROOT_DIR" "$@"
}

runtime_value() {
  local key="$1"
  awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' \
    "$runtime_dir/runtime.env" | tr -d '\r'
}

runner_image=""
reference_commit=""
if [[ "$metrics_only" != true ]]; then
  [[ -f "$runtime_dir/runtime.env" ]] || die "Runtime metadata is missing: $runtime_dir/runtime.env"
  runner_image="$(runtime_value RUNNER_IMAGE)"
  reference_commit="$(runtime_value RUNTIME_BASE_COMMIT)"
  kind_node_image="$(runtime_value KIND_NODE_IMAGE)"
  registry_name="$(runtime_value REGISTRY_NAME)"
  tools_image="$(runtime_value PERFORMANCE_TOOLS_IMAGE)"
  registry_port="$(runtime_value REGISTRY_HOST_PORT)"
  if ! docker image inspect "$runner_image" >/dev/null 2>&1 \
      || ! docker image inspect "$kind_node_image" >/dev/null 2>&1 \
      || ! docker image inspect "volcanosh/vc-scheduler:$reference_commit" >/dev/null 2>&1 \
      || ! docker image inspect "$tools_image" >/dev/null 2>&1 \
      || ! docker container inspect "$registry_name" >/dev/null 2>&1 \
      || ! curl -fsS --connect-timeout 5 "http://localhost:${registry_port}/v2/" >/dev/null 2>&1; then
    log_info "Project runtime is not ready; installing Release assets"
    bash "$ROOT_DIR/setup.sh"
  fi
  docker image inspect "$runner_image" >/dev/null 2>&1 || die "Runner image is unavailable: $runner_image"
  curl -fsS --connect-timeout 5 "http://localhost:${registry_port}/v2/" >/dev/null || \
    die "Local registry is unavailable at localhost:${registry_port}"
fi

prepare_stable_runner() {
  local version_dir="$1" commit
  validate_checkout "$version_dir"
  commit="$(git_commit "$version_dir")"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "Stable HEAD is not a full commit: $version_dir"
  if [[ "$commit" == "$reference_commit" ]]; then
    stable_runner_image="$runner_image"
    return 0
  fi
  stable_deps_dir="${stable_deps_dir:-$ROOT_DIR/.work/offline-assets/go-mod/$commit}"
  stable_runner_image="${stable_runner_image:-volcano-stable-runner:$commit}"
  [[ -d "$stable_deps_dir" ]] || die "Stable offline Go dependency asset is missing: $stable_deps_dir"
  log_info "Importing stable offline Go dependency asset: $stable_deps_dir"
  bash "$ROOT_DIR/adapters/runtime/import-version-deps.sh" \
    --runtime-dir "$runtime_dir" \
    --asset-dir "$stable_deps_dir" \
    --runner-image "$stable_runner_image" \
    --expected-commit "$commit"
}

PERFORMANCE_GUARD_TOOLS_IMAGE="${PERFORMANCE_GUARD_TOOLS_IMAGE:-${tools_image:-}}"
if [[ -z "$PERFORMANCE_GUARD_TOOLS_IMAGE" ]] && command -v docker >/dev/null 2>&1; then
  PERFORMANCE_GUARD_TOOLS_IMAGE="$(docker image ls --format '{{.Repository}}:{{.Tag}}' | awk '/performance-guard-tools/ {print; exit}')"
fi
export PERFORMANCE_GUARD_TOOLS_IMAGE
if [[ -z "$PERFORMANCE_GUARD_TOOLS_IMAGE" ]]; then
  log_warn "No performance tools image was found; Python must be available on the host for report generation"
else
  log_info "Performance tools image: $PERFORMANCE_GUARD_TOOLS_IMAGE"
fi

git_commit() {
  local directory="$1"
  git -C "$directory" rev-parse HEAD 2>/dev/null
}

validate_checkout() {
  local directory="$1"
  [[ -d "$directory" ]] || die "Version checkout not found: $directory"
  git -C "$directory" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
    die "Version path is not a Git checkout: $directory"
  [[ -z "$(git -C "$directory" status --porcelain)" ]] || \
    die "Version checkout has uncommitted changes: $directory"
}

cleanup_cluster() {
  local version_dir="$1" cluster_name="$2" state_dir="$3" version_runner="$4"
  if [[ "$keep_clusters" == true ]]; then
    log_info "Keeping cluster $cluster_name (--keep-clusters)"
    return 0
  fi
  if [[ -f "$state_dir/cluster.marker" ]]; then
    run_make candidate-cleanup \
      RUNTIME_DIR="$runtime_dir" CANDIDATE_DIR="$version_dir" \
      CANDIDATE_RUNNER_IMAGE="$version_runner" \
      CANDIDATE_CLUSTER_NAME="$cluster_name" \
      CANDIDATE_CLUSTER_STATE="$state_dir"
  else
    "$ROOT_DIR/adapters/runtime/run-candidate.sh" \
      --runtime-dir "$runtime_dir" --candidate-dir "$version_dir" \
      --runner-image "$version_runner" --network host --with-docker-socket -- \
      kind delete cluster --name "$cluster_name" >/dev/null 2>&1 || true
  fi
}

active_version_dir=""
active_cluster_name=""
active_state_dir=""
active_runner_image=""
cleanup_active() {
  if [[ -n "$active_version_dir" && -n "$active_cluster_name" ]]; then
    cleanup_cluster "$active_version_dir" "$active_cluster_name" "$active_state_dir" "$active_runner_image" || true
    active_version_dir=""
    active_cluster_name=""
  fi
}
trap cleanup_active EXIT
trap 'cleanup_active; exit 130' INT TERM

run_version() {
  local label="$1" version_dir="$2" subject_type="$3"
  validate_checkout "$version_dir"
  local commit
  commit="$(git_commit "$version_dir")"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "Version HEAD is not a full commit: $version_dir"

  local version_root="$output_dir/$label"
  local build_dir="$version_root/build"
  local state_dir="$version_root/cluster-state"
  local report_dir="$version_root/report"
  local cluster_name="volcano-candidate-guard-${run_id}-${label}"
  local version_runner="$runner_image"
  local go_mode="online"
  local network_mode="host"
  local embedded_go_mod=0
  mkdir -p -- "$version_root"
  log_info "Preparing $label: commit=$commit"

  if [[ "$commit" != "$reference_commit" ]]; then
    if [[ "$label" == "stable" ]]; then
      version_runner="$stable_runner_image"
      go_mode="offline"
      network_mode="none"
      embedded_go_mod=1
      log_info "Building stable with offline Go dependency mode and Docker network disabled"
    else
      log_info "Building candidate with online Go dependency mode through $goproxy"
    fi
    (
      export PERFORMANCE_GUARD_GO_MODE="$go_mode"
      export PERFORMANCE_GUARD_NETWORK_MODE="$network_mode"
      export PERFORMANCE_GUARD_GO_PROXY="$goproxy"
      export PERFORMANCE_GUARD_USE_EMBEDDED_GO_MOD="$embedded_go_mod"
      run_make candidate-build-binaries \
        RUNTIME_DIR="$runtime_dir" CANDIDATE_DIR="$version_dir" \
        CANDIDATE_EXPECTED_COMMIT="$commit" CANDIDATE_RUNNER_IMAGE="$version_runner" \
        CANDIDATE_BUILD_DIR="$build_dir"
    )
    run_make candidate-build-images \
      RUNTIME_DIR="$runtime_dir" CANDIDATE_DIR="$version_dir" \
      CANDIDATE_BUILD_DIR="$build_dir"
    run_make candidate-publish-images \
      CANDIDATE_DIR="$version_dir" CANDIDATE_BUILD_DIR="$build_dir"
  else
    log_info "$label uses preloaded reference images for $reference_commit"
  fi

  active_version_dir="$version_dir"
  active_cluster_name="$cluster_name"
  active_state_dir="$state_dir"
  active_runner_image="$version_runner"
  local status=0
  set +e
  run_make candidate-create-cluster \
    RUNTIME_DIR="$runtime_dir" CANDIDATE_DIR="$version_dir" \
    CANDIDATE_RUNNER_IMAGE="$version_runner" CANDIDATE_CLUSTER_NAME="$cluster_name" \
    CANDIDATE_CLUSTER_STATE="$state_dir"
  status=$?
  if ((status == 0)); then
    run_make candidate-deploy \
      RUNTIME_DIR="$runtime_dir" CANDIDATE_DIR="$version_dir" \
      CANDIDATE_RUNNER_IMAGE="$version_runner" CANDIDATE_CLUSTER_NAME="$cluster_name" \
      CANDIDATE_CLUSTER_STATE="$state_dir" CANDIDATE_REPORT_DIR="$report_dir"
    status=$?
  fi
  if ((status == 0)); then
    run_make candidate-timestamp-profile \
      RUNTIME_DIR="$runtime_dir" CANDIDATE_DIR="$version_dir" \
      CANDIDATE_RUNNER_IMAGE="$version_runner" CANDIDATE_CLUSTER_NAME="$cluster_name" \
      CANDIDATE_CLUSTER_STATE="$state_dir" CANDIDATE_REPORT_DIR="$report_dir" \
      TIMESTAMP_REPORT_DIR="$report_dir/timestamp-profile" \
      TIMESTAMP_RUN_ID="${run_id}-${label}" \
      TIMESTAMP_PROFILE="$profile" \
      TIMESTAMP_SUBJECT_TYPE="$subject_type" TIMESTAMP_SUBJECT_VERSION="$commit"
    status=$?
  fi
  set -e
  cleanup_cluster "$version_dir" "$cluster_name" "$state_dir" "$version_runner"
  active_version_dir=""
  active_cluster_name=""
  if ((status != 0)); then
    die "$label performance run failed; inspect $version_root"
  fi
  LAST_METRICS="$report_dir/timestamp-profile/metrics.json"
}

LAST_METRICS=""

compare_metrics() {
  local candidate_file="$1" baseline_file="$2" comparison_dir="$3"
  [[ -f "$candidate_file" ]] || die "Candidate metrics not found: $candidate_file"
  [[ -f "$baseline_file" ]] || die "Baseline metrics not found: $baseline_file"
  mkdir -p -- "$comparison_dir"
  bash "$ROOT_DIR/scripts/run-performance-tools.sh" scripts/compare-baseline.py \
    --candidate "$candidate_file" \
    --baseline "$baseline_file" \
    --thresholds "$thresholds" \
    --output "$comparison_dir/comparison.json" \
    --markdown-output "$comparison_dir/comparison.md" \
    --junit-output "$comparison_dir/comparison.junit.xml" \
    --html-output "$comparison_dir/comparison.html"
}

if [[ "$command_name" == "fixed-compare" ]]; then
  [[ -z "$stable_path" || -z "$fixed_path" ]] || die "Use only one of --stable-path and --fixed-path"
  stable_path="${stable_path:-$fixed_path}"
  if [[ -n "$candidate_metrics" ]]; then
    [[ -z "$candidate_path" ]] || die "--candidate-metrics cannot be combined with --candidate-path"
  else
    [[ -n "$candidate_path" ]] || die "fixed-compare requires --candidate-path or --candidate-metrics"
  fi
  if [[ -z "$candidate_metrics" && -z "$baseline_metrics" && -z "$stable_path" ]]; then
    stable_path="$ROOT_DIR/stable/volcano"
    if [[ ! -d "$stable_path/.git" ]]; then
      bash "$ROOT_DIR/stable/prepare-stable.sh"
    fi
  fi
  [[ -n "$baseline_metrics" || -n "$stable_path" ]] || \
    die "fixed-compare with --candidate-metrics requires --baseline-metrics"
  if [[ -n "$baseline_metrics" && -n "$stable_path" ]]; then
    die "Use only one of --baseline-metrics and --fixed-path"
  fi
  if [[ -n "$candidate_metrics" && -n "$stable_path" ]]; then
    die "--candidate-metrics cannot be combined with a fresh fixed-version run"
  fi
  if [[ -n "$candidate_metrics" ]]; then
    compare_metrics "$candidate_metrics" "$baseline_metrics" "$output_dir/comparison"
  elif [[ -n "$stable_path" ]]; then
    stable_path="$(resolve_directory "$stable_path")"
    candidate_path="$(resolve_directory "$candidate_path")"
    prepare_stable_runner "$stable_path"
    run_version stable "$stable_path" stable
    stable_metrics="$LAST_METRICS"
    run_version candidate "$candidate_path" candidate
    candidate_metrics="$LAST_METRICS"
    compare_metrics "$candidate_metrics" "$stable_metrics" "$output_dir/comparison"
  else
    candidate_path="$(resolve_directory "$candidate_path")"
    run_version candidate "$candidate_path" candidate
    candidate_metrics="$LAST_METRICS"
    compare_metrics "$candidate_metrics" "$baseline_metrics" "$output_dir/comparison"
  fi
else
  [[ -n "$stable_path" && -n "$candidate_path" ]] || \
    die "version-compare requires --stable-path and --candidate-path"
  stable_path="$(resolve_directory "$stable_path")"
  candidate_path="$(resolve_directory "$candidate_path")"
  prepare_stable_runner "$stable_path"
  run_version stable "$stable_path" stable
  stable_metrics="$LAST_METRICS"
  run_version candidate "$candidate_path" candidate
  candidate_metrics="$LAST_METRICS"
  compare_metrics "$candidate_metrics" "$stable_metrics" "$output_dir/comparison"
fi

log_info "Comparison completed: $output_dir/comparison"
