#!/usr/bin/env python3
"""Inventory offline dependencies referenced by a Volcano benchmark checkout."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


IMAGE_PATTERN = re.compile(r'^\s*(?:-\s*)?image\s*:\s*["\']?([^\s"\'#]+)', re.MULTILINE)
FROM_IMAGE_PATTERN = re.compile(
    r'^\s*FROM\s+(?:--platform=[^\s]+\s+)?([^\s]+)', re.MULTILINE
)
URL_PATTERN = re.compile(r'https://[^\s"\'`]+')
AUDIT_IMAGE_PATTERN = re.compile(r'AUDIT_EXPORTER_IMAGE\s*\?[:]?=\s*([^\s#]+)')
KWOK_VERSION_PATTERN = re.compile(r'KWOK_VERSION=.*?\$\{KWOK_VERSION:-([^}]+)\}')


def git_commit(directory: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(directory), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def bundle_images(bundle_dir: Path) -> set[str]:
    manifest = bundle_dir / "manifest" / "images-required.txt"
    return {
        line.strip()
        for line in manifest.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def docker_image_available(image: str, docker_bin: str) -> bool:
    try:
        result = subprocess.run(
            [docker_bin, "image", "inspect", image],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0


def collect_required_images(candidate_dir: Path) -> tuple[dict[str, list[str]], list[str]]:
    sources = [candidate_dir / "benchmark", candidate_dir / "installer" / "volcano-monitoring.yaml"]
    images: dict[str, list[str]] = {}
    urls: set[str] = set()
    for source in sources:
        paths = [source] if source.is_file() else sorted(source.rglob("*"))
        for path in paths:
            if not path.is_file() or path.suffix not in {".yaml", ".yml", ".sh", ""}:
                continue
            try:
                content = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            relative = path.relative_to(candidate_dir).as_posix()
            for image in IMAGE_PATTERN.findall(content):
                if "{{" not in image and "}}" not in image:
                    images.setdefault(image, []).append(relative)
            for image in FROM_IMAGE_PATTERN.findall(content):
                if "{{" not in image and "}}" not in image:
                    images.setdefault(image, []).append(relative + " (Dockerfile FROM)")
            urls.update(URL_PATTERN.findall(content))
            if path.name == "Makefile":
                for image in AUDIT_IMAGE_PATTERN.findall(content):
                    images.setdefault(image, []).append(relative + " (default variable)")
            if path.name == "common.sh":
                match = KWOK_VERSION_PATTERN.search(content)
                if match:
                    image = f"registry.k8s.io/kwok/kwok:{match.group(1)}"
                    images.setdefault(image, []).append(relative + " (KWOK default)")
    return images, sorted(urls)


def image_record(image: str, references: list[str], provided: set[str], docker_bin: str) -> dict[str, Any]:
    in_bundle = image in provided
    local = docker_image_available(image, docker_bin)
    if in_bundle:
        status = "provided-by-bundle"
    elif local:
        status = "available-on-host-unverified"
    else:
        status = "missing"
    return {
        "image": image,
        "references": sorted(set(references)),
        "bundleProvided": in_bundle,
        "hostRuntimeAvailable": local,
        "status": status,
        "pinned": "@sha256:" in image
        or (":" in image.rsplit("/", 1)[-1] and not image.endswith(":latest")),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Scan a candidate Volcano benchmark for offline image and URL dependencies without pulling anything."
    )
    parser.add_argument("--candidate-dir", type=Path, required=True)
    parser.add_argument("--bundle-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--docker-bin", default="docker")
    args = parser.parse_args()

    try:
        candidate_dir = args.candidate_dir.resolve(strict=True)
        bundle_dir = args.bundle_dir.resolve(strict=True)
        if not (candidate_dir / "benchmark").is_dir():
            raise ValueError(f"Candidate checkout has no benchmark directory: {candidate_dir}")
        if not (bundle_dir / "manifest" / "images-required.txt").is_file():
            raise ValueError(f"Bundle has no image manifest: {bundle_dir}")
        requirements, external_urls = collect_required_images(candidate_dir)
        provided = bundle_images(bundle_dir)
        images = [image_record(image, refs, provided, args.docker_bin) for image, refs in sorted(requirements.items())]
        result = {
            "schemaVersion": "v1",
            "candidate": {"commit": git_commit(candidate_dir)},
            "bundle": {"requiredImageManifest": str((bundle_dir / "manifest" / "images-required.txt").resolve())},
            "images": images,
            "performanceToolDelta": [
                record["image"] for record in images if not record["bundleProvided"]
            ],
            "externalManifestUrls": external_urls,
            "offlineReady": not any(record["status"] == "missing" for record in images)
            and not external_urls,
        }
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Scanned {len(images)} required images: {args.output}")
    return 0 if result["offlineReady"] else 2


if __name__ == "__main__":
    sys.exit(main())
