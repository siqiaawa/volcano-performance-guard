#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: run-candidate.sh --runtime-dir PATH --candidate-dir PATH
                        [--state-dir PATH] [--network MODE]
                        [--runner-image NAME]
                        [--output-dir PATH]
                        [--with-docker-socket] -- COMMAND [ARG...]

Run a command in the project Runtime Runner with the external candidate
checkout mounted read-only at /workspace/volcano. Network mode defaults to
none. The Docker socket is absent unless --with-docker-socket is explicit.
Set PERFORMANCE_GUARD_GO_MODE=online and PERFORMANCE_GUARD_NETWORK_MODE=host
for the controlled server workflow that downloads Go modules from GOPROXY.
EOF
}

runtime_dir=""
candidate_dir=""
state_dir=""
network_mode="none"
with_docker_socket=false
runner_image_override=""
output_dir=""

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
    --state-dir)
      [[ $# -ge 2 ]] || die "--state-dir requires a value"
      state_dir="$2"
      shift 2
      ;;
    --network)
      [[ $# -ge 2 ]] || die "--network requires a value"
      network_mode="$2"
      shift 2
      ;;
    --runner-image)
      [[ $# -ge 2 ]] || die "--runner-image requires a value"
      runner_image_override="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    --with-docker-socket)
      with_docker_socket=true
      shift
      ;;
    --)
      shift
      break
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
[[ $# -gt 0 ]] || die "A command is required after --"
if [[ -n "${PERFORMANCE_GUARD_NETWORK_MODE:-}" ]]; then
  network_mode="$PERFORMANCE_GUARD_NETWORK_MODE"
fi
[[ "$network_mode" == "none" || "$network_mode" == "host" ]] || \
  die "--network must be none or host"

# The historical adapters are intentionally offline by default. The unified
# online workflow can opt into dependency downloads without changing the
# network policy of any existing command.
go_mode="${PERFORMANCE_GUARD_GO_MODE:-offline}"
if [[ "$go_mode" != "offline" && "$go_mode" != "online" ]]; then
  die "PERFORMANCE_GUARD_GO_MODE must be offline or online"
fi
if [[ "$go_mode" == "online" ]]; then
  [[ "$network_mode" == "host" ]] || die "Online Go mode requires --network host"
  go_proxy="${PERFORMANCE_GUARD_GO_PROXY:-https://goproxy.cn,direct}"
  go_sumdb="${PERFORMANCE_GUARD_GO_SUMDB:-off}"
  go_flags="${PERFORMANCE_GUARD_GOFLAGS:--mod=mod}"
  go_toolchain="${PERFORMANCE_GUARD_GOTOOLCHAIN:-auto}"
else
  go_proxy=off
  go_sumdb=off
  go_flags="${PERFORMANCE_GUARD_GOFLAGS:--mod=readonly}"
  go_toolchain="${PERFORMANCE_GUARD_GOTOOLCHAIN:-local}"
fi

require_cmd awk docker git
runtime_dir="$(resolve_directory "$runtime_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
[[ -f "$runtime_dir/runtime.env" ]] || die "Runtime is missing runtime.env"
kind_wrapper="$runtime_dir/bin/kind"
docker_wrapper="$runtime_dir/bin/docker"
[[ -x "$kind_wrapper" ]] || die "Runtime Kind wrapper is missing or not executable: $kind_wrapper"
[[ -x "$docker_wrapper" ]] || die "Runtime Docker wrapper is missing or not executable: $docker_wrapper"
git -C "$candidate_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  die "Candidate is not a Git working tree: $candidate_dir"

runner_image="$({
  awk -F= '$1 == "RUNNER_IMAGE" {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' \
    "$runtime_dir/runtime.env" | tr -d '\r'
} || true)"
if [[ -n "$runner_image_override" ]]; then
  runner_image="$runner_image_override"
fi
[[ "$runner_image" =~ ^[A-Za-z0-9_./:@-]+$ ]] || \
  die "runtime.env contains a missing or unsafe RUNNER_IMAGE"
docker image inspect "$runner_image" >/dev/null 2>&1 || \
  die "Offline Runner image is missing: $runner_image"

if [[ -z "$state_dir" ]]; then
  state_dir="$script_dir/../../.work/candidate-state"
fi
mkdir -p -- "$state_dir/home" "$state_dir/go-build" "$state_dir/go-mod"
state_dir="$(resolve_directory "$state_dir")"

docker_args=(
  run --rm --interactive
  --network "$network_mode"
  -e FORCE_REBUILD=true
  -e "GOPROXY=$go_proxy"
  -e "GOSUMDB=$go_sumdb"
  -e "GOTOOLCHAIN=$go_toolchain"
  -e "GOFLAGS=$go_flags"
  -e "VOLCANO_RUNTIME_CGROUPNS_MODE=${VOLCANO_RUNTIME_CGROUPNS_MODE:-${VOLCANO_OFFLINE_CGROUPNS_MODE:-host}}"
  -e "VOLCANO_RUNTIME_REGISTRY_NAME=${VOLCANO_RUNTIME_REGISTRY_NAME:-volcano-performance-registry}"
  -e "VOLCANO_RUNTIME_REGISTRY_ADDR=${VOLCANO_RUNTIME_REGISTRY_ADDR:-volcano-performance-registry:5000}"
  -e GIT_CONFIG_COUNT=1
  -e GIT_CONFIG_KEY_0=safe.directory
  -e GIT_CONFIG_VALUE_0=/workspace/volcano
  -v "$candidate_dir:/workspace/volcano:ro"
  -v "$state_dir/home:/root"
  -v "$state_dir/go-build:/root/.cache/go-build"
  -v "$state_dir/go-mod:/go/pkg/mod"
  -v "$kind_wrapper:/usr/local/bin/kind:ro"
  -v "$docker_wrapper:/usr/local/bin/docker:ro"
  -w /workspace/volcano
)

if [[ -n "$output_dir" ]]; then
  mkdir -p -- "$output_dir"
  output_dir="$(resolve_directory "$output_dir")"
  docker_args+=(-v "$output_dir:/workspace/output")
fi

if [[ "$with_docker_socket" == true ]]; then
  [[ -S /var/run/docker.sock ]] || die "Docker socket is unavailable"
  docker_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
fi

exec docker "${docker_args[@]}" "$runner_image" "$@"
