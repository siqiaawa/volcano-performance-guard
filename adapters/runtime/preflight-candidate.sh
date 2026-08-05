#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: preflight-candidate.sh --runtime-dir PATH --candidate-dir PATH
                              [--expected-commit SHA] [--runner-image NAME]
                              [--missing-modules-output PATH] [--output PATH]
                              [--embedded-go-mod]

Validate candidate identity, Go dependency availability with network disabled,
and local availability of every Runtime image used to rebase the built
components. The candidate Dockerfiles are not built by the performance guard.
No image is built and no cluster is created.
EOF
}

runtime_dir=""
candidate_dir=""
expected_commit=""
output=""
runner_image=""
missing_modules_output=""
embedded_go_mod=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir)
      [[ $# -ge 2 ]] || die "--runtime-dir requires a value"
      runtime_dir="$2"
      shift 2
      ;;
    --candidate-dir)
      [[ $# -ge 2 ]] || die "--candidate-dir requires a value"
      candidate_dir="$2"
      shift 2
      ;;
    --expected-commit)
      [[ $# -ge 2 ]] || die "--expected-commit requires a value"
      expected_commit="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value"
      output="$2"
      shift 2
      ;;
    --runner-image)
      [[ $# -ge 2 ]] || die "--runner-image requires a value"
      runner_image="$2"
      shift 2
      ;;
    --missing-modules-output)
      [[ $# -ge 2 ]] || die "--missing-modules-output requires a value"
      missing_modules_output="$2"
      shift 2
      ;;
    --embedded-go-mod)
      embedded_go_mod=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$runtime_dir" ]] || die "--runtime-dir is required"
[[ -n "$candidate_dir" ]] || die "--candidate-dir is required"
require_cmd awk docker find git sort
runtime_dir="$(resolve_directory "$runtime_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"

candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD 2>/dev/null)" || \
  die "Candidate is not a Git working tree: $candidate_dir"
candidate_tree="$(git -C "$candidate_dir" rev-parse 'HEAD^{tree}')"
candidate_branch="$(git -C "$candidate_dir" symbolic-ref --quiet --short HEAD || printf 'DETACHED')"
candidate_origin="$(git -C "$candidate_dir" config --get remote.origin.url || true)"
[[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || die "Candidate HEAD is not a full commit SHA"
[[ -z "$expected_commit" || "$candidate_commit" == "$expected_commit" ]] || \
  die "Candidate commit mismatch: expected=$expected_commit actual=$candidate_commit"

candidate_clean=true
if [[ -n "$(git -C "$candidate_dir" status --porcelain)" ]]; then
  candidate_clean=false
fi

reference_commit="$(awk -F= '$1 == "RUNTIME_BASE_COMMIT" {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' \
  "$runtime_dir/runtime.env" | tr -d '\r')" || die "Runtime metadata is missing RUNTIME_BASE_COMMIT"
[[ "$reference_commit" =~ ^[0-9a-f]{40}$ ]] || die "Runtime base commit is not a full commit SHA"
components=(scheduler controller-manager webhook-manager agent-scheduler agent)
base_images=()
for component in "${components[@]}"; do
  base_images+=("volcanosh/vc-$component:$reference_commit")
done

missing_images=()
for image in "${base_images[@]}"; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    log_info "Base image available: $image"
  else
    log_warn "Base image missing: $image"
    missing_images+=("$image")
  fi
done

go_log="$(mktemp)"
go_stderr="$(mktemp)"
trap 'rm -f -- "$go_log" "$go_stderr"' EXIT
runner_args=()
if [[ -n "$runner_image" ]]; then
  runner_args+=(--runner-image "$runner_image")
fi
go_mod_env=()
if [[ "$embedded_go_mod" == true ]]; then
  go_mod_env+=(PERFORMANCE_GUARD_USE_EMBEDDED_GO_MOD=1)
fi
set +e
env "${go_mod_env[@]}" "$script_dir/run-candidate.sh" \
  --runtime-dir "$runtime_dir" \
  --candidate-dir "$candidate_dir" \
  --network none \
  "${runner_args[@]}" \
  -- bash -c \
    'set -euo pipefail; temp_dir=$(mktemp -d); trap '\''rm -rf "$temp_dir"'\'' EXIT; cp go.mod go.sum "$temp_dir/"; cp -a staging "$temp_dir/"; cd "$temp_dir"; go mod download -json all' \
  >"$go_log" 2>"$go_stderr"
download_status=$?
set -e

mapfile -t missing_modules < <(bash "$script_dir/../../scripts/run-performance-tools.sh" "$script_dir/../../scripts/list_missing_go_modules.py" "$go_log")
if [[ -n "$missing_modules_output" ]]; then
  mkdir -p -- "$(dirname -- "$missing_modules_output")"
  printf '%s\n' "${missing_modules[@]}" >"$missing_modules_output"
fi

go_status=$download_status
if ((download_status == 0)); then
  set +e
  env "${go_mod_env[@]}" "$script_dir/run-candidate.sh" \
    --runtime-dir "$runtime_dir" \
    --candidate-dir "$candidate_dir" \
    --network none \
    "${runner_args[@]}" \
    -- go list -mod=readonly -deps ./... >/dev/null 2>"$go_stderr"
  go_status=$?
  set -e
fi

if ((go_status == 0)); then
  go_offline=true
  log_info "Candidate Go dependencies are complete with container network disabled"
else
  go_offline=false
  log_warn "Candidate Go dependency preflight failed with container network disabled"
  for module in "${missing_modules[@]}"; do
    printf '[GO] missing module: %s\n' "$module" >&2
  done
  sed 's/^/[GO] /' "$go_stderr" >&2
fi

base_images_available=true
if ((${#missing_images[@]} > 0)); then
  base_images_available=false
fi

render() {
  cat <<EOF
schemaVersion: v1
candidate:
  commit: $candidate_commit
  tree: $candidate_tree
  branch: $candidate_branch
  origin: ${candidate_origin:-null}
  trackedSourceClean: $candidate_clean
executionBoundary:
  runnerImage: ${runner_image:-runtime-default}
  runnerNetwork: none
  goProxy: "off"
  goSumDb: "off"
  sourceMount: read-only
checks:
  offlineGoDependencies: $go_offline
  componentBaseImagesAvailable: $base_images_available
baseImages:
EOF
  for image in "${base_images[@]}"; do
    if docker image inspect "$image" >/dev/null 2>&1; then
      printf '  - image: "%s"\n    available: true\n' "$image"
    else
      printf '  - image: "%s"\n    available: false\n' "$image"
    fi
  done
}

if [[ -n "$output" ]]; then
  mkdir -p -- "$(dirname -- "$output")"
  temporary_output="${output}.tmp.$$"
  render >"$temporary_output"
  mv -- "$temporary_output" "$output"
  log_info "Candidate preflight report written to $output"
else
  render
fi

[[ "$candidate_clean" == true ]] || die "Candidate working tree is not clean"
[[ "$go_offline" == true ]] || die "Candidate Go dependencies are incomplete offline"
[[ "$base_images_available" == true ]] || die "Candidate component base images are incomplete offline"
