from __future__ import annotations

import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINT = ROOT / "volcano-performance-guard.sh"
RUN_CANDIDATE = ROOT / "adapters" / "runtime" / "run-candidate.sh"
TIMESTAMP_PROFILE = ROOT / "scripts" / "run-timestamp-profile.py"
TIMESTAMP_BENCHMARK = ROOT / "adapters" / "runtime" / "run-timestamp-benchmark.py"
BUILD_BINARIES = ROOT / "adapters" / "runtime" / "build-candidate-binaries.sh"
MAKEFILE = ROOT / "Makefile"


class UnifiedEntrypointTests(unittest.TestCase):
    def test_help_lists_both_public_workflows(self) -> None:
        result = subprocess.run(
            ["bash", str(ENTRYPOINT), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fixed-compare", result.stdout)
        self.assertIn("version-compare", result.stdout)
        self.assertIn("--baseline-metrics", result.stdout)

    def test_public_entrypoint_defaults_to_internal_runtime_and_stable(self) -> None:
        script = ENTRYPOINT.read_text(encoding="utf-8")
        self.assertIn('runtime_dir="${RUNTIME_DIR:-$ROOT_DIR/runtime}"', script)
        self.assertIn('stable_path="$ROOT_DIR/stable/volcano"', script)
        self.assertNotIn("../volcano-offline-e2e-bundle", script)

    def test_metrics_only_comparison_does_not_require_runtime_assets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = subprocess.run(
                [
                    "bash",
                    str(ENTRYPOINT),
                    "fixed-compare",
                    "--runtime-dir",
                    str(root / "missing-bundle"),
                    "--candidate-metrics",
                    str(root / "missing-candidate.json"),
                    "--baseline-metrics",
                    str(root / "missing-baseline.json"),
                    "--output-dir",
                    str(root / "output"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Candidate metrics not found", result.stderr)
        self.assertNotIn("Directory not found", result.stderr)

    def test_metrics_only_comparison_writes_all_reports(self) -> None:
        source = json.loads(
            (ROOT / "tests" / "fixtures" / "run-metrics" / "formal-1.json").read_text(encoding="utf-8")
        )
        metadata = {
            key: value
            for key, value in source["metadata"].items()
            if key not in {"iteration", "warmup"}
        }
        candidate = {
            "schemaVersion": "v1",
            "metadata": metadata,
            "summary": {"status": "success", "formalRuns": 1, "validRuns": 1, "aggregation": "median"},
            "metrics": source["metrics"],
            "sourceRuns": [source["metadata"]["runId"]],
        }
        candidate["metadata"]["subject"] = {
            "type": "candidate",
            "version": "a" * 40,
            "commit": "a" * 40,
        }
        baseline = copy.deepcopy(candidate)
        baseline["metadata"]["runId"] = "fixed-baseline"
        baseline["metadata"]["subject"] = {
            "type": "stable",
            "version": "fixed",
            "commit": "b" * 40,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate_path = root / "candidate.json"
            baseline_path = root / "baseline.json"
            output = root / "output"
            candidate_path.write_text(json.dumps(candidate), encoding="utf-8")
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")
            result = subprocess.run(
                [
                    "bash",
                    str(ENTRYPOINT),
                    "fixed-compare",
                    "--candidate-metrics",
                    str(candidate_path),
                    "--baseline-metrics",
                    str(baseline_path),
                    "--output-dir",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            comparison = json.loads((output / "comparison" / "comparison.json").read_text(encoding="utf-8"))
            self.assertEqual(comparison["status"], "PASS")
            self.assertTrue((output / "comparison" / "comparison.md").is_file())
            self.assertTrue((output / "comparison" / "comparison.junit.xml").is_file())
            self.assertTrue((output / "comparison" / "comparison.html").is_file())

    def test_online_go_mode_is_explicit_and_defaults_remain_offline(self) -> None:
        script = RUN_CANDIDATE.read_text(encoding="utf-8")
        build_script = BUILD_BINARIES.read_text(encoding="utf-8")
        self.assertIn('go_mode="${PERFORMANCE_GUARD_GO_MODE:-offline}"', script)
        self.assertIn("Online Go mode requires --network host", script)
        self.assertIn("https://goproxy.cn,direct", script)
        self.assertIn("go_proxy=off", script)
        self.assertIn('go_toolchain="${PERFORMANCE_GUARD_GOTOOLCHAIN:-auto}"', script)
        self.assertIn('$runtime_dir/bin/kind', script)
        self.assertIn('/usr/local/bin/docker:ro', script)
        self.assertIn('$state_dir/go-mod:/go/pkg/mod', script)
        self.assertIn('VOLCANO_RUNTIME_CGROUPNS_MODE', script)
        self.assertIn('network_mode="${PERFORMANCE_GUARD_NETWORK_MODE:-none}"', build_script)
        self.assertIn("BUILD_NETWORK=$network_mode", build_script)

    def test_stable_build_is_explicitly_offline_and_uses_a_bound_runner(self) -> None:
        script = ENTRYPOINT.read_text(encoding="utf-8")
        importer = (ROOT / "adapters" / "runtime" / "import-version-deps.sh").read_text(
            encoding="utf-8"
        )
        runner_dockerfile = (ROOT / "adapters" / "runtime" / "candidate-deps.Dockerfile").read_text(
            encoding="utf-8"
        )
        self.assertIn("--stable-deps-dir", script)
        self.assertIn("--stable-runner-image", script)
        self.assertIn("prepare_stable_runner", script)
        self.assertIn('go_mode="offline"', script)
        self.assertIn('network_mode="none"', script)
        self.assertIn("import-version-deps.sh", script)
        self.assertIn("--network=none", importer)
        self.assertIn("ENV GOPROXY=off", runner_dockerfile)

    def test_unified_profile_is_forwarded_to_each_version_run(self) -> None:
        script = ENTRYPOINT.read_text(encoding="utf-8")
        makefile = MAKEFILE.read_text(encoding="utf-8")
        self.assertIn('TIMESTAMP_PROFILE="$profile"', script)
        self.assertIn('[[ "$run_id" =~ ^[a-z0-9][a-z0-9-]{0,14}$ ]]', script)
        self.assertIn("PERFORMANCE_GUARD_TOOLS_IMAGE ?= $(PERFORMANCE_TOOLS_IMAGE)", makefile)

    def test_timestamp_subject_type_is_forwarded_to_each_iteration(self) -> None:
        profile_script = TIMESTAMP_PROFILE.read_text(encoding="utf-8")
        benchmark_script = TIMESTAMP_BENCHMARK.read_text(encoding="utf-8")
        self.assertIn('"--subject-type", args.subject_type', profile_script)
        self.assertIn('choices=("stable", "candidate")', benchmark_script)
        self.assertIn('"type": args.subject_type', benchmark_script)


if __name__ == "__main__":
    unittest.main()
