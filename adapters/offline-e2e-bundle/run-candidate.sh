#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: run-candidate.sh --bundle-dir PATH --candidate-dir PATH
                        [--state-dir PATH] [--network MODE]
                        [--runner-image NAME]
                        [--output-dir PATH]
                        [--with-docker-socket] -- COMMAND [ARG...]

Run a command in the bundle's offline Runner with the external candidate
checkout mounted read-only at /workspace/volcano. Network mode defaults to
none. The Docker socket is absent unless --with-docker-socket is explicit.
EOF
}

bundle_dir=""
candidate_dir=""
state_dir=""
network_mode="none"
with_docker_socket=false
runner_image_override=""
output_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-dir)
      [[ $# -ge 2 ]] || die "--bundle-dir requires a value"
      bundle_dir="$2"
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

[[ -n "$bundle_dir" ]] || die "--bundle-dir is required"
[[ -n "$candidate_dir" ]] || die "--candidate-dir is required"
[[ $# -gt 0 ]] || die "A command is required after --"
[[ "$network_mode" == "none" || "$network_mode" == "host" ]] || \
  die "--network must be none or host"

require_cmd awk docker git
bundle_dir="$(resolve_directory "$bundle_dir")"
candidate_dir="$(resolve_directory "$candidate_dir")"
[[ -f "$bundle_dir/offline.env" ]] || die "Bundle is missing offline.env"
git -C "$candidate_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  die "Candidate is not a Git working tree: $candidate_dir"

runner_image="$({
  awk -F= '$1 == "RUNNER_IMAGE" {sub(/^[^=]*=/, ""); print; found=1} END {if (!found) exit 1}' \
    "$bundle_dir/offline.env" | tr -d '\r'
} || true)"
if [[ -n "$runner_image_override" ]]; then
  runner_image="$runner_image_override"
fi
[[ "$runner_image" =~ ^[A-Za-z0-9_./:@-]+$ ]] || \
  die "offline.env contains a missing or unsafe RUNNER_IMAGE"
docker image inspect "$runner_image" >/dev/null 2>&1 || \
  die "Offline Runner image is missing: $runner_image"

if [[ -z "$state_dir" ]]; then
  state_dir="$script_dir/../../.work/candidate-state"
fi
mkdir -p -- "$state_dir/home" "$state_dir/go-build"
state_dir="$(resolve_directory "$state_dir")"

docker_args=(
  run --rm --interactive
  --network "$network_mode"
  -e FORCE_REBUILD=true
  -e GOPROXY=off
  -e GOSUMDB=off
  -e GOTOOLCHAIN=local
  -e GOFLAGS=-mod=readonly
  -e GIT_CONFIG_COUNT=1
  -e GIT_CONFIG_KEY_0=safe.directory
  -e GIT_CONFIG_VALUE_0=/workspace/volcano
  -v "$candidate_dir:/workspace/volcano:ro"
  -v "$state_dir/home:/root"
  -v "$state_dir/go-build:/root/.cache/go-build"
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
