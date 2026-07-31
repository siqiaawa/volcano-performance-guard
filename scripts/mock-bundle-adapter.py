#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shlex
import sys
from pathlib import Path
from typing import Any

from lib.contracts import ContractError, ROOT, load_document, require_valid, write_environment_env, write_json


MARKER = ".mock-environment-adapter.json"


def ensure_project_local(path: Path) -> Path:
    resolved = path.resolve()
    mock_work_root = (ROOT / ".work").resolve()
    try:
        resolved.relative_to(mock_work_root)
    except ValueError as exc:
        raise ContractError(f"Mock adapter output paths must stay inside {mock_work_root}: {resolved}") from exc
    return resolved


def environment_path_from_env_file(path: Path) -> Path:
    values: dict[str, str] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        tokens = shlex.split(stripped, posix=True)
        if len(tokens) != 2 or tokens[0] != "export" or "=" not in tokens[1]:
            raise ContractError(f"Unsupported generated env syntax at {path}:{line_number}")
        key, value = tokens[1].split("=", 1)
        values[key] = value
    if "ENVIRONMENT_JSON" not in values:
        raise ContractError(f"ENVIRONMENT_JSON is missing from {path}")
    return Path(values["ENVIRONMENT_JSON"])


def resolve_environment_argument(args: argparse.Namespace) -> Path:
    path = args.environment or args.env
    if path is None:
        raise ContractError("Either --environment or --env is required")
    return environment_path_from_env_file(path) if path.suffix == ".env" else path


def prepare(args: argparse.Namespace) -> int:
    bundle = args.bundle.resolve()
    source = bundle / "environment.json" if bundle.is_dir() else bundle
    workdir = ensure_project_local(args.workdir)
    output_env = ensure_project_local(args.output_env)
    if output_env.parent != workdir:
        raise ContractError("--output-env must be directly under --workdir for the mock adapter")
    environment = load_document(source)
    require_valid("environment", environment, source)
    if environment["adapter"]["mode"] != "mock":
        raise ContractError("Mock adapter fixture must declare adapter.mode=mock")

    environment_json = workdir / "environment.json"
    workdir.mkdir(parents=True, exist_ok=True)
    write_json(environment_json, environment)
    write_environment_env(output_env, environment, environment_json)
    write_json(
        workdir / MARKER,
        {"schemaVersion": "v1", "adapter": "mock-environment", "state": "prepared"},
    )
    print(f"Mock environment prepared: {environment_json}")
    print(f"Shell compatibility file: {output_env}")
    return 0


def inspect_environment(args: argparse.Namespace) -> int:
    path = resolve_environment_argument(args)
    environment = load_document(path)
    require_valid("environment", environment, path)
    summary: dict[str, Any] = {
        "schemaVersion": environment["schemaVersion"],
        "adapter": environment["adapter"],
        "bundle": environment["bundle"],
        "cluster": {
            "name": environment["cluster"]["name"],
            "kubernetesVersion": environment["cluster"]["kubernetesVersion"],
            "architecture": environment["cluster"]["architecture"],
        },
        "stableVolcano": {
            "version": environment["stableVolcano"]["version"],
            "namespace": environment["stableVolcano"]["namespace"],
            "installType": environment["stableVolcano"]["installType"],
            "components": sorted(environment["stableVolcano"]["components"]),
        },
        "capabilities": environment["capabilities"],
    }
    json.dump(summary, sys.stdout, ensure_ascii=False, indent=2)
    print()
    return 0


def export_env(args: argparse.Namespace) -> int:
    path = args.environment
    environment = load_document(path)
    require_valid("environment", environment, path)
    output = ensure_project_local(args.output_env)
    write_environment_env(output, environment, path)
    print(f"Generated {output}")
    return 0


def cleanup(args: argparse.Namespace) -> int:
    environment_path = resolve_environment_argument(args).resolve()
    workdir = ensure_project_local(environment_path.parent)
    environment = load_document(environment_path)
    require_valid("environment", environment, environment_path)
    if environment["adapter"]["mode"] != "mock":
        raise ContractError("Mock cleanup requires adapter.mode=mock")
    marker = workdir / MARKER
    if not marker.is_file():
        raise ContractError(f"Refusing mock cleanup without marker: {marker}")
    state = load_document(marker)
    if state.get("adapter") != "mock-environment":
        raise ContractError(f"Unexpected mock adapter marker: {marker}")
    state["state"] = "cleaned"
    write_json(marker, state)
    print(f"Mock environment marked clean: {workdir}; environment evidence retained")
    return 0


def add_environment_arguments(parser: argparse.ArgumentParser) -> None:
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--environment", type=Path, help="Canonical environment.json")
    group.add_argument("--env", type=Path, help="Generated environment.env")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Side-effect-free mock implementation of the environment adapter")
    commands = root.add_subparsers(dest="command", required=True)

    command = commands.add_parser("prepare", help="Create validated mock environment outputs")
    command.add_argument("--bundle", type=Path, required=True, help="Fixture directory or environment JSON")
    command.add_argument("--workdir", type=Path, required=True)
    command.add_argument("--output-env", type=Path, required=True)
    command.set_defaults(handler=prepare)

    command = commands.add_parser("inspect", help="Inspect a validated mock environment")
    add_environment_arguments(command)
    command.set_defaults(handler=inspect_environment)

    command = commands.add_parser("export-env", help="Generate environment.env from canonical JSON")
    command.add_argument("--environment", type=Path, required=True)
    command.add_argument("--output-env", type=Path, required=True)
    command.set_defaults(handler=export_env)

    command = commands.add_parser("cleanup", help="Mark the mock environment as cleaned")
    add_environment_arguments(command)
    command.set_defaults(handler=cleanup)
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        return args.handler(args)
    except (ContractError, OSError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
