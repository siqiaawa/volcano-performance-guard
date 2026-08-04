#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: prepare-candidate-deps.sh --runtime-dir PATH --candidate-dir PATH
                                  [--expected-commit SHA]
                                  [--asset-dir PATH] [--runner-image NAME]
                                  [--preflight-output PATH]
                                  [--missing-modules-output PATH]
                                  [--output-env PATH] [--allow-network]

Discover missing Go modules with the Runtime Runner, optionally package only
those modules during an explicitly online phase, import the supplement into a
derived candidate Runner, and run the offline preflight again. The Runtime and
candidate checkouts are never modified. Without --allow-network this command
only performs discovery and fails with the missing module list.
EOF
}

runtime_dir=""
candidate_dir=""
expected_commit=""
asset_dir=""
runner_image=""
preflight_output=""
missing_modules_output=""
output_env=""
allow_network=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-dir) runtime_dir="${2:?}"; shift 2 ;;
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --expected-commit) expected_commit="${2:?}"; shift 2 ;;
    --asset-dir) asset_dir="${2:?}"; shift 2 ;;
    --runner-image) runner_image="${2:?}"; shift 2 ;;
    --preflight-output) preflight_output="${2:?}"; shift 2 ;;
    --missing-modules-output) missing_modules_output="${2:?}"; shift 2 ;;
    --output-env) output_env="${2:?}"; shift 2 ;;
    --allow-network) allow_network=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$runtime_dir" ]] || die "--runtime-dir is required"
[[ -n "$candidate_dir" ]] || die "--candidate-dir is required"
require_cmd awk bash docker git mktemp
runtime_dir="$(resolve_directory "$runtime_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
[[ -f "$runtime_dir/runtime.env" ]] || die "Runtime is missing runtime.env"

candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD 2>/dev/null)" || \
  die "Candidate is not a Git working tree: $candidate_dir"
[[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || die "Candidate HEAD is not a full commit SHA"
[[ -z "$expected_commit" || "$candidate_commit" == "$expected_commit" ]] || \
  die "Candidate commit mismatch: expected=$expected_commit actual=$candidate_commit"

base_runner="$(awk -F= '$1 == "RUNNER_IMAGE" {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' \
  "$runtime_dir/runtime.env" | tr -d '\r')" || die "Runtime metadata is missing RUNNER_IMAGE"
[[ "$base_runner" =~ ^[A-Za-z0-9_./:@-]+$ ]] || die "Runtime RUNNER_IMAGE is unsafe"
if [[ -z "$runner_image" ]]; then
  runner_image="volcano-candidate-runner:$candidate_commit"
fi
[[ "$runner_image" =~ ^[A-Za-z0-9_./:@-]+$ ]] || die "Candidate Runner image is unsafe"

if [[ -z "$asset_dir" ]]; then
  asset_dir="$script_dir/../../.work/offline-assets/go-mod/$candidate_commit"
fi
if [[ -z "$preflight_output" ]]; then
  preflight_output="$script_dir/../../.work/candidate-preflight.yaml"
fi
if [[ -z "$missing_modules_output" ]]; then
  missing_modules_output="$script_dir/../../.work/candidate-missing-modules.txt"
fi
mkdir -p -- "$(dirname -- "$preflight_output")" "$(dirname -- "$missing_modules_output")"

write_env() {
  [[ -n "$output_env" ]] || return 0
  local temporary_env quoted_asset
  printf -v quoted_asset '%q' "$asset_dir"
  mkdir -p -- "$(dirname -- "$output_env")"
  temporary_env="${output_env}.tmp.$$"
  printf 'CANDIDATE_COMMIT=%s\nCANDIDATE_RUNNER_IMAGE=%s\nCANDIDATE_DEPS_ASSET_DIR=%s\n' \
    "$candidate_commit" "$1" "$quoted_asset" >"$temporary_env"
  mv -- "$temporary_env" "$output_env"
}

work_dir="$(mktemp -d)"
trap 'rm -rf -- "$work_dir"' EXIT
base_report="$work_dir/base-preflight.yaml"
base_missing="$work_dir/base-missing-modules.txt"

log_info "Discovering missing Go modules with Runtime Runner: $base_runner"
set +e
bash "$script_dir/preflight-candidate.sh" \
  --runtime-dir "$runtime_dir" \
  --candidate-dir "$candidate_dir" \
  --runner-image "$base_runner" \
  --missing-modules-output "$base_missing" \
  --output "$base_report"
base_status=$?
set -e

if ((base_status == 0)); then
  cp -- "$base_report" "$preflight_output"
  printf 'candidateCommit=%s\nbaseRunner=%s\ncandidateRunner=%s\nmissingModules=0\n' \
    "$candidate_commit" "$base_runner" "$base_runner"
  write_env "$base_runner"
  exit 0
fi

if [[ ! -s "$base_missing" ]]; then
  cp -- "$base_report" "$preflight_output"
  die "Candidate preflight failed before it could identify missing Go modules; see $preflight_output"
fi
cp -- "$base_missing" "$missing_modules_output"
missing_count="$(awk 'NF {count++} END {print count+0}' "$base_missing")"
log_warn "Runtime Runner is missing $missing_count candidate Go module(s)"

if [[ "$allow_network" != true ]]; then
  cp -- "$base_report" "$preflight_output"
  die "Missing modules discovered; rerun with --allow-network for explicit online packaging: $missing_modules_output"
fi

log_warn "ONLINE PACKAGING: downloading only the discovered module set"
all_missing="$work_dir/all-missing-modules.txt"
sort -u "$base_missing" >"$all_missing"
max_iterations=5
for ((iteration = 1; iteration <= max_iterations; iteration++)); do
  bash "$script_dir/package-candidate-deps.sh" \
    --runtime-dir "$runtime_dir" \
    --candidate-dir "$candidate_dir" \
    --missing-modules "$all_missing" \
    --output-dir "$asset_dir" \
    --expected-commit "$candidate_commit" \
    --allow-network

  bash "$script_dir/import-candidate-deps.sh" \
    --runtime-dir "$runtime_dir" \
    --asset-dir "$asset_dir" \
    --runner-image "$runner_image" \
    --expected-commit "$candidate_commit"

  iteration_missing="$work_dir/missing-modules-$iteration.txt"
  log_info "Re-running candidate preflight with derived Runner (iteration $iteration/$max_iterations): $runner_image"
  set +e
  bash "$script_dir/preflight-candidate.sh" \
    --runtime-dir "$runtime_dir" \
    --candidate-dir "$candidate_dir" \
    --runner-image "$runner_image" \
    --missing-modules-output "$iteration_missing" \
    --output "$preflight_output"
  iteration_status=$?
  set -e

  if ((iteration_status == 0)); then
    cp -- "$all_missing" "$missing_modules_output"
    missing_count="$(awk 'NF {count++} END {print count+0}' "$all_missing")"
    write_env "$runner_image"
    printf 'candidateCommit=%s\nbaseRunner=%s\ncandidateRunner=%s\nmissingModules=%s\nassetDir=%s\n' \
      "$candidate_commit" "$base_runner" "$runner_image" "$missing_count" "$asset_dir"
    exit 0
  fi

  if [[ ! -s "$iteration_missing" ]]; then
    cp -- "$all_missing" "$missing_modules_output"
    die "Candidate preflight failed after dependency packaging without identifying another module; see $preflight_output"
  fi

  next_missing="$work_dir/next-missing-modules.txt"
  cat -- "$all_missing" "$iteration_missing" | sort -u >"$next_missing"
  if cmp -s "$all_missing" "$next_missing"; then
    cp -- "$next_missing" "$missing_modules_output"
    die "Candidate dependency preflight did not converge; see $preflight_output"
  fi
  mv -- "$next_missing" "$all_missing"
  missing_count="$(awk 'NF {count++} END {print count+0}' "$all_missing")"
  log_warn "Discovered additional missing module(s); expanding supplement to $missing_count entries"
done

cp -- "$all_missing" "$missing_modules_output"
die "Candidate dependency preflight did not converge after $max_iterations iterations; see $preflight_output"
