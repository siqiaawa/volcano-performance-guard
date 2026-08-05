from __future__ import annotations

import subprocess
import tempfile
import unittest
import importlib.util
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
INSPECT = ROOT / "adapters" / "runtime" / "inspect.sh"
RUN_CANDIDATE = ROOT / "adapters" / "runtime" / "run-candidate.sh"
PREFLIGHT_CANDIDATE = ROOT / "adapters" / "runtime" / "preflight-candidate.sh"
DEPLOY_CANDIDATE = ROOT / "adapters" / "runtime" / "deploy-candidate.sh"
SCAN_BENCHMARK_DEPS = ROOT / "scripts" / "scan-benchmark-deps.py"
TIMESTAMP_BENCHMARK = ROOT / "adapters" / "runtime" / "run-timestamp-benchmark.py"
BUILD_AUDIT_EXPORTER = ROOT / "adapters" / "runtime" / "build-candidate-audit-exporter.sh"
RUN_COMMUNITY_BENCHMARK = ROOT / "adapters" / "runtime" / "run-community-benchmark.sh"
CREATE_AUDIT_CLUSTER = ROOT / "adapters" / "runtime" / "create-candidate-audit-cluster.sh"
INSTALL_MONITORING = ROOT / "adapters" / "runtime" / "install-candidate-monitoring.sh"
PREPARE_CANDIDATE_DEPS = ROOT / "adapters" / "runtime" / "prepare-candidate-deps.sh"
PACKAGE_BENCHMARK_ASSETS = ROOT / "scripts" / "package-benchmark-assets.py"
IMPORT_BENCHMARK_ASSETS = ROOT / "scripts" / "import-benchmark-assets.py"
IMPORT_VERSION_DEPS = ROOT / "adapters" / "runtime" / "import-version-deps.sh"
TOOLS_DOCKERFILE = ROOT / "tools" / "Dockerfile"
TOOLS_WRAPPER = ROOT / "scripts" / "run-performance-tools.sh"
RUNTIME_DIR = ROOT / "runtime"
RELEASE_ASSETS = ROOT / "release-assets"
SPEC = importlib.util.spec_from_file_location("scan_benchmark_deps", SCAN_BENCHMARK_DEPS)
assert SPEC and SPEC.loader
SCAN_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCAN_MODULE)
IMPORT_SPEC = importlib.util.spec_from_file_location("import_benchmark_assets", IMPORT_BENCHMARK_ASSETS)
assert IMPORT_SPEC and IMPORT_SPEC.loader
IMPORT_MODULE = importlib.util.module_from_spec(IMPORT_SPEC)
IMPORT_SPEC.loader.exec_module(IMPORT_MODULE)


class RuntimeAdapterTests(unittest.TestCase):
    def test_internal_runtime_fingerprint_matches_tracked_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "runtime.yaml"
            result = subprocess.run(
                ["bash", str(INSPECT), "--runtime-dir", str(RUNTIME_DIR), "--output", str(output)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            detected = yaml.safe_load(output.read_text(encoding="utf-8"))
        tracked = yaml.safe_load((ROOT / "configs" / "runtime.detected.yaml").read_text(encoding="utf-8"))
        self.assertEqual(detected["runtime"]["fingerprint"], tracked["bundle"]["fingerprint"])
        self.assertEqual(detected["stableVolcano"]["commit"], tracked["referenceVolcano"]["commit"])

    def test_release_manifest_and_checksums_cover_the_same_assets(self) -> None:
        release_values = {}
        for line in (RELEASE_ASSETS / "release.env").read_text(encoding="utf-8").splitlines():
            key, value = line.split("=", 1)
            release_values[key] = value.strip('"')
        declared = set(release_values["RELEASE_ASSETS"].split())
        checksummed = {
            line.split("  ", 1)[1]
            for line in (RELEASE_ASSETS / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
        }
        self.assertEqual(declared, checksummed)
        self.assertEqual(len(declared), 6)

    def test_help_is_side_effect_free(self) -> None:
        result = subprocess.run(
            ["bash", str(INSPECT), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--runtime-dir", result.stdout)

    def test_missing_runtime_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "missing"
            result = subprocess.run(
                ["bash", str(INSPECT), "--runtime-dir", str(missing)],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Directory not found", result.stderr)

    def test_candidate_entrypoint_help_is_side_effect_free(self) -> None:
        for entrypoint in (RUN_CANDIDATE, PREFLIGHT_CANDIDATE):
            with self.subTest(entrypoint=entrypoint.name):
                result = subprocess.run(
                    ["bash", str(entrypoint), "--help"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--candidate-dir", result.stdout)

    def test_candidate_runner_requires_command_separator(self) -> None:
        result = subprocess.run(
            [
                "bash",
                str(RUN_CANDIDATE),
                "--runtime-dir",
                "/missing-bundle",
                "--candidate-dir",
                "/missing-candidate",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("A command is required after --", result.stderr)

    def test_candidate_deploy_checks_the_default_core_component_set(self) -> None:
        script = DEPLOY_CANDIDATE.read_text(encoding="utf-8")
        self.assertIn("for component in scheduler controller-manager webhook-manager", script)
        self.assertNotIn("((${#rendered_images[@]} >= 4))", script)

    def test_candidate_runner_keeps_stdin_open_for_kubectl_manifests(self) -> None:
        script = RUN_CANDIDATE.read_text(encoding="utf-8")
        self.assertIn("run --rm --interactive", script)

    def test_benchmark_dependency_scanner_is_read_only(self) -> None:
        script = SCAN_BENCHMARK_DEPS.read_text(encoding="utf-8")
        self.assertIn('"image", "inspect"', script)
        self.assertNotIn('"pull"', script)
        self.assertIn("externalManifestUrls", script)

    def test_benchmark_dependency_scanner_ignores_unrendered_templates_and_mutable_tags(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "candidate"
            benchmark = candidate / "benchmark"
            benchmark.mkdir(parents=True)
            (benchmark / "case.yaml").write_text(
                "image: {{ .Image }}\nimage: grafana/grafana:latest\n- image: docker.io/example/ksm:v1\nimage: busybox:1.36\n",
                encoding="utf-8",
            )
            images, _ = SCAN_MODULE.collect_required_images(candidate)
        self.assertNotIn("{{", images)
        self.assertIn("docker.io/example/ksm:v1", images)
        self.assertFalse(
            SCAN_MODULE.image_record("grafana/grafana:latest", [], set(), "missing-docker")["pinned"]
        )

    def test_benchmark_dependency_scanner_includes_dockerfile_base_images(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            candidate = Path(directory) / "candidate"
            benchmark = candidate / "benchmark"
            benchmark.mkdir(parents=True)
            (benchmark / "Dockerfile").write_text(
                "FROM golang:1.25.0@sha256:abc\nFROM alpine:3.24.1\n",
                encoding="utf-8",
            )
            images, references = SCAN_MODULE.collect_required_images(candidate)
        self.assertIn("golang:1.25.0@sha256:abc", images)
        self.assertIn("alpine:3.24.1", images)
        self.assertIn("benchmark/Dockerfile (Dockerfile FROM)", images["golang:1.25.0@sha256:abc"])

    def test_timestamp_benchmark_fingerprints_its_own_tooling(self) -> None:
        script = TIMESTAMP_BENCHMARK.read_text(encoding="utf-8")
        self.assertIn("def performance_tools_version()", script)
        self.assertIn("pod-timestamps-v1+sha256:", script)

    def test_benchmark_asset_entrypoints_have_side_effect_free_help(self) -> None:
        for entrypoint in (PACKAGE_BENCHMARK_ASSETS, IMPORT_BENCHMARK_ASSETS):
            with self.subTest(entrypoint=entrypoint.name):
                result = subprocess.run(
                    ["python3", str(entrypoint), "--help"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_benchmark_asset_packaging_has_explicit_network_boundary(self) -> None:
        package_script = PACKAGE_BENCHMARK_ASSETS.read_text(encoding="utf-8")
        import_script = IMPORT_BENCHMARK_ASSETS.read_text(encoding="utf-8")
        self.assertIn("--allow-network", package_script)
        self.assertIn('["docker", "pull"', package_script)
        self.assertNotIn('["docker", "pull"', import_script)

    def test_performance_tools_image_is_candidate_bound_and_wrapper_has_help(self) -> None:
        dockerfile = TOOLS_DOCKERFILE.read_text(encoding="utf-8")
        self.assertIn("io.volcano.performance-guard.candidate.commit", dockerfile)
        self.assertIn("COPY --from=runner-tools /usr/local/bin/docker-real", dockerfile)
        self.assertIn("PYTHONPATH=/opt/performance-guard/vendor", dockerfile)
        wrapper_script = TOOLS_WRAPPER.read_text(encoding="utf-8")
        self.assertIn("add_safe_git_directory", wrapper_script)
        result = subprocess.run(
            ["bash", str(TOOLS_WRAPPER), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Python is not required", result.stdout)

    def test_import_supports_container_registry_probe_boundary(self) -> None:
        script = IMPORT_BENCHMARK_ASSETS.read_text(encoding="utf-8")
        self.assertIn("--skip-registry-probe", script)
        self.assertIn("Docker push still verifies registry availability", script)

    def test_import_writes_shell_safe_registry_environment_keys(self) -> None:
        key = IMPORT_MODULE.environment_key(
            "localhost:15001/volcanosh/performance-guard-tools:deadbeef"
        )
        self.assertEqual(key, "VOLCANOSH_PERFORMANCE_GUARD_TOOLS_DEADBEEF")
        self.assertRegex(key, r"^[A-Z_][A-Z0-9_]*$")

    def test_audit_exporter_build_is_candidate_bound_and_offline(self) -> None:
        script = BUILD_AUDIT_EXPORTER.read_text(encoding="utf-8")
        self.assertIn("--network none", script)
        self.assertIn("io.volcano.performance-guard.candidate.commit", script)

    def test_community_benchmark_entrypoint_help_is_side_effect_free(self) -> None:
        result = subprocess.run(
            ["bash", str(RUN_COMMUNITY_BENCHMARK), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--scenario", result.stdout)
        self.assertIn("--use-kwok", result.stdout)

    def test_audit_entrypoints_have_side_effect_free_help(self) -> None:
        for entrypoint in (CREATE_AUDIT_CLUSTER, INSTALL_MONITORING):
            with self.subTest(entrypoint=entrypoint.name):
                result = subprocess.run(
                    ["bash", str(entrypoint), "--help"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--runtime-dir", result.stdout)

    def test_candidate_dependency_prepare_entrypoint_is_explicit_about_network(self) -> None:
        result = subprocess.run(
            ["bash", str(PREPARE_CANDIDATE_DEPS), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--allow-network", result.stdout)
        script = PREPARE_CANDIDATE_DEPS.read_text(encoding="utf-8")
        self.assertIn("package-candidate-deps.sh", script)
        self.assertIn("import-candidate-deps.sh", script)
        self.assertIn("--runner-image", script)
        self.assertIn("max_iterations=5", script)
        self.assertIn("sort -u", script)

    def test_version_dependency_importer_has_an_offline_contract(self) -> None:
        result = subprocess.run(
            ["bash", str(IMPORT_VERSION_DEPS), "--help"],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--runtime-dir", result.stdout)
        self.assertIn("--asset-dir", result.stdout)
        script = IMPORT_VERSION_DEPS.read_text(encoding="utf-8")
        self.assertIn("go-mod-supplement.tar.gz.sha256", script)
        self.assertIn("--network=none", script)
        self.assertIn("base-runner-image.txt", script)


if __name__ == "__main__":
    unittest.main()
