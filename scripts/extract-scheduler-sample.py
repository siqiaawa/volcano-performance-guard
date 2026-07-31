#!/usr/bin/env python3
"""Extract scheduler CPU/memory samples from a kubelet summary JSON stream."""
from __future__ import annotations

import json
import sys


def main() -> int:
    document = json.load(sys.stdin)
    for pod in document.get("pods", []):
        reference = pod.get("podRef", {})
        if reference.get("namespace") != "volcano-system" or not reference.get("name", "").startswith("volcano-scheduler-"):
            continue
        for container in pod.get("containers", []):
            if container.get("name") != "volcano-scheduler":
                continue
            print(json.dumps({
                "cpuCores": (container.get("cpu", {}).get("usageNanoCores") or 0) / 1_000_000_000,
                "memoryMb": (container.get("memory", {}).get("workingSetBytes") or 0) / 1_000_000,
            }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
