#!/usr/bin/env python3
"""Print Prometheus server time without jq."""
from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request


def main() -> int:
    endpoint = sys.argv[1].rstrip("/") + "/api/v1/query?" + urllib.parse.urlencode({"query": "time()"})
    with urllib.request.urlopen(endpoint, timeout=10) as response:
        document = json.load(response)
    results = document.get("data", {}).get("result", [])
    if isinstance(results, list) and len(results) == 2 and isinstance(results[0], (int, float)):
        print(results[1])
    elif results:
        print(results[0].get("value", [None, ""])[1])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
