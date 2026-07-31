from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "collect-community-benchmark-metrics.py"
SPEC = importlib.util.spec_from_file_location("collect_community_benchmark_metrics", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def pod(name: str, scheduled_second: int) -> dict[str, object]:
    return {
        "metadata": {"name": name, "creationTimestamp": "2026-07-31T00:00:00Z"},
        "status": {
            "phase": "Running",
            "conditions": [
                {
                    "type": "PodScheduled",
                    "status": "True",
                    "lastTransitionTime": f"2026-07-31T00:00:0{scheduled_second}Z",
                }
            ],
        },
    }


class CommunityBenchmarkMetricsTests(unittest.TestCase):
    def test_collects_offline_latency_throughput_and_correctness_metrics(self) -> None:
        metadata = {
            "candidateCommit": "d" * 40,
            "clusterName": "volcano-candidate-test",
            "scenario": "pod",
            "requestedCount": "3",
            "expectedPods": "3",
            "scheduler": "volcano",
            "kwok": "true",
            "testStatus": "0",
        }
        scheduler = {
            "items": [
                {"status": {"containerStatuses": [{"name": "volcano-scheduler", "restartCount": 1}]}}
            ]
        }
        events = [
            {
                "Time": "2026-07-31T00:00:01.000000000Z",
                "Action": "output",
                "Test": "TestFromConfig",
                "Output": "    pod_test.go:175: Submitted 3 pods\n",
            },
            {
                "Time": "2026-07-31T00:00:03.000000000Z",
                "Action": "output",
                "Test": "TestFromConfig",
                "Output": "    pod_test.go:183: === Results ===\n",
            },
            {
                "Time": "2026-07-31T00:00:03.100000000Z",
                "Action": "pass",
                "Test": "TestFromConfig",
                "Elapsed": 2.1,
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            events_path = Path(directory) / "events.jsonl"
            events_path.write_text("".join(json.dumps(event) + "\n" for event in events), encoding="utf-8")
            result, log_lines = MODULE.collect(
                metadata,
                {"items": [pod("pod-1", 1), pod("pod-2", 2), pod("pod-3", 3)]},
                events_path,
                scheduler,
                scheduler,
            )

        metrics = result["metrics"]
        self.assertTrue(result["benchmarkSuccess"])
        self.assertEqual(metrics["pod_scheduling_latency_p50_ms"], 2000.0)
        self.assertEqual(metrics["pod_scheduling_latency_p90_ms"], 2800.0)
        self.assertEqual(metrics["pod_scheduling_latency_p99_ms"], 2980.0)
        self.assertEqual(metrics["total_scheduling_duration_seconds"], 2.0)
        self.assertEqual(metrics["pod_scheduling_throughput_pods_per_second"], 1.5)
        self.assertEqual(metrics["scheduled_pod_ratio"], 1.0)
        self.assertFalse(result["measurement"]["latencyGateEligible"])
        self.assertIn("Submitted 3 pods", "".join(log_lines))

    def test_missing_pods_fail_without_synthesizing_latency_zeroes(self) -> None:
        metadata = {
            "candidateCommit": "e" * 40,
            "clusterName": "volcano-candidate-test",
            "scenario": "gang",
            "requestedCount": "2",
            "expectedPods": "2",
            "scheduler": "volcano",
            "kwok": "false",
            "testStatus": "1",
        }
        with tempfile.TemporaryDirectory() as directory:
            events_path = Path(directory) / "events.jsonl"
            events_path.write_text(
                json.dumps(
                    {
                        "Time": "2026-07-31T00:00:01Z",
                        "Action": "fail",
                        "Test": "TestFromConfig",
                        "Elapsed": 10.0,
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            result, _ = MODULE.collect(metadata, {"items": []}, events_path, {"items": []}, {"items": []})

        self.assertFalse(result["benchmarkSuccess"])
        self.assertEqual(result["metrics"]["pending_pods"], 2)
        self.assertIsNone(result["metrics"]["pod_scheduling_latency_p50_ms"])
        self.assertIsNone(result["metrics"]["pod_scheduling_throughput_pods_per_second"])

    def test_audit_report_replaces_second_precision_latency(self) -> None:
        metadata = {
            "candidateCommit": "f" * 40,
            "clusterName": "volcano-candidate-audit-test",
            "scenario": "pod",
            "requestedCount": "2",
            "expectedPods": "2",
            "scheduler": "volcano",
            "kwok": "false",
            "testStatus": "0",
        }
        events = [
            {"Time": "2026-07-31T00:00:01Z", "Action": "output", "Output": "Submitted 2 pods\n"},
            {"Time": "2026-07-31T00:00:02Z", "Action": "output", "Output": "=== Results ===\n"},
        ]
        audit = {
            "pod_scheduling_latency_seconds": {"p50": 0.0123, "p90": 0.021, "p99": 0.034, "count": 2}
        }
        with tempfile.TemporaryDirectory() as directory:
            events_path = Path(directory) / "events.jsonl"
            events_path.write_text("".join(json.dumps(event) + "\n" for event in events), encoding="utf-8")
            result, _ = MODULE.collect(
                metadata,
                {"items": [pod("pod-1", 1), pod("pod-2", 2)]},
                events_path,
                {"items": []},
                {"items": []},
                audit,
                [{"cpuCores": 0.2, "memoryMb": 10}, {"cpuCores": 0.4, "memoryMb": 12}],
            )

        self.assertTrue(result["measurement"]["latencyGateEligible"])
        self.assertEqual(result["measurement"]["latencyPrecision"], "microseconds")
        self.assertEqual(result["metrics"]["pod_scheduling_latency_p50_ms"], 12.3)
        self.assertEqual(result["metrics"]["scheduler_cpu_peak_cores"], 0.4)


if __name__ == "__main__":
    unittest.main()
