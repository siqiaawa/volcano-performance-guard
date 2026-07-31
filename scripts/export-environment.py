#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from lib.contracts import ContractError, load_document, require_valid, write_environment_env


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a shell-compatible environment.env from validated JSON")
    parser.add_argument("--input", type=Path, required=True, help="Canonical environment.json")
    parser.add_argument("--output", type=Path, required=True, help="Generated environment.env")
    args = parser.parse_args()
    try:
        environment = load_document(args.input)
        require_valid("environment", environment, args.input)
        write_environment_env(args.output, environment, args.input)
    except ContractError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    print(f"Generated {args.output} from {args.input}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
