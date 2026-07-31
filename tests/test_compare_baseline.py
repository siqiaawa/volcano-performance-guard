from __future__ import annotations

import copy
import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from lib.contracts import load_document  # noqa: E402

MODULE_PATH = ROOT / "scripts" / "compare-baseline.py"
SPEC = importlib.util.spec_from_file_location("compare_baseline", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CompareBaselineTests(unittest.TestCase):
    def setUp(self) -> None:
        self.candidate = load_document(ROOT / "tests" / "fixtures" / "run-metrics" / "formal-1.json")
        self.candidate["metadata"]["subject"] = {
            "type": "candidate",
            "version": "a" * 40,
            "commit": "a" * 40,
        }
        self.baseline = copy.deepcopy(self.candidate)
        self.baseline["metadata"]["subject"] = {"type": "stable", "version": "v1.15.0", "commit": None}
        self.rules = {"pod_scheduling_latency_p99_ms": {"direction": "lower", "warningRelative": 0.1, "failureRelative": 0.2}}

    def test_same_environment_passes(self) -> None:
        result = MODULE.metric_result("pod_scheduling_latency_p99_ms", 120.0, 100.0, self.rules["pod_scheduling_latency_p99_ms"])
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(MODULE.compatibility_errors(self.candidate, self.baseline), [])

    def test_different_environment_is_rejected(self) -> None:
        self.baseline["metadata"]["environmentFingerprint"] = "sha256:" + "0" * 64
        self.assertIn("metadata.environmentFingerprint differs", MODULE.compatibility_errors(self.candidate, self.baseline))

    def test_direct_failures_are_never_threshold_warnings(self) -> None:
        self.candidate["metrics"]["pending_pods"] = 1
        self.assertEqual(MODULE.direct_failures(self.candidate["metrics"]), ["pending_pods=1"])

    def test_zero_baseline_metric_cannot_be_used_for_relative_thresholds(self) -> None:
        with self.assertRaisesRegex(Exception, "zero baseline"):
            MODULE.metric_result("pod_scheduling_latency_p99_ms", 1.0, 0.0, self.rules["pod_scheduling_latency_p99_ms"])

    def test_html_report_contains_status_metrics_and_escaped_paths(self) -> None:
        result = {
            "status": "WARNING",
            "candidate": "/tmp/candidate<&>.json",
            "baseline": "/tmp/baseline.json",
            "compatibilityErrors": [],
            "directFailures": [],
            "comparisons": [
                MODULE.metric_result(
                    "pod_scheduling_latency_p99_ms",
                    115.0,
                    100.0,
                    self.rules["pod_scheduling_latency_p99_ms"],
                )
            ],
        }
        document = MODULE.html_report(result)
        self.assertIn("<!doctype html>", document)
        self.assertIn("WARNING", document)
        self.assertIn("pod_scheduling_latency_p99_ms", document)
        self.assertIn("candidate&lt;&amp;&gt;.json", document)
        self.assertNotIn("candidate<&>.json", document)


if __name__ == "__main__":
    unittest.main()
