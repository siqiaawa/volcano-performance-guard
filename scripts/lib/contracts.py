#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import shlex
from pathlib import Path
from typing import Any

import yaml
from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[2]
CONTRACT_DIR = ROOT / "contracts"
SCHEMA_FILES = {
    "environment": "environment.schema.json",
    "profile": "profile.schema.json",
    "candidate-release": "candidate-release.schema.json",
    "run-metrics": "run-metrics.schema.json",
    "metrics": "metrics.schema.json",
}


class ContractError(ValueError):
    pass


def load_document(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as stream:
            if path.suffix.lower() == ".json":
                value = json.load(stream)
            else:
                value = yaml.safe_load(stream)
    except (OSError, json.JSONDecodeError, yaml.YAMLError) as exc:
        raise ContractError(f"Cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError(f"Contract document must be an object: {path}")
    return value


def load_schema(kind: str) -> dict[str, Any]:
    try:
        schema_file = SCHEMA_FILES[kind]
    except KeyError as exc:
        raise ContractError(f"Unknown contract type: {kind}") from exc
    schema = load_document(CONTRACT_DIR / schema_file)
    Draft202012Validator.check_schema(schema)
    return schema


def json_path(parts: list[Any]) -> str:
    value = "$"
    for part in parts:
        value += f"[{part}]" if isinstance(part, int) else f".{part}"
    return value


def semantic_errors(kind: str, document: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if kind == "profile":
        workload = document["workload"]
        if workload["type"] == "gang" and workload["minAvailable"] > workload["replicasPerJob"]:
            errors.append("$.workload.minAvailable cannot exceed replicasPerJob")
    elif kind == "candidate-release":
        candidate = document["candidate"]
        commit = candidate["commit"]
        discovered = set(candidate["componentDiscovery"]["components"])
        declared = set(candidate["components"])
        if discovered != declared:
            errors.append(
                "$.candidate.componentDiscovery.components must exactly match $.candidate.components"
            )

        for name, component in candidate["components"].items():
            if component["sourceCommit"] != commit:
                errors.append(f"$.candidate.components.{name}.sourceCommit must match $.candidate.commit")

        materials = candidate["deploymentMaterials"]
        if materials["sourceCommit"] != commit:
            errors.append("$.candidate.deploymentMaterials.sourceCommit must match $.candidate.commit")
        artifact_groups = {
            "installation.artifacts": materials["installation"]["artifacts"],
            **{
                name: materials[name]
                for name in ("crds", "config", "rbac", "workloads", "serviceAccounts", "services")
            },
        }
        for group_name, artifacts in artifact_groups.items():
            for index, artifact in enumerate(artifacts):
                if artifact["sourceCommit"] != commit:
                    errors.append(
                        f"$.candidate.deploymentMaterials.{group_name}[{index}].sourceCommit "
                        "must match $.candidate.commit"
                    )

        strategy = candidate["deployment"]["strategy"]
        install_type = materials["installation"]["type"]
        if strategy == "helm-upgrade" and install_type != "helm-chart":
            errors.append("$.candidate.deployment.strategy=helm-upgrade requires a Helm chart")
        if strategy == "manifest-apply" and install_type != "manifests":
            errors.append("$.candidate.deployment.strategy=manifest-apply requires manifests")
    elif kind in {"run-metrics", "metrics"}:
        metrics = document["metrics"]
        p50 = metrics["pod_scheduling_latency_p50_ms"]
        p90 = metrics["pod_scheduling_latency_p90_ms"]
        p99 = metrics["pod_scheduling_latency_p99_ms"]
        if not p50 <= p90 <= p99:
            errors.append("$.metrics scheduling latency must satisfy p50 <= p90 <= p99")
        if metrics["scheduled_pods"] > metrics["expected_pods"]:
            errors.append("$.metrics.scheduled_pods cannot exceed expected_pods")
    return errors


def validation_errors(kind: str, document: dict[str, Any]) -> list[str]:
    validator = Draft202012Validator(load_schema(kind), format_checker=FormatChecker())
    schema_errors = sorted(validator.iter_errors(document), key=lambda item: (list(item.absolute_path), item.message))
    errors = [f"{json_path(list(error.absolute_path))}: {error.message}" for error in schema_errors]
    if not errors:
        errors.extend(semantic_errors(kind, document))
    return errors


def require_valid(kind: str, document: dict[str, Any], source: Path | str) -> None:
    errors = validation_errors(kind, document)
    if errors:
        detail = "\n".join(f"  - {error}" for error in errors)
        raise ContractError(f"Invalid {kind} contract {source}:\n{detail}")


def fingerprint(document: dict[str, Any]) -> str:
    payload = json.dumps(document, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode("utf-8")
    return f"sha256:{hashlib.sha256(payload).hexdigest()}"


def write_json(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(document, stream, ensure_ascii=False, indent=2)
        stream.write("\n")


def environment_exports(environment: dict[str, Any], environment_path: Path) -> dict[str, str]:
    cluster = environment["cluster"]
    runtime = cluster["runtime"]
    stable_volcano = environment["stableVolcano"]
    bundle = environment["bundle"]
    registry = environment["registry"]
    return {
        "ENVIRONMENT_JSON": str(environment_path.resolve()),
        "KUBECONFIG": cluster["kubeconfig"] or "",
        "CLUSTER_NAME": cluster["name"],
        "CLUSTER_PROVIDER": cluster["provider"] or "",
        "BUNDLE_NAME": bundle["name"],
        "BUNDLE_VERSION": bundle["version"] or "",
        "BUNDLE_FINGERPRINT": bundle["fingerprint"],
        "BUNDLE_ARCHIVE_SHA256": bundle["archiveSha256"] or "",
        "KUBERNETES_VERSION": cluster["kubernetesVersion"] or "",
        "CONTAINER_RUNTIME": runtime["name"] or "",
        "CONTAINER_RUNTIME_VERSION": runtime["version"] or "",
        "NODE_ARCH": cluster["architecture"],
        "INTERNAL_REGISTRY": registry["endpoint"] or "",
        "STABLE_VOLCANO_VERSION": stable_volcano["version"] or "",
        "STABLE_VOLCANO_NAMESPACE": stable_volcano["namespace"] or "",
        "STABLE_VOLCANO_INSTALL_TYPE": stable_volcano["installType"],
        "STABLE_VOLCANO_RELEASE_NAME": stable_volcano["releaseName"] or "",
    }


def write_environment_env(output: Path, environment: dict[str, Any], environment_path: Path) -> None:
    exports = environment_exports(environment, environment_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write("# Generated from a validated environment.json; do not edit.\n")
        for key, value in exports.items():
            stream.write(f"export {key}={shlex.quote(value)}\n")
