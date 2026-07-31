#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from lib.contracts import ContractError, fingerprint, load_document, require_valid, write_json


def build_plan(
    environment: dict[str, Any],
    profile: dict[str, Any],
    candidate: dict[str, Any] | None,
    run_id: str,
) -> dict[str, Any]:
    issues: list[str] = []
    capabilities = environment["capabilities"]
    if not capabilities["cleanup"]:
        issues.append("environment does not declare benchmark cleanup capability")
    if candidate and not capabilities["deployCandidateRelease"]:
        issues.append("environment does not declare candidate release deployment capability")
    if candidate and not (capabilities["restoreStableRelease"] or capabilities["destroyCluster"]):
        issues.append("environment cannot restore the stable release or destroy the test cluster")

    candidate_data = candidate["candidate"] if candidate else None
    if candidate_data:
        strategy = candidate_data["deployment"]["strategy"]
        if strategy == "recreate-cluster" and not capabilities["destroyCluster"]:
            issues.append("candidate requests cluster recreation but the environment cannot destroy the cluster")
        if strategy == "image-only":
            expected_fingerprint = candidate_data["deployment"]["imageOnlyCompatibility"][
                "againstEnvironmentFingerprint"
            ]
            if expected_fingerprint != fingerprint(environment):
                issues.append("image-only compatibility evidence was collected for a different environment")

    steps: list[dict[str, Any]] = [
        {"id": "inspect-environment", "action": "inspect-environment", "mutatesEnvironment": False},
        {"id": "inspect-stable-volcano", "action": "inspect-stable-release", "mutatesEnvironment": False},
        {
            "id": "verify-offline-inputs",
            "action": "verify-local-artifacts",
            "mutatesEnvironment": False,
            "parameters": {
                "publicNetworkAllowed": False,
                "requiredSources": [
                    "base-environment-bundle",
                    "candidate-source",
                    "performance-tools-bundle",
                    "baseline-data",
                ],
            },
        },
    ]
    if candidate_data:
        candidate_parameters = {
            "version": candidate_data["version"],
            "commit": candidate_data["commit"],
            "components": sorted(candidate_data["components"]),
            "strategy": candidate_data["deployment"]["strategy"],
            "networkAccess": "internal-only",
            "buildBaseSource": "base-environment-bundle-or-internal-registry",
        }
        steps.extend(
            [
                {
                    "id": "build-candidate-images",
                    "action": "build-candidate-images-from-source",
                    "mutatesEnvironment": False,
                    "parameters": candidate_parameters,
                },
                {
                    "id": "validate-candidate-provenance",
                    "action": "validate-candidate-release-provenance",
                    "mutatesEnvironment": False,
                    "parameters": {"commit": candidate_data["commit"]},
                },
                {
                    "id": "verify-candidate-artifact-set",
                    "action": "verify-candidate-deployment-materials",
                    "mutatesEnvironment": False,
                },
                {
                    "id": "select-deployment-strategy",
                    "action": "select-candidate-deployment-strategy",
                    "mutatesEnvironment": False,
                    "parameters": {"requested": candidate_data["deployment"]["strategy"]},
                },
                {
                    "id": "deploy-candidate-release",
                    "action": "deploy-candidate-release",
                    "mutatesEnvironment": True,
                    "parameters": candidate_parameters,
                },
                {
                    "id": "verify-candidate-deployment",
                    "action": "verify-candidate-release",
                    "mutatesEnvironment": False,
                },
            ]
        )
    steps.extend(
        [
            {
                "id": "install-performance-tools",
                "action": "install-performance-tools",
                "mutatesEnvironment": True,
                "parameters": {
                    "source": "offline-performance-tools-bundle",
                    "publicRegistryFallback": False,
                },
            },
            {
                "id": "prepare-benchmark-nodes",
                "action": "prepare-kwok",
                "mutatesEnvironment": True,
                "parameters": {"nodes": profile["cluster"]["kwokNodes"]},
            },
        ]
    )
    for iteration in range(1, profile["execution"]["warmupRuns"] + 1):
        steps.append(
            {
                "id": f"warmup-{iteration}",
                "action": "benchmark-run",
                "mutatesEnvironment": True,
                "parameters": {"iteration": iteration, "warmup": True},
            }
        )
    for iteration in range(1, profile["execution"]["formalRuns"] + 1):
        steps.append(
            {
                "id": f"formal-{iteration}",
                "action": "benchmark-run",
                "mutatesEnvironment": True,
                "parameters": {"iteration": iteration, "warmup": False},
            }
        )
    steps.extend(
        [
            {"id": "aggregate", "action": "aggregate-metrics", "mutatesEnvironment": False},
            {"id": "compare-baseline", "action": "compare-product-baseline", "mutatesEnvironment": False},
            {"id": "report", "action": "generate-reports", "mutatesEnvironment": False},
            {"id": "diagnostics", "action": "collect-diagnostics", "mutatesEnvironment": False},
            {"id": "cleanup-benchmark", "action": "cleanup-benchmark", "mutatesEnvironment": True},
        ]
    )
    if candidate_data:
        if capabilities["restoreStableRelease"]:
            steps.append(
                {
                    "id": "restore-stable-volcano",
                    "action": "restore-stable-release",
                    "mutatesEnvironment": True,
                }
            )
        elif capabilities["destroyCluster"]:
            steps.append(
                {
                    "id": "destroy-test-cluster",
                    "action": "destroy-cluster",
                    "mutatesEnvironment": True,
                }
            )

    return {
        "schemaVersion": "v1",
        "mode": "dry-run",
        "executionZone": "internal",
        "networkPolicy": {
            "publicRegistryAccess": False,
            "publicDownloadFallback": False,
            "allowedArtifactSources": ["local-bundle", "internal-registry", "checked-out-source"],
        },
        "runId": run_id,
        "status": "blocked" if issues else "ready",
        "issues": issues,
        "inputs": {
            "environmentFingerprint": fingerprint(environment),
            "profileHash": fingerprint(profile),
            "candidateReleaseHash": fingerprint(candidate) if candidate else None,
        },
        "profile": {
            "name": profile["name"],
            "workload": profile["workload"],
            "timeout": profile["execution"]["timeout"],
        },
        "steps": steps,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Render a side-effect-free Volcano benchmark execution plan")
    parser.add_argument("--environment", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        environment = load_document(args.environment)
        profile = load_document(args.profile)
        candidate = load_document(args.candidate) if args.candidate else None
        require_valid("environment", environment, args.environment)
        require_valid("profile", profile, args.profile)
        if candidate:
            require_valid("candidate-release", candidate, args.candidate)
        plan = build_plan(environment, profile, candidate, args.run_id)
    except ContractError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    if args.output:
        write_json(args.output, plan)
        print(f"Rendered dry-run plan: {args.output}")
    else:
        json.dump(plan, sys.stdout, ensure_ascii=False, indent=2)
        print()
    return 2 if plan["status"] == "blocked" else 0


if __name__ == "__main__":
    sys.exit(main())
