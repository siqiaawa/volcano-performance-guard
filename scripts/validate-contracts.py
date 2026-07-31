#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from lib.contracts import ContractError, SCHEMA_FILES, load_document, require_valid


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate versioned Volcano performance guard contracts")
    parser.add_argument("kind", choices=sorted(SCHEMA_FILES))
    parser.add_argument("paths", type=Path, nargs="+")
    args = parser.parse_args()

    failed = False
    for path in args.paths:
        try:
            document = load_document(path)
            require_valid(args.kind, document, path)
        except ContractError as exc:
            print(f"[ERROR] {exc}", file=sys.stderr)
            failed = True
        else:
            print(f"[OK] {args.kind}: {path}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
