from __future__ import annotations

import copy
import shlex
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from lib.contracts import (  # noqa: E402
    SCHEMA_FILES,
    load_document,
    load_schema,
    validation_errors,
    write_environment_env,
)


class ContractSchemaTests(unittest.TestCase):
    def setUp(self) -> None:
        self.environment = load_document(ROOT / "tests" / "fixtures" / "mock-bundle" / "environment.json")
        self.candidate = load_document(ROOT / "tests" / "fixtures" / "candidate-release.yaml")

    def test_all_schemas_are_valid_draft_2020_12(self) -> None:
        for kind in SCHEMA_FILES:
            with self.subTest(kind=kind):
                self.assertIsInstance(load_schema(kind), dict)

    def test_versioned_examples_validate(self) -> None:
        examples = [
            ("environment", ROOT / "tests" / "fixtures" / "mock-bundle" / "environment.json"),
            ("candidate-release", ROOT / "tests" / "fixtures" / "candidate-release.yaml"),
            ("profile", ROOT / "profiles" / "smoke.yaml"),
            ("profile", ROOT / "profiles" / "offline-timestamp-smoke.yaml"),
            ("profile", ROOT / "profiles" / "pr-gate.yaml"),
        ]
        examples.extend(
            ("run-metrics", path) for path in sorted((ROOT / "tests" / "fixtures" / "run-metrics").glob("*.json"))
        )
        for kind, path in examples:
            with self.subTest(kind=kind, path=path.name):
                self.assertEqual(validation_errors(kind, load_document(path)), [])

    def test_mutable_candidate_tag_is_rejected(self) -> None:
        document = copy.deepcopy(self.candidate)
        document["candidate"]["components"]["scheduler"]["image"]["tag"] = "latest"
        self.assertTrue(validation_errors("candidate-release", document))

    def test_candidate_component_set_is_discovered_not_fixed(self) -> None:
        document = copy.deepcopy(self.candidate)
        document["candidate"]["componentDiscovery"]["components"].remove("agent-scheduler")
        del document["candidate"]["components"]["agent-scheduler"]
        self.assertEqual(validation_errors("candidate-release", document), [])

    def test_mixed_commit_deployment_material_is_rejected(self) -> None:
        document = copy.deepcopy(self.candidate)
        document["candidate"]["deploymentMaterials"]["crds"][0]["sourceCommit"] = "1" * 40
        self.assertIn(
            "$.candidate.deploymentMaterials.crds[0].sourceCommit must match $.candidate.commit",
            validation_errors("candidate-release", document),
        )

    def test_image_only_strategy_requires_compatibility_evidence(self) -> None:
        document = copy.deepcopy(self.candidate)
        document["candidate"]["deployment"]["strategy"] = "image-only"
        self.assertTrue(validation_errors("candidate-release", document))

    def test_gang_min_available_cannot_exceed_replicas(self) -> None:
        document = load_document(ROOT / "profiles" / "smoke.yaml")
        document["workload"]["minAvailable"] = document["workload"]["replicasPerJob"] + 1
        self.assertIn(
            "$.workload.minAvailable cannot exceed replicasPerJob",
            validation_errors("profile", document),
        )

    def test_profile_allows_zero_kwok_nodes_for_an_existing_cluster(self) -> None:
        document = load_document(ROOT / "profiles" / "offline-timestamp-smoke.yaml")
        self.assertEqual(validation_errors("profile", document), [])

    def test_environment_env_uses_shell_quoting(self) -> None:
        document = copy.deepcopy(self.environment)
        document["cluster"]["name"] = "mock; printf unsafe"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "environment.env"
            source = Path(directory) / "environment.json"
            write_environment_env(output, document, source)
            values = {}
            for line in output.read_text(encoding="utf-8").splitlines():
                if not line.startswith("export "):
                    continue
                tokens = shlex.split(line)
                key, value = tokens[1].split("=", 1)
                values[key] = value
            self.assertEqual(values["CLUSTER_NAME"], "mock; printf unsafe")
            self.assertEqual(values["CLUSTER_PROVIDER"], "mock")
            self.assertEqual(values["BUNDLE_VERSION"], "")
            self.assertEqual(values["BUNDLE_FINGERPRINT"], f"sha256:{'1' * 64}")
            self.assertEqual(values["BUNDLE_ARCHIVE_SHA256"], "")
            self.assertEqual(values["STABLE_VOLCANO_VERSION"], "v1.15.0")
            self.assertNotIn("VOLCANO_VERSION", values)


if __name__ == "__main__":
    unittest.main()
