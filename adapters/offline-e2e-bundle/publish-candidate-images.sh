#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../../scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: publish-candidate-images.sh --candidate-dir PATH --build-dir PATH
                                   [--registry-host HOST:PORT]

Publish commit-tagged candidate images to the already running local offline
registry. No public registry target is accepted.
EOF
}

candidate_dir=""
build_dir=""
registry_host="localhost:15000"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --candidate-dir) candidate_dir="${2:?}"; shift 2 ;;
    --build-dir) build_dir="${2:?}"; shift 2 ;;
    --registry-host) registry_host="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "$candidate_dir" ]] || die "--candidate-dir is required"
[[ -n "$build_dir" ]] || die "--build-dir is required"
[[ "$registry_host" =~ ^(localhost|127\.0\.0\.1):[0-9]+$ ]] || \
  die "Registry target must be loopback HOST:PORT"
require_cmd curl docker git
candidate_dir="$(resolve_directory "$candidate_dir")"
build_dir="$(resolve_directory "$build_dir")"
candidate_commit="$(git -C "$candidate_dir" rev-parse HEAD)"
grep -Fx "CANDIDATE_COMMIT=$candidate_commit" "$build_dir/build-metadata.env" >/dev/null || \
  die "Binary build metadata does not match candidate commit"
curl -fsS "http://$registry_host/v2/" >/dev/null || die "Local registry is unavailable: $registry_host"

components=(scheduler controller-manager webhook-manager agent-scheduler agent)
: >"$build_dir/registry-images.env"
for component in "${components[@]}"; do
  source_image="volcanosh/vc-$component:$candidate_commit"
  target_image="$registry_host/volcanosh/vc-$component:$candidate_commit"
  docker image inspect "$source_image" >/dev/null 2>&1 || die "Candidate image is missing: $source_image"
  revision="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$source_image")"
  [[ "$revision" == "$candidate_commit" ]] || die "Candidate image revision label mismatch: $source_image"
  docker tag "$source_image" "$target_image"
  push_output="$(docker push "$target_image")"
  digest="$(awk '/digest:/ {for (i=1; i<=NF; i++) if ($i == "digest:") print $(i+1)}' <<<"$push_output" | tail -n 1)"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "Unable to capture registry digest for $target_image"
  component_key="${component^^}"
  component_key="${component_key//-/_}"
  printf 'REGISTRY_IMAGE_%s=%s\n' "$component_key" "$target_image" >>"$build_dir/registry-images.env"
  printf 'REGISTRY_DIGEST_%s=%s\n' "$component_key" "$digest" >>"$build_dir/registry-images.env"
  log_info "Published $target_image@$digest"
done
