#!/usr/bin/env python3
"""Pin community monitoring manifests to the imported immutable asset tags."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import yaml


def image_path(value: str) -> str:
    return value.removeprefix("localhost:15000/")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--audit-manifest", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--audit-output", type=Path, required=True)
    args = parser.parse_args()

    asset = json.loads(args.assets.read_text(encoding="utf-8"))
    replacements: dict[str, str] = {}
    for record in asset.get("images", []):
        source = record.get("sourceImage")
        target = record.get("registryImage")
        if isinstance(source, str) and isinstance(target, str):
            replacements[source] = image_path(target)
            if ":" not in source.rsplit("/", 1)[-1]:
                replacements[source + ":latest"] = image_path(target)
            if "kube-apiserver-audit-exporter" in source:
                replacements["volcanosh/kube-apiserver-audit-exporter:dev"] = image_path(target)
    if not replacements:
        parser.error("Asset manifest contains no image mappings")

    def pin(value: Any) -> Any:
        if isinstance(value, str):
            return replacements.get(value, value)
        if isinstance(value, list):
            return [pin(item) for item in value]
        if isinstance(value, dict):
            return {key: pin(item) for key, item in value.items()}
        return value

    def render(source: Path, output: Path) -> None:
        docs = [pin(document) for document in yaml.safe_load_all(source.read_text(encoding="utf-8"))]
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(
            "---\n".join(yaml.safe_dump(doc, sort_keys=False) for doc in docs if doc is not None),
            encoding="utf-8",
        )

    render(args.manifest, args.output)
    render(args.audit_manifest, args.audit_output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
