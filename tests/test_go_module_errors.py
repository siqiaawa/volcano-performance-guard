from __future__ import annotations

import unittest

from scripts.list_missing_go_modules import decode_stream, missing_references


class GoModuleErrorTests(unittest.TestCase):
    def test_lists_only_failed_modules_from_json_stream(self) -> None:
        values = decode_stream(
            '{"Path":"example.test/ok","Version":"v1.0.0","Dir":"/cache/ok"}\n'
            '{"Path":"example.test/missing","Version":"v2.0.0","Error":"GOPROXY=off"}\n'
        )
        self.assertEqual(
            missing_references(values), ["example.test/missing@v2.0.0"]
        )

    def test_rejects_non_object_stream_values(self) -> None:
        with self.assertRaises(ValueError):
            decode_stream("[]")


if __name__ == "__main__":
    unittest.main()
