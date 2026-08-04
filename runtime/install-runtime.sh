#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/runtime/runtime.env"
assets_dir="${PERFORMANCE_GUARD_ASSETS_DIR:-$ROOT_DIR/release-assets}"
verify=true

usage() { echo "Usage: runtime/install-runtime.sh [--assets-dir PATH] [--skip-verify]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --assets-dir) assets_dir="${2:?}"; shift 2 ;;
    --skip-verify) verify=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
assets_dir="$(cd -- "$assets_dir" && pwd -P)"
command -v docker >/dev/null || { echo "Docker is required" >&2; exit 1; }
docker info >/dev/null
[[ "$verify" == false ]] || bash "$ROOT_DIR/runtime/verify-runtime.sh" --assets-dir "$assets_dir"

load_if_missing() {
  local image=$1 archive=$2
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "Loading $archive"
    docker load -i "$assets_dir/$archive"
  fi
  docker image inspect "$image" >/dev/null
}
load_if_missing "$RUNNER_IMAGE" "$RUNTIME_RUNNER_ARCHIVE"
load_if_missing "$KIND_NODE_IMAGE" "$RUNTIME_KIND_ARCHIVE"
load_if_missing "volcanosh/vc-scheduler:$RUNTIME_BASE_COMMIT" "$RUNTIME_BASES_ARCHIVE"
load_if_missing "$REGISTRY_IMAGE" "$RUNTIME_SUPPORT_ARCHIVE"
benchmark_images=(
  "$PERFORMANCE_TOOLS_IMAGE"
  "localhost:${REGISTRY_HOST_PORT}/library/busybox:1.36-benchmark-d57d10f47129"
  "localhost:${REGISTRY_HOST_PORT}/prom/prometheus:benchmark-d57d10f47129"
  "localhost:${REGISTRY_HOST_PORT}/grafana/grafana:benchmark-d57d10f47129"
  "localhost:${REGISTRY_HOST_PORT}/volcanosh/kube-state-metrics:v2.0.0-beta-benchmark-d57d10f47129"
  "localhost:${REGISTRY_HOST_PORT}/volcanosh/kube-apiserver-audit-exporter:d57d10f47129b11f12d875de1195a42c0a53270f"
)
benchmark_missing=false
for image in "${benchmark_images[@]}"; do
  docker image inspect "$image" >/dev/null 2>&1 || benchmark_missing=true
done
if [[ "$benchmark_missing" == true ]]; then
  echo "Loading $BENCHMARK_IMAGES_ARCHIVE"
  docker load -i "$assets_dir/$BENCHMARK_IMAGES_ARCHIVE"
fi

if docker container inspect "$REGISTRY_NAME" >/dev/null 2>&1; then
  docker start "$REGISTRY_NAME" >/dev/null
else
  occupying="$(docker ps --format '{{.Names}} {{.Ports}}' | awk -v port=":${REGISTRY_HOST_PORT}->" 'index($0, port) {print $1; exit}')"
  [[ -z "$occupying" ]] || {
    echo "Port ${REGISTRY_HOST_PORT} is owned by container $occupying; stop that old registry before setup" >&2
    exit 1
  }
  docker run -d --restart unless-stopped --name "$REGISTRY_NAME" \
    -p "127.0.0.1:${REGISTRY_HOST_PORT}:5000" "$REGISTRY_IMAGE" >/dev/null
fi

publish() {
  local source=$1 target=$2
  docker image inspect "$source" >/dev/null 2>&1 || return 0
  docker tag "$source" "localhost:${REGISTRY_HOST_PORT}/$target"
  docker push "localhost:${REGISTRY_HOST_PORT}/$target" >/dev/null
}
publish busybox:latest library/busybox:latest
for component in scheduler controller-manager webhook-manager agent-scheduler agent; do
  publish "volcanosh/vc-$component:$RUNTIME_BASE_COMMIT" \
    "volcanosh/vc-$component:$RUNTIME_BASE_COMMIT"
done
curl -fsS "http://localhost:${REGISTRY_HOST_PORT}/v2/" >/dev/null

benchmark_dir="$ROOT_DIR/runtime/benchmark-assets"
cp -- "$assets_dir/$BENCHMARK_IMAGES_ARCHIVE" "$benchmark_dir/benchmark-images.tar"
tools_runner_image="$PERFORMANCE_TOOLS_ASSET_IMAGE"
if ! docker image inspect "$tools_runner_image" >/dev/null 2>&1; then
  tools_runner_image="$PERFORMANCE_TOOLS_IMAGE"
fi
bash "$ROOT_DIR/scripts/run-performance-tools.sh" --image "$tools_runner_image" \
  scripts/import-benchmark-assets.py \
  --asset-dir "$benchmark_dir" --expected-commit d57d10f47129b11f12d875de1195a42c0a53270f \
  --registry-host "localhost:${REGISTRY_HOST_PORT}" --skip-load --skip-registry-probe
rm -f -- "$benchmark_dir/benchmark-images.tar"
chmod +x "$ROOT_DIR/runtime/bin/kind" "$ROOT_DIR/runtime/bin/docker"
echo "Performance Guard runtime is ready"
