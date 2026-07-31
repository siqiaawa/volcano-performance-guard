from __future__ import annotations

import copy
import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
MODULE_PATH = ROOT / "scripts" / "aggregate-metrics.py"
SPEC = importlib.util.spec_from_file_location("aggregate_metrics", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

from lib.contracts import ContractError, load_document, validation_errors  # noqa: E402


class AggregateMetricsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.documents = [
            load_document(path)
            for path in sorted((ROOT / "tests" / "fixtures" / "run-metrics").glob("formal-*.json"))
        ]

    def test_aggregates_median_and_provenance(self) -> None:
        result = MODULE.aggregate_documents(self.documents, expected_runs=3, run_id="contract-demo")
        self.assertEqual(result["summary"], {
            "status": "success",
            "formalRuns": 3,
            "validRuns": 3,
            "aggregation": "median",
        })
        self.assertEqual(result["metrics"]["pod_scheduling_latency_p50_ms"], 100.0)
        self.assertEqual(result["metrics"]["pod_scheduling_throughput_pods_per_second"], 440.0)
        self.assertEqual(result["metrics"]["scheduler_cpu_peak_cores"], 3.0)
        self.assertEqual(result["metrics"]["scheduler_memory_peak_mb"], 1900)
        self.assertEqual(result["metadata"]["subject"]["type"], "candidate")
        self.assertEqual(result["metadata"]["provenance"]["stableVolcanoVersion"], "v1.15.0")
        self.assertEqual(validation_errors("metrics", result), [])

    def test_expected_run_mismatch_is_explicit_failure(self) -> None:
        result = MODULE.aggregate_documents(self.documents, expected_runs=4, run_id="incomplete-demo")
        self.assertEqual(result["summary"]["status"], "failed")
        self.assertFalse(result["metrics"]["benchmark_success"])

    def test_mixed_environment_fingerprints_are_rejected(self) -> None:
        documents = copy.deepcopy(self.documents)
        documents[-1]["metadata"]["environmentFingerprint"] = f"sha256:{'d' * 64}"
        with self.assertRaisesRegex(ContractError, "environmentFingerprint"):
            MODULE.aggregate_documents(documents, expected_runs=3, run_id="invalid-demo")

    def test_duplicate_formal_iterations_are_rejected(self) -> None:
        documents = copy.deepcopy(self.documents)
        documents[-1]["metadata"]["iteration"] = documents[0]["metadata"]["iteration"]
        with self.assertRaisesRegex(ContractError, "iterations must be unique"):
            MODULE.aggregate_documents(documents, expected_runs=3, run_id="invalid-demo")

    def test_mixed_performance_tools_versions_are_rejected(self) -> None:
        documents = copy.deepcopy(self.documents)
        documents[-1]["metadata"]["provenance"]["performanceToolsVersion"] = "mock-tools-v2"
        with self.assertRaisesRegex(ContractError, "provenance"):
            MODULE.aggregate_documents(documents, expected_runs=3, run_id="invalid-demo")


if __name__ == "__main__":
    unittest.main()
