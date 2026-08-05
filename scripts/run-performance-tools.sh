#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: run-performance-tools.sh [--image IMAGE] [--network MODE] SCRIPT [ARG...]

Run one performance-guard Python script inside the pinned offline tools image.
The project and any absolute input/output paths in the argument list are
mounted at their original paths. Docker is required; Python is not required on
the host when the tools image has already been imported.
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd -- "$script_dir/.." && pwd -P)"
tools_image="${PERFORMANCE_GUARD_TOOLS_IMAGE:-}"
network_mode="${PERFORMANCE_GUARD_TOOLS_NETWORK:-none}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) tools_image="${2:?}"; shift 2 ;;
    --network) network_mode="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
[[ "$network_mode" == "none" || "$network_mode" == "host" ]] || {
  printf '[ERROR] tools network must be none or host\n' >&2
  exit 2
}

python_script="$1"
shift
if [[ "$python_script" != /* ]]; then
  python_script="$project_dir/$python_script"
fi
[[ -f "$python_script" ]] || {
  printf '[ERROR] Python script is missing: %s\n' "$python_script" >&2
  exit 1
}

tools_image_available=false
if [[ -n "$tools_image" ]] && command -v docker >/dev/null 2>&1 \
    && docker image inspect "$tools_image" >/dev/null 2>&1; then
  tools_image_available=true
fi
if [[ "$tools_image_available" != true ]]; then
  if command -v python3 >/dev/null 2>&1; then
    exec python3 "$python_script" "$@"
  fi
  printf '[ERROR] Performance tools image is missing and host python3 is unavailable; import the benchmark asset package first\n' >&2
  exit 1
fi

docker_args=(
  run --rm --interactive
  --network "$network_mode"
  --entrypoint python3
  -e PYTHONUNBUFFERED=1
  -v "$project_dir:$project_dir"
  -w "$project_dir"
)
if [[ -S /var/run/docker.sock ]]; then
  docker_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
fi

declare -A mounted_paths=()
safe_git_directories=("$project_dir")
add_safe_git_directory() {
  local directory="$1" existing
  for existing in "${safe_git_directories[@]}"; do
    [[ "$existing" == "$directory" ]] && return 0
  done
  safe_git_directories+=("$directory")
}
add_mount() {
  local requested="$1" mode="$2" mount_path
  [[ "$requested" == /* ]] || return 0
  requested="$(realpath -m -- "$requested")"
  if [[ -d "$requested/.git" || -f "$requested/.git" ]]; then
    add_safe_git_directory "$requested"
  fi
  if [[ "$requested" == "$project_dir" || "$requested" == "$project_dir"/* ]]; then
    return 0
  fi
  if [[ -e "$requested" ]]; then
    mount_path="$requested"
  else
    mount_path="$(dirname -- "$requested")"
  fi
  [[ -d "$mount_path" || -f "$mount_path" ]] || return 0
  [[ -n "${mounted_paths[$mount_path]:-}" ]] && return 0
  mounted_paths["$mount_path"]="$mode"
  docker_args+=(-v "$mount_path:$mount_path:$mode")
}

previous_option=""
for argument in "$@"; do
  if [[ "$argument" == /* ]]; then
    mode=ro
    case "$previous_option" in
      --output|--output-dir|--report-dir|--state-dir|--missing-modules-output|--audit-log-dir|--markdown-output|--log-output|--junit-output|--html-output|--audit-output)
        mode=rw
        ;;
    esac
    add_mount "$argument" "$mode"
  fi
  if [[ "$argument" == --* ]]; then
    previous_option="$argument"
  else
    previous_option=""
  fi
done

docker_args+=(-e "GIT_CONFIG_COUNT=${#safe_git_directories[@]}")
for index in "${!safe_git_directories[@]}"; do
  docker_args+=(
    -e "GIT_CONFIG_KEY_${index}=safe.directory"
    -e "GIT_CONFIG_VALUE_${index}=${safe_git_directories[$index]}"
  )
done

exec docker "${docker_args[@]}" "$tools_image" "$python_script" "$@"
