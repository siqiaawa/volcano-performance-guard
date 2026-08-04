#!/usr/bin/env python3
"""Verify and import a packaged Benchmark asset set into the loopback registry."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
REGISTRY_RE = re.compile(r"^(localhost|127\.0\.0\.1):[0-9]+$")


def run(command: list[str], *, capture: bool = False) -> str:
    result = subprocess.run(command, check=False, capture_output=capture, text=True)
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


def inspect_id(image: str) -> str:
    output = run(["docker", "image", "inspect", "--format", "{{.Id}}", image], capture=True)
    return output.strip()


def environment_key(image: str) -> str:
    repository_and_tag = image.split("/", 1)[1]
    return re.sub(r"[^A-Z0-9_]", "_", repository_and_tag.upper())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset-dir", type=Path, required=True)
    parser.add_argument("--expected-commit", default="")
    parser.add_argument("--registry-host", default="localhost:15001")
    parser.add_argument(
        "--skip-registry-probe",
        action="store_true",
        help="Skip the client-side localhost probe; Docker push still verifies registry availability",
    )
    parser.add_argument("--skip-load", action="store_true", help="Use images already loaded from the verified archive")
    args = parser.parse_args()
    if not REGISTRY_RE.fullmatch(args.registry_host):
        raise RuntimeError("Registry target must be loopback HOST:PORT")

    asset_dir = args.asset_dir.resolve(strict=True)
    manifest = json.loads((asset_dir / "manifest.json").read_text(encoding="utf-8"))
    commit = manifest["candidate"]["commit"]
    if not COMMIT_RE.fullmatch(commit):
        raise RuntimeError(f"Invalid candidate commit in asset: {commit}")
    if args.expected_commit and args.expected_commit != commit:
        raise RuntimeError(f"Benchmark asset commit mismatch: expected={args.expected_commit} asset={commit}")
    checksums = asset_dir / "SHA256SUMS"
    for line in checksums.read_text(encoding="utf-8").splitlines():
        expected, relative = line.split("  ", 1)
        path = asset_dir / relative
        actual = sha256(path)
        if actual != expected:
            raise RuntimeError(f"SHA-256 mismatch: {relative} expected={expected} actual={actual}")

    archive = asset_dir / manifest["archive"]["name"]
    if not args.skip_load:
        run(["docker", "load", "-i", str(archive)])
    if not args.skip_registry_probe and subprocess.run(
        ["curl", "-fsS", f"http://{args.registry_host}/v2/"], check=False
    ).returncode != 0:
        raise RuntimeError(f"Loopback registry is unavailable: {args.registry_host}")

    imported: list[dict[str, Any]] = []
    for entry in manifest["images"]:
        asset_image = entry["registryImage"]
        image_path = asset_image.split("/", 1)[1]
        image = f"{args.registry_host}/{image_path}"
        try:
            actual_id = inspect_id(asset_image)
        except RuntimeError:
            actual_id = inspect_id(image)
        if actual_id != entry["imageId"]:
            raise RuntimeError(f"Loaded image ID mismatch: {asset_image} expected={entry['imageId']} actual={actual_id}")
        if asset_image != image:
            run(["docker", "tag", asset_image, image])
        output = run(["docker", "push", image], capture=True)
        digest_match = re.search(r"digest:\s+(sha256:[0-9a-f]{64})", output)
        if not digest_match:
            raise RuntimeError(f"Unable to capture registry digest: {image}")
        imported.append({**entry, "registryImage": image, "registryDigest": digest_match.group(1)})

    result = {
        "schemaVersion": "v1",
        "candidate": {"commit": commit},
        "registryHost": args.registry_host,
        "images": imported,
        "charts": manifest["charts"],
    }
    (asset_dir / "imported-manifest.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    with (asset_dir / "registry-images.env").open("w", encoding="utf-8") as stream:
        for entry in imported:
            key = environment_key(entry["registryImage"])
            stream.write(f"BENCHMARK_IMAGE_{key}={entry['registryImage']}\n")
            stream.write(f"BENCHMARK_DIGEST_{key}={entry['registryDigest']}\n")
    print(f"Imported {len(imported)} Benchmark images into {args.registry_host}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, json.JSONDecodeError, ValueError) as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        raise SystemExit(1)
