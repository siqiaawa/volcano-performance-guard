#!/usr/bin/env python3
"""Render the community audit-enabled Kind config without touching the checkout."""
from __future__ import annotations

import argparse
from pathlib import Path

import yaml


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--policy-path", type=Path, required=True)
    parser.add_argument("--audit-log-dir", type=Path, required=True)
    parser.add_argument("--prometheus-port", type=int, default=30013)
    parser.add_argument("--grafana-port", type=int, default=30014)
    parser.add_argument("--workers", type=int, default=1)
    args = parser.parse_args()

    if args.workers < 0:
        parser.error("--workers must be non-negative")
    for path in (args.policy_path, args.audit_log_dir):
        if not path.is_absolute():
            parser.error(f"path must be absolute: {path}")
    document = yaml.safe_load(args.template.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or not isinstance(document.get("nodes"), list):
        parser.error("Kind template must contain a nodes list")
    control_plane = next((node for node in document["nodes"] if node.get("role") == "control-plane"), None)
    if control_plane is None:
        parser.error("Kind template has no control-plane node")

    mounts = control_plane.setdefault("extraMounts", [])
    replaced = set()
    for mount in mounts:
        container_path = mount.get("containerPath")
        if container_path == "/etc/kubernetes/policies/audit-policy.yaml":
            mount["hostPath"] = str(args.policy_path)
            replaced.add("policy")
        elif container_path == "/var/log/kubernetes":
            mount["hostPath"] = str(args.audit_log_dir)
            replaced.add("logs")
    if replaced != {"policy", "logs"}:
        parser.error("Kind template must mount both audit policy and audit log")

    ports = control_plane.setdefault("extraPortMappings", [])
    for mapping, host_port in zip(ports[:2], (args.prometheus_port, args.grafana_port)):
        mapping["hostPort"] = host_port
    if len(ports) < 2:
        parser.error("Kind template must expose Prometheus and Grafana ports")

    document["nodes"] = [control_plane] + [{"role": "worker"} for _ in range(args.workers)]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(yaml.safe_dump(document, sort_keys=False), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
