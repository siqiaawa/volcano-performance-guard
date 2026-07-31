#!/usr/bin/env python3
"""Collect audit-exporter histogram deltas from a Prometheus HTTP endpoint."""
from __future__ import annotations

import argparse
import json
import math
import sys
import urllib.parse
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


def query(url: str, expression: str, timestamp: str) -> list[dict[str, Any]]:
    endpoint = f"{url.rstrip('/')}/api/v1/query?{urllib.parse.urlencode({'query': expression, 'time': timestamp})}"
    with urllib.request.urlopen(endpoint, timeout=10) as response:
        payload = json.load(response)
    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus query failed: {payload}")
    return payload.get("data", {}).get("result", [])


def buckets(rows: list[dict[str, Any]]) -> dict[str, float]:
    return {str(row.get("metric", {}).get("le")): float(row["value"][1]) for row in rows}


def quantile(before: dict[str, float], after: dict[str, float], fraction: float) -> float | None:
    values = sorted(
        ((key, after.get(key, 0.0) - before.get(key, 0.0)) for key in after),
        key=lambda item: math.inf if item[0] == "+Inf" else float(item[0]),
    )
    total = values[-1][1] if values else 0.0
    if total <= 0:
        return None
    target = fraction * total
    previous_limit = 0.0
    previous_count = 0.0
    for limit_text, count in values:
        limit = math.inf if limit_text == "+Inf" else float(limit_text)
        if count >= target:
            if count == previous_count or math.isinf(limit):
                return limit if math.isfinite(limit) else previous_limit
            return previous_limit + (limit - previous_limit) * (target - previous_count) / (count - previous_count)
        previous_limit, previous_count = limit, count
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prometheus-url", required=True)
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    selector = '{namespace="default"}'
    metric = "pod_scheduling_latency_seconds_bucket"
    try:
        before = buckets(query(args.prometheus_url, f"sum by (le) ({metric}{selector})", args.before))
        after = buckets(query(args.prometheus_url, f"sum by (le) ({metric}{selector})", args.after))
        count_before = query(args.prometheus_url, f"sum(pod_scheduling_latency_seconds_count{selector})", args.before)
        count_after = query(args.prometheus_url, f"sum(pod_scheduling_latency_seconds_count{selector})", args.after)
        before_count = float(count_before[0]["value"][1]) if count_before else 0.0
        after_count = float(count_after[0]["value"][1]) if count_after else 0.0
        report = {
            "time_window": {"before": float(args.before), "after": float(args.after), "seconds": float(args.after) - float(args.before)},
            "pod_scheduling_latency_seconds": {
                "p50": quantile(before, after, 0.50),
                "p90": quantile(before, after, 0.90),
                "p99": quantile(before, after, 0.99),
                "count": max(0, round(after_count - before_count)),
            },
            "prometheus_url": args.prometheus_url,
            "collector": "performance-guard-python-audit-v1",
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, KeyError, RuntimeError, urllib.error.URLError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
