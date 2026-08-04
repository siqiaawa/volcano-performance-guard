#!/usr/bin/env python3
"""Package external Benchmark images and the Runtime's pinned KWOK charts."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any


COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
REGISTRY_RE = re.compile(r"^(localhost|127\.0\.0\.1):[0-9]+$")


def run(command: list[str], *, capture: bool = False) -> str:
    result = subprocess.run(
        command,
        check=False,
        capture_output=capture,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() if capture else ""
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(command)} {detail}")
    return result.stdout if capture else ""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def image_inspect(image: str) -> dict[str, Any]:
    output = run(["docker", "image", "inspect", image], capture=True)
    records = json.loads(output)
    if len(records) != 1:
        raise RuntimeError(f"Expected one image record for {image}")
    return records[0]


def source_digest(record: dict[str, Any], image: str) -> str:
    repo_digests = record.get("RepoDigests") or []
    candidates = [value for value in repo_digests if "@sha256:" in value]
    if not candidates:
        raise RuntimeError(f"Pulled image has no immutable RepoDigest: {image}")
    return sorted(candidates)[0].split("@", 1)[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-dir", type=Path, required=True)
    parser.add_argument("--candidate-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--audit-image", default="")
    parser.add_argument("--tools-image", required=True)
    parser.add_argument("--expected-commit", default="")
    parser.add_argument("--registry-host", default="localhost:15001")
    parser.add_argument("--sources", type=Path, default=Path("configs/benchmark-assets.sources.json"))
    parser.add_argument("--allow-network", action="store_true")
    parser.add_argument(
        "--reuse-local-images",
        action="store_true",
        help="Use already-present source images instead of pulling them during an explicit packaging run",
    )
    parser.add_argument("--include-optional", action="store_true")
    args = parser.parse_args()

    if not args.allow_network:
        raise RuntimeError("Benchmark asset packaging requires explicit --allow-network")
    if not REGISTRY_RE.fullmatch(args.registry_host):
        raise RuntimeError("Registry target must be loopback HOST:PORT")

    runtime_dir = args.runtime_dir.resolve(strict=True)
    candidate_dir = args.candidate_dir.resolve(strict=True)
    output_dir = args.output_dir.resolve()
    sources_path = args.sources if args.sources.is_absolute() else Path.cwd() / args.sources
    sources = json.loads(sources_path.resolve(strict=True).read_text(encoding="utf-8"))

    commit = run(["git", "-C", str(candidate_dir), "rev-parse", "HEAD"], capture=True).strip()
    if not COMMIT_RE.fullmatch(commit):
        raise RuntimeError(f"Candidate HEAD is not a full commit SHA: {commit}")
    if args.expected_commit and args.expected_commit != commit:
        raise RuntimeError(f"Candidate commit mismatch: expected={args.expected_commit} actual={commit}")
    if run(["git", "-C", str(candidate_dir), "status", "--porcelain"], capture=True).strip():
        raise RuntimeError("Candidate working tree is not clean")

    audit_image = args.audit_image or f"volcanosh/kube-apiserver-audit-exporter:{commit}"
    audit_record = image_inspect(audit_image)
    labels = audit_record.get("Config", {}).get("Labels") or {}
    if labels.get("io.volcano.performance-guard.candidate.commit") != commit:
        raise RuntimeError(f"Audit exporter is not bound to candidate commit: {audit_image}")

    tools_record = image_inspect(args.tools_image)
    tools_labels = tools_record.get("Config", {}).get("Labels") or {}
    if tools_labels.get("io.volcano.performance-guard.candidate.commit") != commit:
        raise RuntimeError(f"Performance tools image is not bound to candidate commit: {args.tools_image}")

    output_dir.mkdir(parents=True, exist_ok=True)
    charts_dir = output_dir / "charts"
    charts_dir.mkdir(parents=True, exist_ok=True)
    image_entries: list[dict[str, Any]] = []
    target_images: list[str] = []
    omitted_optional_images: list[str] = []

    image_entries.append(
        {
            "sourceImage": args.tools_image,
            "resolvedDigest": None,
            "registryImage": args.tools_image,
            "imageId": tools_record["Id"],
            "architecture": tools_record.get("Architecture"),
            "os": tools_record.get("Os"),
            "candidateCommit": commit,
            "role": "performance-guard-tools",
        }
    )
    target_images.append(args.tools_image)

    for source in sources["images"]:
        source_image = source["source"]
        if not source.get("required", True) and not args.include_optional:
            omitted_optional_images.append(source_image)
            continue
        if args.reuse_local_images:
            if not image_inspect(source_image):
                raise RuntimeError(f"Local source image is missing: {source_image}")
        else:
            run(["docker", "pull", "--platform", sources["platform"], source_image])
        record = image_inspect(source_image)
        digest = source_digest(record, source_image)
        target_tag = f"{source['targetTagPrefix']}-{commit[:12]}"
        target_image = f"{args.registry_host}/{source['targetRepository']}:{target_tag}"
        run(["docker", "tag", source_image, target_image])
        image_entries.append(
            {
                "sourceImage": source_image,
                "resolvedDigest": digest,
                "registryImage": target_image,
                "imageId": record["Id"],
                "architecture": record.get("Architecture"),
                "os": record.get("Os"),
                "role": "benchmark",
            }
        )
        target_images.append(target_image)

    audit_target = f"{args.registry_host}/volcanosh/kube-apiserver-audit-exporter:{commit}"
    run(["docker", "tag", audit_image, audit_target])
    image_entries.append(
        {
            "sourceImage": audit_image,
            "resolvedDigest": None,
            "registryImage": audit_target,
            "imageId": audit_record["Id"],
            "architecture": audit_record.get("Architecture"),
            "os": audit_record.get("Os"),
            "candidateCommit": commit,
            "role": "audit-exporter",
        }
    )
    target_images.append(audit_target)

    for relative in sources["chartsFromRuntime"]:
        source_chart = runtime_dir / relative
        if not source_chart.is_file():
            raise RuntimeError(f"Runtime chart is missing: {source_chart}")
        shutil.copy2(source_chart, charts_dir / source_chart.name)

    archive = output_dir / "benchmark-images.tar"
    archive.unlink(missing_ok=True)
    run(["docker", "save", "-o", str(archive), *target_images])
    manifest: dict[str, Any] = {
        "schemaVersion": "v1",
        "candidate": {"commit": commit},
        "platform": sources["platform"],
        "registryHost": args.registry_host,
        "images": image_entries,
        "omittedOptionalImages": omitted_optional_images,
        "charts": [
            {
                "name": chart.name,
                "sha256": sha256(chart),
            }
            for chart in sorted(charts_dir.iterdir())
        ],
        "archive": {"name": archive.name, "sha256": sha256(archive)},
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (output_dir / "candidate-commit.txt").write_text(commit + "\n", encoding="utf-8")

    checksummed = [archive, output_dir / "manifest.json"] + sorted(charts_dir.iterdir())
    (output_dir / "SHA256SUMS").write_text(
        "".join(f"{sha256(path)}  {path.relative_to(output_dir).as_posix()}\n" for path in checksummed),
        encoding="utf-8",
    )
    print(f"Benchmark assets written to {output_dir}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        raise SystemExit(1)
