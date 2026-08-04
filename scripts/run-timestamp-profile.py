#!/usr/bin/env python3
"""Execute warmup/formal timestamp iterations and aggregate formal results."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from lib.contracts import ContractError, require_valid  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Run all iterations in an offline Pod timestamp performance profile")
    parser.add_argument("--runtime-dir", type=Path, required=True)
    parser.add_argument("--candidate-dir", type=Path, required=True)
    parser.add_argument("--runner-image", required=True)
    parser.add_argument("--state-dir", type=Path, required=True)
    parser.add_argument("--cluster-name", required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--report-dir", type=Path, required=True)
    parser.add_argument("--subject-type", choices=("stable", "candidate"), default="candidate")
    parser.add_argument("--subject-version")
    args = parser.parse_args()

    try:
        profile = yaml.safe_load(args.profile.read_text(encoding="utf-8"))
        require_valid("profile", profile, args.profile)
    except (OSError, yaml.YAMLError, ContractError) as exc:
        print(f"[ERROR] Cannot load profile: {exc}", file=sys.stderr)
        return 1

    report_dir = args.report_dir.resolve()
    runs_dir = report_dir / "runs"
    runs_dir.mkdir(parents=True, exist_ok=True)
    benchmark = ROOT / "adapters" / "runtime" / "run-timestamp-benchmark.py"
    formal_outputs: list[Path] = []
    total = profile["execution"]["warmupRuns"] + profile["execution"]["formalRuns"]
    for iteration in range(1, total + 1):
        warmup = iteration <= profile["execution"]["warmupRuns"]
        output = runs_dir / f"iteration-{iteration}.json"
        command = [
            sys.executable, str(benchmark),
            "--runtime-dir", str(args.runtime_dir),
            "--candidate-dir", str(args.candidate_dir),
            "--runner-image", args.runner_image,
            "--state-dir", str(args.state_dir),
            "--cluster-name", args.cluster_name,
            "--profile", str(args.profile),
            "--run-id", f"{args.run_id}-{iteration}",
            "--iteration", str(iteration),
            "--output", str(output),
            "--subject-type", args.subject_type,
        ]
        if args.subject_version:
            command.extend(["--subject-version", args.subject_version])
        if warmup:
            command.append("--warmup")
        result = subprocess.run(command, check=False)
        if result.returncode != 0:
            return result.returncode
        if not warmup:
            formal_outputs.append(output)

    aggregate = ROOT / "scripts" / "aggregate-metrics.py"
    command = [sys.executable, str(aggregate)]
    for output in formal_outputs:
        command.extend(["--input", str(output)])
    command.extend([
        "--expected-runs", str(profile["execution"]["formalRuns"]),
        "--run-id", args.run_id,
        "--output", str(report_dir / "metrics.json"),
    ])
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
