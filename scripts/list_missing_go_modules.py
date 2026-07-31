#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def decode_stream(text: str) -> list[dict[str, object]]:
    decoder = json.JSONDecoder()
    values: list[dict[str, object]] = []
    offset = 0
    while offset < len(text):
        while offset < len(text) and text[offset].isspace():
            offset += 1
        if offset == len(text):
            break
        value, offset = decoder.raw_decode(text, offset)
        if not isinstance(value, dict):
            raise ValueError("go mod download stream contains a non-object value")
        values.append(value)
    return values


def missing_references(values: list[dict[str, object]]) -> list[str]:
    missing: set[str] = set()
    for value in values:
        if "Error" not in value:
            continue
        path = value.get("Path")
        version = value.get("Version")
        if not isinstance(path, str) or not isinstance(version, str):
            raise ValueError("failed module entry is missing Path or Version")
        missing.add(f"{path}@{version}")
    return sorted(missing)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="List failed path@version entries from go mod download -json output."
    )
    parser.add_argument("input", type=Path)
    args = parser.parse_args()

    for reference in missing_references(decode_stream(args.input.read_text(encoding="utf-8"))):
        print(reference)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
