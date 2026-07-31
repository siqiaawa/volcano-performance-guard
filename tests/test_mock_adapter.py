from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "adapters" / "mock"
FIXTURE = ROOT / "tests" / "fixtures" / "mock-bundle"


class MockAdapterIntegrationTests(unittest.TestCase):
    def test_prepare_refuses_output_outside_project_work_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            workdir = Path(directory)
            prepare = subprocess.run(
                [
                    "bash",
                    str(ADAPTER / "prepare.sh"),
                    "--bundle",
                    str(FIXTURE),
                    "--workdir",
                    str(workdir),
                    "--output-env",
                    str(workdir / "environment.env"),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(prepare.returncode, 0)
            self.assertIn(".work", prepare.stderr)

    def test_prepare_inspect_and_marker_guarded_cleanup(self) -> None:
        work_root = ROOT / ".work"
        work_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="mock-adapter-test.", dir=work_root) as directory:
            workdir = Path(directory)
            env_file = workdir / "environment.env"
            prepare = subprocess.run(
                [
                    "bash",
                    str(ADAPTER / "prepare.sh"),
                    "--bundle",
                    str(FIXTURE),
                    "--workdir",
                    str(workdir),
                    "--output-env",
                    str(env_file),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(prepare.returncode, 0, prepare.stderr)
            self.assertTrue((workdir / "environment.json").is_file())
            self.assertTrue(env_file.is_file())

            inspect = subprocess.run(
                ["bash", str(ADAPTER / "inspect.sh"), "--env", str(env_file)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(inspect.returncode, 0, inspect.stderr)
            self.assertIn('"mode": "mock"', inspect.stdout)

            cleanup = subprocess.run(
                ["bash", str(ADAPTER / "cleanup.sh"), "--env", str(env_file)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(cleanup.returncode, 0, cleanup.stderr)
            self.assertTrue(workdir.is_dir())
            self.assertTrue((workdir / "environment.json").is_file())
            self.assertTrue(env_file.is_file())
            state = json.loads((workdir / ".mock-environment-adapter.json").read_text(encoding="utf-8"))
            self.assertEqual(state["state"], "cleaned")

            repeated = subprocess.run(
                ["bash", str(ADAPTER / "cleanup.sh"), "--env", str(env_file)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(repeated.returncode, 0, repeated.stderr)


if __name__ == "__main__":
    unittest.main()
