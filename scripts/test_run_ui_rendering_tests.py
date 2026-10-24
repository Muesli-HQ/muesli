#!/usr/bin/env python3
"""Linux-compatible disabled-profile fallback tests for the UI-rendering runner."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts/run_ui_rendering_tests.sh"


class UIRenderingRunnerTests(unittest.TestCase):
    def test_disabled_profile_writes_structured_harness_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "result"
            process = subprocess.run([str(RUNNER), "--output", str(output)], text=True,
                                     capture_output=True, check=False)
            self.assertEqual(process.returncode, 78, process.stderr)
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["outcome"], "harness_error")
            self.assertEqual(summary["counts"]["errors"], 2)
            suites = {suite["suite"]: suite for suite in summary["suites"]}
            self.assertEqual(set(suites), {"snapshot", "e2e"})
            self.assertTrue(all(suite["status"] == "harness_error" for suite in suites.values()))

    def test_timeout_range_is_rejected_before_execution(self):
        process = subprocess.run([str(RUNNER), "--timeout-seconds", "1"], text=True,
                                 capture_output=True, check=False)
        self.assertEqual(process.returncode, 2)
        self.assertIn("between 60 and 7200", process.stderr)


if __name__ == "__main__":
    unittest.main()
