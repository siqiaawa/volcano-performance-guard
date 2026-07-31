#!/usr/bin/env python3
"""Collect minimal offline performance metrics from an upstream Volcano Benchmark run."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import re
import sys
from pathlib import Path
from typing import Any


class MetricsError(RuntimeError):
    pass


def parse_timestamp(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = fraction * (len(ordered) - 1)
    lower = math.floor(index)
    upper = math.ceil(index)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower)


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise MetricsError(f"Expected a JSON object: {path}")
    return value


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    values: list[dict[str, Any]] = []
    if not path.exists():
        return values
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line:
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise MetricsError(f"Expected a JSON object at line {line_number}: {path}")
        values.append(value)
    return values


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line or line.lstrip().startswith("#"):
            continue
        if "=" not in line:
            raise MetricsError(f"Invalid metadata line {line_number}: {path}")
        key, value = line.split("=", 1)
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", key) or key in values:
            raise MetricsError(f"Invalid or duplicate metadata key at line {line_number}: {key}")
        values[key] = value
    return values


def required(metadata: dict[str, str], key: str) -> str:
    value = metadata.get(key)
    if value is None or value == "":
        raise MetricsError(f"Run metadata is missing {key}")
    return value


def positive_int(metadata: dict[str, str], key: str) -> int:
    value = required(metadata, key)
    if not value.isdigit() or int(value) < 1:
        raise MetricsError(f"Run metadata {key} must be a positive integer")
    return int(value)


def boolean(metadata: dict[str, str], key: str) -> bool:
    value = required(metadata, key)
    if value not in {"true", "false"}:
        raise MetricsError(f"Run metadata {key} must be true or false")
    return value == "true"


def pod_scheduled_time(pod: dict[str, Any]) -> str | None:
    for condition in pod.get("status", {}).get("conditions", []):
        if condition.get("type") == "PodScheduled" and condition.get("status") == "True":
            value = condition.get("lastTransitionTime")
            return value if isinstance(value, str) else None
    return None


def pod_metrics(pods: list[dict[str, Any]], expected: int) -> dict[str, Any]:
    latencies: list[float] = []
    scheduled = 0
    failed = 0
    pending_observed = 0
    for pod in pods:
        phase = pod.get("status", {}).get("phase")
        scheduled_at = pod_scheduled_time(pod)
        if scheduled_at is not None:
            scheduled += 1
            created_at = pod.get("metadata", {}).get("creationTimestamp")
            if isinstance(created_at, str):
                latency = (parse_timestamp(scheduled_at) - parse_timestamp(created_at)).total_seconds() * 1000
                if latency < 0:
                    raise MetricsError("A PodScheduled timestamp precedes its creation timestamp")
                latencies.append(latency)
        elif phase != "Failed":
            pending_observed += 1
        if phase == "Failed":
            failed += 1

    observed = len(pods)
    missing = max(expected - observed, 0)
    pending = pending_observed + missing
    return {
        "latencies": latencies,
        "observed": observed,
        "scheduled": scheduled,
        "failed": failed,
        "pending": pending,
        "missing": missing,
    }


def event_metrics(path: Path) -> tuple[float | None, float | None, list[str]]:
    submitted_at: dt.datetime | None = None
    results_at: dt.datetime | None = None
    test_duration: float | None = None
    output_lines: list[str] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise MetricsError(f"Invalid go test JSON event at line {line_number}: {path}") from exc
        if not isinstance(event, dict):
            raise MetricsError(f"Non-object go test event at line {line_number}: {path}")
        output = event.get("Output")
        event_time = event.get("Time")
        if isinstance(output, str):
            output_lines.append(output)
            if "Submitted " in output and submitted_at is None and isinstance(event_time, str):
                submitted_at = parse_timestamp(event_time)
            if "=== Results ===" in output and isinstance(event_time, str):
                results_at = parse_timestamp(event_time)
        if (
            event.get("Test") == "TestFromConfig"
            and event.get("Action") in {"pass", "fail"}
            and isinstance(event.get("Elapsed"), (int, float))
        ):
            test_duration = float(event["Elapsed"])

    scheduling_duration: float | None = None
    if submitted_at is not None and results_at is not None:
        scheduling_duration = (results_at - submitted_at).total_seconds()
        if scheduling_duration < 0:
            raise MetricsError("Benchmark result event precedes its submission event")
    return scheduling_duration, test_duration, output_lines


def restart_total(document: dict[str, Any]) -> int:
    return sum(
        int(status.get("restartCount", 0))
        for pod in document.get("items", [])
        for status in pod.get("status", {}).get("containerStatuses", [])
    )


def format_number(value: Any) -> str:
    if value is None:
        return "N/A"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return f"{value:.6g}"
    return str(value)


def scheduler_sample_metrics(samples: list[dict[str, Any]]) -> dict[str, float | None]:
    cpu = [float(value["cpuCores"]) for value in samples if isinstance(value.get("cpuCores"), (int, float))]
    memory = [float(value["memoryMb"]) for value in samples if isinstance(value.get("memoryMb"), (int, float))]
    return {
        "scheduler_cpu_peak_cores": max(cpu) if cpu else None,
        "scheduler_memory_peak_mb": max(memory) if memory else None,
    }


def audit_metric_values(document: dict[str, Any], expected: int) -> dict[str, float]:
    latency = document.get("pod_scheduling_latency_seconds")
    if not isinstance(latency, dict):
        raise MetricsError("Audit report is missing pod_scheduling_latency_seconds")
    values: dict[str, float] = {}
    for percentile_name in ("p50", "p90", "p99"):
        value = latency.get(percentile_name)
        if not isinstance(value, (int, float)):
            raise MetricsError(f"Audit report is missing latency {percentile_name}")
        values[f"pod_scheduling_latency_{percentile_name}_ms"] = float(value) * 1000
    count = latency.get("count")
    if not isinstance(count, (int, float)) or count < expected:
        raise MetricsError(f"Audit report contains {count!r} bindings, expected at least {expected}")
    return values


def markdown(result: dict[str, Any]) -> str:
    metrics = result["metrics"]
    rows = [
        ("Benchmark status", result["status"]),
        ("Expected Pods", metrics["expected_pods"]),
        ("Observed Pods", metrics["observed_pods"]),
        ("Scheduled Pods", metrics["scheduled_pods"]),
        ("Failed Pods", metrics["failed_pods"]),
        ("Pending/Missing Pods", metrics["pending_pods"]),
        ("Scheduled ratio", metrics["scheduled_pod_ratio"]),
        ("Submission-to-scheduled duration (s)", metrics["total_scheduling_duration_seconds"]),
        ("Throughput (Pods/s)", metrics["pod_scheduling_throughput_pods_per_second"]),
        ("Pod scheduling p50 (ms)", metrics["pod_scheduling_latency_p50_ms"]),
        ("Pod scheduling p90 (ms)", metrics["pod_scheduling_latency_p90_ms"]),
        ("Pod scheduling p99 (ms)", metrics["pod_scheduling_latency_p99_ms"]),
        ("Scheduler restart delta", metrics["scheduler_restart_count"]),
    ]
    lines = [
        f"# Community Benchmark: {result['scenario']}",
        "",
        f"Candidate: `{result['candidateCommit']}`",
        "",
        "| Metric | Value |",
        "| --- | ---: |",
    ]
    lines.extend(f"| {name} | {format_number(value)} |" for name, value in rows)
    lines.extend(["", f"> {result['measurement']['note']}", ""])
    return "\n".join(lines)


def collect(
    metadata: dict[str, str],
    pods_document: dict[str, Any],
    events_path: Path,
    scheduler_before: dict[str, Any],
    scheduler_after: dict[str, Any],
    audit_document: dict[str, Any] | None = None,
    samples: list[dict[str, Any]] | None = None,
) -> tuple[dict[str, Any], list[str]]:
    commit = required(metadata, "candidateCommit")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise MetricsError("candidateCommit must be a full Git SHA")
    scenario = required(metadata, "scenario")
    if scenario not in {"pod", "gang"}:
        raise MetricsError("scenario must be pod or gang")
    expected = positive_int(metadata, "expectedPods")
    test_status_text = required(metadata, "testStatus")
    if not re.fullmatch(r"[0-9]+", test_status_text):
        raise MetricsError("testStatus must be a non-negative integer")
    test_status = int(test_status_text)

    pods = pods_document.get("items")
    if not isinstance(pods, list) or not all(isinstance(pod, dict) for pod in pods):
        raise MetricsError("Pod capture must contain an items array")
    pod_result = pod_metrics(pods, expected)
    scheduling_duration, test_duration, log_lines = event_metrics(events_path)
    restart_delta = max(restart_total(scheduler_after) - restart_total(scheduler_before), 0)
    ratio = pod_result["scheduled"] / expected
    throughput = None
    if scheduling_duration is not None and scheduling_duration > 0:
        throughput = pod_result["scheduled"] / scheduling_duration
    latencies = pod_result["latencies"]
    success = (
        test_status == 0
        and pod_result["scheduled"] == expected
        and pod_result["failed"] == 0
        and pod_result["pending"] == 0
        and restart_delta == 0
        and len(latencies) == expected
    )
    measured_metrics: dict[str, Any] = {
        "pod_scheduling_latency_p50_ms": percentile(latencies, 0.50),
        "pod_scheduling_latency_p90_ms": percentile(latencies, 0.90),
        "pod_scheduling_latency_p99_ms": percentile(latencies, 0.99),
        **scheduler_sample_metrics(samples or []),
    }
    measurement = {
        "latencySource": "kubernetes-pod-status-timestamps",
        "latencyPrecision": "seconds",
        "durationSource": "go-test-json-submitted-to-results",
        "latencyGateEligible": False,
        "note": "Pod latency uses Kubernetes status timestamps with second-level precision and is not eligible for a formal latency gate.",
    }
    if audit_document is not None:
        measured_metrics.update(audit_metric_values(audit_document, expected))
        measurement.update(
            {
                "latencySource": "kube-apiserver-audit-exporter-prometheus",
                "latencyPrecision": "microseconds",
                "latencyGateEligible": True,
                "note": "Pod latency comes from API Server audit MicroTime events collected by the imported Audit Exporter and Prometheus.",
            }
        )
    metrics = {
        **measured_metrics,
        "pod_scheduling_throughput_pods_per_second": throughput,
        "total_scheduling_duration_seconds": scheduling_duration,
        "test_duration_seconds": test_duration,
        "expected_pods": expected,
        "observed_pods": pod_result["observed"],
        "scheduled_pods": pod_result["scheduled"],
        "failed_pods": pod_result["failed"],
        "pending_pods": pod_result["pending"],
        "missing_pods": pod_result["missing"],
        "scheduled_pod_ratio": ratio,
        "scheduler_restart_count": restart_delta,
        "benchmark_success": success,
    }
    result = {
        "schemaVersion": "v1",
        "candidateCommit": commit,
        "clusterName": required(metadata, "clusterName"),
        "scenario": scenario,
        "requestedCount": positive_int(metadata, "requestedCount"),
        "scheduler": required(metadata, "scheduler"),
        "kwok": boolean(metadata, "kwok"),
        "status": "success" if success else "failed",
        "benchmarkSuccess": success,
        "method": "upstream-go-test-from-config+pod-status-metrics",
        "measurement": measurement,
        "metrics": metrics,
    }
    return result, log_lines


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--pods", type=Path, required=True)
    parser.add_argument("--events", type=Path, required=True)
    parser.add_argument("--scheduler-before", type=Path, required=True)
    parser.add_argument("--scheduler-after", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--markdown-output", type=Path, required=True)
    parser.add_argument("--log-output", type=Path, required=True)
    parser.add_argument("--audit-report", type=Path)
    parser.add_argument("--scheduler-samples", type=Path)
    args = parser.parse_args()
    try:
        result, log_lines = collect(
            load_env(args.metadata),
            load_json(args.pods),
            args.events,
            load_json(args.scheduler_before),
            load_json(args.scheduler_after),
            load_json(args.audit_report) if args.audit_report else None,
            load_jsonl(args.scheduler_samples) if args.scheduler_samples else [],
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        args.markdown_output.write_text(markdown(result), encoding="utf-8")
        args.log_output.write_text("".join(log_lines), encoding="utf-8")
    except (OSError, ValueError, KeyError, json.JSONDecodeError, MetricsError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    print(f"Community Benchmark metrics written to {args.output}")
    return 0 if result["benchmarkSuccess"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
