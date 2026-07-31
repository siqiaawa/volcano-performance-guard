#!/usr/bin/env python3
"""Run a small, offline Volcano Pod benchmark on an already deployed candidate cluster."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import platform
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from lib.contracts import ContractError, fingerprint, require_valid, write_json  # noqa: E402


class BenchmarkError(RuntimeError):
    pass


def command_output(command: list[str], *, input_text: str | None = None) -> str:
    result = subprocess.run(command, input=input_text, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no command output"
        raise BenchmarkError(f"Command failed ({result.returncode}): {' '.join(command)}\n{detail}")
    return result.stdout


def git_value(directory: Path, *arguments: str) -> str:
    return command_output(["git", "-C", str(directory), *arguments]).strip()


def parse_timeout(value: str) -> float:
    match = re.fullmatch(r"([1-9][0-9]*)([smh])", value)
    if not match:
        raise BenchmarkError(f"Unsupported profile timeout: {value}")
    multiplier = {"s": 1, "m": 60, "h": 3600}[match.group(2)]
    return int(match.group(1)) * multiplier


def parse_timestamp(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        raise BenchmarkError("No scheduling latencies were recorded")
    ordered = sorted(values)
    index = fraction * (len(ordered) - 1)
    lower = math.floor(index)
    upper = math.ceil(index)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower)


def cpu_model() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or platform.machine()


def memory_bytes() -> int:
    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) * 1024
    except (OSError, IndexError, ValueError):
        pass
    raise BenchmarkError("Cannot determine runner memory from /proc/meminfo")


def performance_tools_version() -> str:
    files = (
        Path(__file__),
        Path(__file__).with_name("run-candidate.sh"),
        ROOT / "scripts" / "run-timestamp-profile.py",
        ROOT / "scripts" / "aggregate-metrics.py",
        ROOT / "scripts" / "lib" / "contracts.py",
    )
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.relative_to(ROOT).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return f"pod-timestamps-v1+sha256:{digest.hexdigest()}"


def candidate_command(arguments: argparse.Namespace, *kubectl_args: str) -> list[str]:
    return [
        "bash",
        str(Path(__file__).with_name("run-candidate.sh")),
        "--bundle-dir",
        str(arguments.bundle_dir),
        "--candidate-dir",
        str(arguments.candidate_dir),
        "--runner-image",
        arguments.runner_image,
        "--state-dir",
        str(arguments.state_dir),
        "--network",
        "host",
        "--with-docker-socket",
        "--",
        "kubectl",
        *kubectl_args,
    ]


def kubectl_json(arguments: argparse.Namespace, *kubectl_args: str) -> dict[str, Any]:
    return json.loads(command_output(candidate_command(arguments, *kubectl_args)))


def scheduler_sample(arguments: argparse.Namespace, node_name: str) -> dict[str, float]:
    summary = kubectl_json(arguments, "get", "--raw", f"/api/v1/nodes/{node_name}/proxy/stats/summary")
    for pod in summary.get("pods", []):
        reference = pod.get("podRef", {})
        if reference.get("namespace") != "volcano-system" or not reference.get("name", "").startswith("volcano-scheduler-"):
            continue
        for container in pod.get("containers", []):
            if container.get("name") != "volcano-scheduler":
                continue
            cpu = container.get("cpu", {}).get("usageNanoCores")
            memory = container.get("memory", {}).get("workingSetBytes")
            if isinstance(cpu, int) and isinstance(memory, int):
                return {"cpuCores": cpu / 1_000_000_000, "memoryMb": memory / 1_000_000}
    raise BenchmarkError("Kubelet summary did not contain a measurable volcano-scheduler container")


def pod_manifest(namespace: str, label_value: str, count: int, scheduler_name: str) -> str:
    manifests: list[dict[str, Any]] = []
    for index in range(count):
        manifests.append(
            {
                "apiVersion": "v1",
                "kind": "Pod",
                "metadata": {
                    "name": f"performance-{label_value}-{index}",
                    "namespace": namespace,
                    "labels": {"volcano.sh/performance-guard-run": label_value},
                },
                "spec": {
                    "schedulerName": scheduler_name,
                    "restartPolicy": "Never",
                    "tolerations": [
                        {"key": "node-role.kubernetes.io/control-plane", "operator": "Exists", "effect": "NoSchedule"},
                        {"key": "node-role.kubernetes.io/master", "operator": "Exists", "effect": "NoSchedule"},
                    ],
                    "containers": [
                        {
                            "name": "workload",
                            "image": "busybox:latest",
                            "imagePullPolicy": "Always",
                            "command": ["sh", "-c", "sleep 120"],
                        }
                    ],
                },
            }
        )
    return "---\n".join(yaml.safe_dump(manifest, sort_keys=False) for manifest in manifests)


def scheduled_pod_latencies(items: list[dict[str, Any]]) -> tuple[list[float], int]:
    latencies: list[float] = []
    failed = 0
    for item in items:
        phase = item.get("status", {}).get("phase")
        if phase == "Failed":
            failed += 1
        created = item.get("metadata", {}).get("creationTimestamp")
        conditions = item.get("status", {}).get("conditions", [])
        scheduled = next(
            (condition.get("lastTransitionTime") for condition in conditions if condition.get("type") == "PodScheduled" and condition.get("status") == "True"),
            None,
        )
        if created and scheduled:
            latencies.append((parse_timestamp(scheduled) - parse_timestamp(created)).total_seconds() * 1000)
    return latencies, failed


def provenance(arguments: argparse.Namespace, profile: dict[str, Any], node: dict[str, Any], scheduler_config: dict[str, Any]) -> tuple[str, dict[str, Any]]:
    bundle_detection = yaml.safe_load((ROOT / "configs" / "offline-bundle.detected.yaml").read_text(encoding="utf-8"))
    bundle = bundle_detection["bundle"]
    node_info = node.get("status", {}).get("nodeInfo", {})
    runtime = node_info.get("containerRuntimeVersion", "unknown").split("://", 1)
    runtime_name, runtime_version = (runtime[0], runtime[1]) if len(runtime) == 2 else (runtime[0], "unknown")
    config_hash = fingerprint(scheduler_config.get("data", {}))
    test_code_commit = git_value(ROOT, "rev-parse", "HEAD")
    runner = {"cpuModel": cpu_model(), "cpuCores": os.cpu_count() or 1, "memoryBytes": memory_bytes()}
    record = {
        "baseEnvironmentBundle": {
            "name": bundle["name"],
            "version": bundle.get("semanticVersion"),
            "fingerprint": bundle["fingerprint"],
            "archiveSha256": None,
        },
        "kubernetesVersion": node_info.get("kubeletVersion", "unknown"),
        "containerRuntime": {"name": runtime_name, "version": runtime_version},
        "architecture": node_info.get("architecture", "amd64"),
        "runner": runner,
        "stableVolcanoVersion": f"reference-commit-{bundle_detection['referenceVolcano']['commit']}",
        "volcanoConfigHash": config_hash,
        "performanceToolsVersion": performance_tools_version(),
        "testCodeCommit": test_code_commit,
    }
    environment = {
        "bundleFingerprint": bundle["fingerprint"],
        "kubernetesVersion": record["kubernetesVersion"],
        "containerRuntime": record["containerRuntime"],
        "architecture": record["architecture"],
        "runner": runner,
        "volcanoConfigHash": config_hash,
        "performanceToolsVersion": record["performanceToolsVersion"],
        "testCodeCommit": test_code_commit,
    }
    return fingerprint(environment), record


def main() -> int:
    parser = argparse.ArgumentParser(description="Run an offline Pod timestamp benchmark against a deployed candidate Volcano cluster")
    parser.add_argument("--bundle-dir", type=Path, required=True)
    parser.add_argument("--candidate-dir", type=Path, required=True)
    parser.add_argument("--runner-image", required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--cluster-name", required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--iteration", type=int, required=True)
    parser.add_argument("--warmup", action="store_true")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--namespace", default="volcano-performance")
    args = parser.parse_args()

    label_value = re.sub(r"[^a-z0-9-]", "-", f"{args.run_id}-{args.iteration}".lower()).strip("-")[-50:]
    try:
        for path in (args.bundle_dir, args.candidate_dir, args.state_dir):
            if not path.is_dir():
                raise BenchmarkError(f"Directory not found: {path}")
        profile = yaml.safe_load(args.profile.read_text(encoding="utf-8"))
        require_valid("profile", profile, args.profile)
        workload = profile["workload"]
        if workload["type"] != "pod":
            raise BenchmarkError("Timestamp benchmark supports only workload.type=pod")
        count = workload["podCount"]
        scheduler_name = workload.get("schedulerName", "volcano")
        timeout = parse_timeout(profile["execution"]["timeout"])

        marker = args.state_dir / "cluster.marker"
        marker_text = marker.read_text(encoding="utf-8")
        if f"CLUSTER_NAME={args.cluster_name}" not in marker_text:
            raise BenchmarkError("Cluster marker does not match --cluster-name")
        candidate_commit = git_value(args.candidate_dir, "rev-parse", "HEAD")
        if f"CANDIDATE_COMMIT={candidate_commit}" not in marker_text:
            raise BenchmarkError("Cluster marker does not match the candidate commit")

        command_output(candidate_command(args, "create", "namespace", args.namespace, "--dry-run=client", "-o", "yaml"),)
    except (BenchmarkError, ContractError, OSError, yaml.YAMLError, KeyError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    # Namespace creation is intentionally performed via apply so an existing namespace is harmless.
    try:
        namespace_manifest = yaml.safe_dump({"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": args.namespace}}, sort_keys=False)
        command_output(candidate_command(args, "apply", "-f", "-"), input_text=namespace_manifest)
        command_output(candidate_command(args, "delete", "pods", "-n", args.namespace, "-l", f"volcano.sh/performance-guard-run={label_value}", "--ignore-not-found=true"))
        nodes = kubectl_json(args, "get", "nodes", "-o", "json")
        if len(nodes.get("items", [])) != 1:
            raise BenchmarkError("Timestamp smoke benchmark requires exactly one dedicated Kind node")
        node = nodes["items"][0]
        node_name = node["metadata"]["name"]
        scheduler_config = kubectl_json(args, "get", "configmap", "volcano-scheduler-configmap", "-n", "volcano-system", "-o", "json")
        environment_fingerprint, provenance_record = provenance(args, profile, node, scheduler_config)

        start = time.monotonic()
        command_output(
            candidate_command(args, "apply", "-f", "-"),
            input_text=pod_manifest(args.namespace, label_value, count, scheduler_name),
        )
        samples: list[dict[str, float]] = []
        latest: dict[str, Any] = {}
        while time.monotonic() - start < timeout:
            try:
                samples.append(scheduler_sample(args, node_name))
            except BenchmarkError:
                # The pod is always sampled again before a success result is accepted.
                pass
            latest = kubectl_json(args, "get", "pods", "-n", args.namespace, "-l", f"volcano.sh/performance-guard-run={label_value}", "-o", "json")
            latencies, failed = scheduled_pod_latencies(latest.get("items", []))
            if len(latencies) == count and failed == 0:
                break
            time.sleep(0.5)
        elapsed = time.monotonic() - start
        items = latest.get("items", [])
        latencies, failed = scheduled_pod_latencies(items)
        scheduled = len(latencies)
        pending = max(count - scheduled - failed, 0)
        if not samples:
            raise BenchmarkError("No scheduler CPU/memory sample was available during the benchmark")
        restarts = kubectl_json(args, "get", "pods", "-n", "volcano-system", "-l", "app=volcano-scheduler", "-o", "json")
        scheduler_restarts = sum(
            status.get("restartCount", 0)
            for pod in restarts.get("items", [])
            for status in pod.get("status", {}).get("containerStatuses", [])
        )
        success = scheduled == count and failed == 0 and pending == 0 and scheduler_restarts == 0
        if not success and not latencies:
            raise BenchmarkError("No scheduled benchmark Pod exists; no latency metric can be emitted")
        metrics = {
            "pod_scheduling_latency_p50_ms": percentile(latencies, 0.50),
            "pod_scheduling_latency_p90_ms": percentile(latencies, 0.90),
            "pod_scheduling_latency_p99_ms": percentile(latencies, 0.99),
            "pod_scheduling_throughput_pods_per_second": scheduled / elapsed if elapsed > 0 else 0.0,
            "total_scheduling_duration_seconds": elapsed,
            "expected_pods": count,
            "scheduled_pods": scheduled,
            "failed_pods": failed,
            "pending_pods": pending,
            "scheduled_pod_ratio": scheduled / count,
            "scheduler_cpu_peak_cores": max(sample["cpuCores"] for sample in samples),
            "scheduler_memory_peak_mb": max(sample["memoryMb"] for sample in samples),
            "scheduler_restart_count": scheduler_restarts,
            "benchmark_success": success,
        }
        result = {
            "schemaVersion": "v1",
            "metadata": {
                "runId": args.run_id,
                "profile": profile["name"],
                "profileHash": fingerprint(profile),
                "environmentFingerprint": environment_fingerprint,
                "subject": {"type": "candidate", "version": candidate_commit, "commit": candidate_commit},
                "provenance": provenance_record,
                "iteration": args.iteration,
                "warmup": args.warmup,
            },
            "status": "success" if success else "failed",
            "metrics": metrics,
        }
        require_valid("run-metrics", result, "timestamp benchmark result")
        write_json(args.output, result)
        raw_dir = args.output.parent / f"{args.output.stem}.artifacts"
        raw_dir.mkdir(parents=True, exist_ok=True)
        write_json(raw_dir / "pods.json", latest)
        write_json(raw_dir / "scheduler-samples.json", {"samples": samples})
        write_json(
            raw_dir / "measurement.json",
            {
                "method": "kubernetes-pod-status-timestamps",
                "latencyPrecision": "seconds",
                "latencyGateEligible": False,
                "note": "Use an approved audit-exporter and Prometheus tool bundle for sub-second latency gating.",
            },
        )
        print(f"Timestamp benchmark {'passed' if success else 'failed'}: {args.output}")
        return 0 if success else 2
    except (BenchmarkError, ContractError, OSError, ValueError, KeyError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    finally:
        try:
            command_output(candidate_command(args, "delete", "pods", "-n", args.namespace, "-l", f"volcano.sh/performance-guard-run={label_value}", "--ignore-not-found=true"))
        except (BenchmarkError, OSError):
            print("[WARN] Benchmark Pod cleanup did not complete", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
