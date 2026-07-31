#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "${root_dir}/scripts/run-performance-tools.sh" "${root_dir}/scripts/mock-bundle-adapter.py" cleanup "$@"
