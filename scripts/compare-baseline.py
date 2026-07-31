#!/usr/bin/env python3
"""Compare candidate aggregate metrics to an independently approved baseline."""
from __future__ import annotations

import argparse
import json
import sys
from html import escape
from pathlib import Path
from typing import Any

import yaml

from lib.contracts import ContractError, load_document, require_valid, write_json


COMPARABILITY_KEYS = ("profile", "profileHash", "environmentFingerprint")
PROVENANCE_KEYS = (
    "baseEnvironmentBundle",
    "kubernetesVersion",
    "containerRuntime",
    "architecture",
    "runner",
    "volcanoConfigHash",
    "performanceToolsVersion",
    "testCodeCommit",
)


def compatibility_errors(candidate: dict[str, Any], baseline: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    candidate_meta = candidate["metadata"]
    baseline_meta = baseline["metadata"]
    if candidate_meta["subject"]["type"] != "candidate":
        errors.append("candidate input metadata.subject.type must be candidate")
    if baseline_meta["subject"]["type"] != "stable":
        errors.append("baseline input metadata.subject.type must be stable")
    for key in COMPARABILITY_KEYS:
        if candidate_meta[key] != baseline_meta[key]:
            errors.append(f"metadata.{key} differs")
    for key in PROVENANCE_KEYS:
        if candidate_meta["provenance"][key] != baseline_meta["provenance"][key]:
            errors.append(f"metadata.provenance.{key} differs")
    return errors


def direct_failures(metrics: dict[str, Any]) -> list[str]:
    failures = []
    if not metrics["benchmark_success"]:
        failures.append("benchmark_success=false")
    for name in ("failed_pods", "pending_pods", "scheduler_restart_count"):
        if metrics[name] > 0:
            failures.append(f"{name}={metrics[name]}")
    if metrics["scheduled_pod_ratio"] < 1.0:
        failures.append(f"scheduled_pod_ratio={metrics['scheduled_pod_ratio']}")
    return failures


def load_thresholds(path: Path) -> dict[str, dict[str, Any]]:
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or document.get("schemaVersion") != "v1" or not isinstance(document.get("metrics"), dict):
        raise ContractError(f"Invalid threshold document: {path}")
    thresholds: dict[str, dict[str, Any]] = {}
    for metric, rule in document["metrics"].items():
        if not isinstance(rule, dict) or set(rule) != {"direction", "warningRelative", "failureRelative"}:
            raise ContractError(f"Invalid threshold rule for {metric}")
        if rule["direction"] not in {"lower", "higher"}:
            raise ContractError(f"Invalid threshold direction for {metric}")
        if not 0 <= rule["warningRelative"] <= rule["failureRelative"]:
            raise ContractError(f"Invalid threshold range for {metric}")
        thresholds[metric] = rule
    return thresholds


def metric_result(name: str, current: float, baseline: float, rule: dict[str, Any]) -> dict[str, Any]:
    if baseline == 0:
        raise ContractError(f"Cannot calculate relative regression for zero baseline metric: {name}")
    regression = (current - baseline) / baseline if rule["direction"] == "lower" else (baseline - current) / baseline
    if regression >= rule["failureRelative"]:
        status = "FAIL"
    elif regression >= rule["warningRelative"]:
        status = "WARNING"
    else:
        status = "PASS"
    return {
        "metric": name,
        "direction": rule["direction"],
        "baseline": baseline,
        "current": current,
        "relativeRegression": regression,
        "status": status,
    }


def markdown(result: dict[str, Any]) -> str:
    lines = [f"# Volcano Performance Comparison: {result['status']}", ""]
    if result["compatibilityErrors"]:
        lines.extend(["## Baseline Compatibility", ""])
        lines.extend(f"- {item}" for item in result["compatibilityErrors"])
        lines.append("")
    if result["directFailures"]:
        lines.extend(["## Direct Failures", ""])
        lines.extend(f"- {item}" for item in result["directFailures"])
        lines.append("")
    if result["comparisons"]:
        lines.extend(["## Metrics", "", "| Metric | Baseline | Candidate | Regression | Status |", "| --- | ---: | ---: | ---: | --- |"])
        for item in result["comparisons"]:
            lines.append(
                f"| {item['metric']} | {item['baseline']:.6g} | {item['current']:.6g} | "
                f"{item['relativeRegression'] * 100:.2f}% | {item['status']} |"
            )
        lines.append("")
    return "\n".join(lines)


def junit(result: dict[str, Any]) -> str:
    failures = result["compatibilityErrors"] + result["directFailures"]
    failed_metrics = [item for item in result["comparisons"] if item["status"] == "FAIL"]
    test_count = 1 + len(result["comparisons"])
    failure_count = (1 if failures else 0) + len(failed_metrics)
    lines = [f'<testsuite name="volcano-performance-guard" tests="{test_count}" failures="{failure_count}">']
    lines.append('  <testcase name="baseline-compatibility">')
    if failures:
        lines.append(f"    <failure message=\"{'; '.join(failures)}\"/>")
    lines.append("  </testcase>")
    for item in result["comparisons"]:
        lines.append(f'  <testcase name="{item["metric"]}">')
        if item["status"] == "FAIL":
            lines.append(f'    <failure message="relative regression {item["relativeRegression"]:.6f}"/>')
        lines.append("  </testcase>")
    lines.append("</testsuite>")
    return "\n".join(lines) + "\n"


def html_report(result: dict[str, Any]) -> str:
    status = result["status"]
    status_class = {
        "PASS": "pass",
        "WARNING": "warning",
        "FAIL": "fail",
        "BASELINE_INCOMPATIBLE": "fail",
    }.get(status, "neutral")
    issue_items = result["compatibilityErrors"] + result["directFailures"]
    issues = "".join(f"<li>{escape(item)}</li>" for item in issue_items) or "<li>None</li>"
    rows = []
    for item in result["comparisons"]:
        item_status = item["status"]
        item_class = {"PASS": "pass", "WARNING": "warning", "FAIL": "fail"}.get(item_status, "neutral")
        rows.append(
            "<tr>"
            f"<td><code>{escape(item['metric'])}</code></td>"
            f"<td>{item['baseline']:.6g}</td>"
            f"<td>{item['current']:.6g}</td>"
            f"<td>{item['relativeRegression'] * 100:.2f}%</td>"
            f'<td><span class="status {item_class}">{escape(item_status)}</span></td>'
            "</tr>"
        )
    if not rows:
        rows.append('<tr><td colspan="5" class="empty">No comparable metrics</td></tr>')
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Volcano Performance Comparison</title>
  <style>
    :root {{ color-scheme: light; font-family: Inter, "Segoe UI", Arial, sans-serif; }}
    body {{ margin: 0; color: #202124; background: #f6f7f8; }}
    main {{ width: min(1080px, calc(100% - 32px)); margin: 32px auto; }}
    header {{ display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 24px; }}
    h1 {{ margin: 0; font-size: 24px; font-weight: 650; letter-spacing: 0; }}
    h2 {{ margin: 28px 0 10px; font-size: 17px; letter-spacing: 0; }}
    .status {{ display: inline-block; padding: 4px 8px; border-radius: 4px; font-size: 12px; font-weight: 700; }}
    .pass {{ color: #176b3a; background: #e5f4ea; }}
    .warning {{ color: #765500; background: #fff1c7; }}
    .fail {{ color: #a12b2b; background: #fbe7e7; }}
    .neutral {{ color: #454a50; background: #e8eaed; }}
    .paths {{ display: grid; grid-template-columns: 110px minmax(0, 1fr); gap: 8px 12px; padding: 16px 0; border-block: 1px solid #d8dce1; }}
    .paths dt {{ font-weight: 650; }}
    .paths dd {{ margin: 0; overflow-wrap: anywhere; }}
    table {{ width: 100%; border-collapse: collapse; background: #fff; border: 1px solid #d8dce1; }}
    th, td {{ padding: 10px 12px; border-bottom: 1px solid #e5e7ea; text-align: right; }}
    th {{ color: #4c5157; background: #f1f3f4; font-size: 12px; text-transform: uppercase; }}
    th:first-child, td:first-child {{ text-align: left; }}
    tr:last-child td {{ border-bottom: 0; }}
    ul {{ margin: 0; padding-left: 20px; }}
    .empty {{ color: #686d73; text-align: center !important; }}
    @media (max-width: 700px) {{
      header {{ align-items: flex-start; flex-direction: column; }}
      main {{ width: min(100% - 20px, 1080px); margin: 18px auto; }}
      .table-wrap {{ overflow-x: auto; }}
      table {{ min-width: 700px; }}
    }}
  </style>
</head>
<body>
  <main>
    <header>
      <h1>Volcano Performance Comparison</h1>
      <span class="status {status_class}">{escape(status)}</span>
    </header>
    <dl class="paths">
      <dt>Candidate</dt><dd><code>{escape(result['candidate'])}</code></dd>
      <dt>Baseline</dt><dd><code>{escape(result['baseline'])}</code></dd>
    </dl>
    <h2>Compatibility And Direct Checks</h2>
    <ul>{issues}</ul>
    <h2>Metric Comparison</h2>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Metric</th><th>Baseline</th><th>Candidate</th><th>Regression</th><th>Status</th></tr></thead>
        <tbody>{''.join(rows)}</tbody>
      </table>
    </div>
  </main>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare candidate Volcano metrics with a stable, approved baseline")
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--thresholds", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--markdown-output", type=Path, required=True)
    parser.add_argument("--junit-output", type=Path, required=True)
    parser.add_argument("--html-output", type=Path, required=True)
    args = parser.parse_args()

    try:
        candidate = load_document(args.candidate)
        baseline = load_document(args.baseline)
        require_valid("metrics", candidate, args.candidate)
        require_valid("metrics", baseline, args.baseline)
        baseline_failures = direct_failures(baseline["metrics"])
        if baseline_failures:
            raise ContractError("Baseline is not a successful formal result: " + ", ".join(baseline_failures))
        threshold_rules = load_thresholds(args.thresholds)
        incompatible = compatibility_errors(candidate, baseline)
        failures = direct_failures(candidate["metrics"])
        comparisons: list[dict[str, Any]] = []
        if not incompatible:
            for metric, rule in threshold_rules.items():
                comparisons.append(metric_result(metric, candidate["metrics"][metric], baseline["metrics"][metric], rule))
        statuses = [item["status"] for item in comparisons]
        if incompatible:
            status = "BASELINE_INCOMPATIBLE"
        elif failures or "FAIL" in statuses:
            status = "FAIL"
        elif "WARNING" in statuses:
            status = "WARNING"
        else:
            status = "PASS"
        result = {
            "schemaVersion": "v1",
            "status": status,
            "candidate": str(args.candidate.resolve()),
            "baseline": str(args.baseline.resolve()),
            "compatibilityErrors": incompatible,
            "directFailures": failures,
            "comparisons": comparisons,
        }
        write_json(args.output, result)
        args.markdown_output.parent.mkdir(parents=True, exist_ok=True)
        args.markdown_output.write_text(markdown(result), encoding="utf-8")
        args.junit_output.parent.mkdir(parents=True, exist_ok=True)
        args.junit_output.write_text(junit(result), encoding="utf-8")
        args.html_output.parent.mkdir(parents=True, exist_ok=True)
        args.html_output.write_text(html_report(result), encoding="utf-8")
    except (ContractError, OSError, KeyError, TypeError, ValueError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    print(f"Baseline comparison {result['status']}: {args.output}")
    return 0 if result["status"] in {"PASS", "WARNING"} else 2


if __name__ == "__main__":
    sys.exit(main())
