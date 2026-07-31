from __future__ import annotations

import copy
import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
MODULE_PATH = ROOT / "scripts" / "render-run-plan.py"
SPEC = importlib.util.spec_from_file_location("render_run_plan", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

from lib.contracts import load_document  # noqa: E402


class RunPlanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = load_document(ROOT / "tests" / "fixtures" / "mock-bundle" / "environment.json")
        self.profile = load_document(ROOT / "profiles" / "pr-gate.yaml")
        self.candidate = load_document(ROOT / "tests" / "fixtures" / "candidate-release.yaml")

    def test_ready_plan_contains_expected_iterations_and_restore(self) -> None:
        plan = MODULE.build_plan(self.environment, self.profile, self.candidate, "contract-demo")
        self.assertEqual(plan["status"], "ready")
        self.assertEqual(plan["executionZone"], "internal")
        self.assertFalse(plan["networkPolicy"]["publicRegistryAccess"])
        self.assertFalse(plan["networkPolicy"]["publicDownloadFallback"])
        step_ids = [step["id"] for step in plan["steps"]]
        self.assertIn("verify-offline-inputs", step_ids)
        self.assertIn("warmup-1", step_ids)
        self.assertEqual([value for value in step_ids if value.startswith("formal-")], [
            "formal-1",
            "formal-2",
            "formal-3",
        ])
        self.assertIn("validate-candidate-provenance", step_ids)
        self.assertIn("select-deployment-strategy", step_ids)
        self.assertIn("deploy-candidate-release", step_ids)
        self.assertNotIn("replace-volcano-images", [step["action"] for step in plan["steps"]])
        install_tools = next(step for step in plan["steps"] if step["id"] == "install-performance-tools")
        self.assertEqual(install_tools["parameters"]["source"], "offline-performance-tools-bundle")
        self.assertFalse(install_tools["parameters"]["publicRegistryFallback"])
        self.assertEqual(step_ids[-2:], ["cleanup-benchmark", "restore-stable-volcano"])

    def test_missing_adapter_capabilities_block_candidate_plan(self) -> None:
        environment = copy.deepcopy(self.environment)
        environment["capabilities"]["deployCandidateRelease"] = False
        environment["capabilities"]["restoreStableRelease"] = False
        environment["capabilities"]["destroyCluster"] = False
        plan = MODULE.build_plan(environment, self.profile, self.candidate, "blocked-demo")
        self.assertEqual(plan["status"], "blocked")
        self.assertEqual(len(plan["issues"]), 2)

    def test_destroy_cluster_is_valid_recovery_fallback(self) -> None:
        environment = copy.deepcopy(self.environment)
        environment["capabilities"]["restoreStableRelease"] = False
        plan = MODULE.build_plan(environment, self.profile, self.candidate, "destroy-demo")
        self.assertEqual(plan["status"], "ready")
        self.assertEqual(plan["steps"][-1]["id"], "destroy-test-cluster")


if __name__ == "__main__":
    unittest.main()
