#!/usr/bin/env python3
from __future__ import annotations

import argparse
import statistics
import sys
from pathlib import Path
from typing import Any

from lib.contracts import ContractError, load_document, require_valid, write_json


METADATA_KEYS = ("profile", "profileHash", "environmentFingerprint", "subject", "provenance")


def aggregate_documents(documents: list[dict[str, Any]], expected_runs: int, run_id: str) -> dict[str, Any]:
    formal = [document for document in documents if not document["metadata"]["warmup"]]
    if not formal:
        raise ContractError("At least one formal run is required")

    source_run_ids = [document["metadata"]["runId"] for document in formal]
    if len(source_run_ids) != len(set(source_run_ids)):
        raise ContractError("Formal run IDs must be unique")
    iterations = [document["metadata"]["iteration"] for document in formal]
    if len(iterations) != len(set(iterations)):
        raise ContractError("Formal run iterations must be unique")

    first_metadata = formal[0]["metadata"]
    for document in formal[1:]:
        metadata = document["metadata"]
        for key in METADATA_KEYS:
            if metadata[key] != first_metadata[key]:
                raise ContractError(f"Formal runs disagree on metadata.{key}")

    valid = [
        document
        for document in formal
        if document["status"] == "success" and document["metrics"]["benchmark_success"]
    ]
    if not valid:
        raise ContractError("No successful formal runs are available for aggregation")

    metric_names = [name for name in valid[0]["metrics"] if name != "benchmark_success"]
    aggregated_metrics: dict[str, Any] = {
        name: statistics.median(document["metrics"][name] for document in valid) for name in metric_names
    }
    complete = len(formal) == expected_runs and len(valid) == expected_runs
    aggregated_metrics["benchmark_success"] = complete

    result = {
        "schemaVersion": "v1",
        "metadata": {
            "runId": run_id,
            "profile": first_metadata["profile"],
            "profileHash": first_metadata["profileHash"],
            "environmentFingerprint": first_metadata["environmentFingerprint"],
            "subject": first_metadata["subject"],
            "provenance": first_metadata["provenance"],
        },
        "summary": {
            "status": "success" if complete else "failed",
            "formalRuns": len(formal),
            "validRuns": len(valid),
            "aggregation": "median",
        },
        "metrics": aggregated_metrics,
        "sourceRuns": source_run_ids,
    }
    require_valid("metrics", result, "aggregated result")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Aggregate normalized Volcano benchmark runs using the median")
    parser.add_argument("--input", type=Path, action="append", required=True, dest="inputs")
    parser.add_argument("--expected-runs", type=int, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.expected_runs < 1:
        parser.error("--expected-runs must be at least 1")

    try:
        documents = []
        for path in args.inputs:
            document = load_document(path)
            require_valid("run-metrics", document, path)
            documents.append(document)
        result = aggregate_documents(documents, args.expected_runs, args.run_id)
        write_json(args.output, result)
    except ContractError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1
    print(
        f"Aggregated {result['summary']['validRuns']}/{result['summary']['formalRuns']} valid formal runs: "
        f"{args.output}"
    )
    return 0 if result["summary"]["status"] == "success" else 2


if __name__ == "__main__":
    sys.exit(main())
