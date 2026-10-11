#!/usr/bin/env python3
"""Linux-compatible contract tests for scripts/ui_rendering_report.py."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPORTER = ROOT / "scripts/ui_rendering_report.py"


def completed(suite, cases):
    return {"schema_version": 1, "suite": suite, "status": "completed", "renderer_profile": {"host": "test"},
            "cases": cases}


class UIRenderingReportTests(unittest.TestCase):
    def report(self, documents):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        inputs = []
        for index, document in enumerate(documents):
            path = root / f"{index}.json"
            path.write_text(json.dumps(document))
            inputs.extend(["--input", str(path)])
        output = root / "report"
        process = subprocess.run([sys.executable, str(REPORTER), *inputs, "--output", str(output)],
                                 text=True, capture_output=True, check=False)
        return process, output

    def test_image_differences_are_advisory(self):
        process, output = self.report([
            completed("snapshot", [{"id": "settings-dark", "status": "changed"}]),
            completed("e2e", [{"id": "first-launch", "status": "missing_baseline"}]),
        ])
        self.assertEqual(process.returncode, 0, process.stderr)
        summary = json.loads((output / "summary.json").read_text())
        self.assertEqual(summary["outcome"], "advisory")
        self.assertTrue(summary["advisory"])
        self.assertEqual(summary["counts"]["changed"], 1)
        self.assertEqual(summary["counts"]["missing_baseline"], 1)

    def test_html_escapes_case_ids_and_quotes_artifact_paths(self):
        process, output = self.report([
            completed("snapshot", [{"id": "<unsafe>&", "status": "matched",
                                    "artifacts": {"actual": "cases/a b.png"}}]),
        ])
        self.assertEqual(process.returncode, 0, process.stderr)
        page = (output / "index.html").read_text()
        self.assertIn("&lt;unsafe&gt;&amp;", page)
        self.assertIn("cases/a%20b.png", page)
        self.assertNotIn("<unsafe>", page)

    def test_harness_error_is_reported_not_advisory(self):
        process, output = self.report([
            {"schema_version": 1, "suite": "snapshot", "status": "harness_error",
             "renderer_profile": {}, "cases": [], "error": "test host crashed"},
            completed("e2e", []),
        ])
        self.assertEqual(process.returncode, 0, process.stderr)
        summary = json.loads((output / "summary.json").read_text())
        self.assertEqual(summary["outcome"], "harness_error")
        self.assertFalse(summary["advisory"])
        self.assertEqual(summary["counts"]["errors"], 1)

    def test_incompatible_environment_is_not_a_visual_difference(self):
        process, output = self.report([
            completed("snapshot", [{"id": "settings", "status": "incompatible_environment"}]),
        ])
        self.assertEqual(process.returncode, 0, process.stderr)
        summary = json.loads((output / "summary.json").read_text())
        self.assertEqual(summary["outcome"], "environment_error")
        self.assertFalse(summary["advisory"])
        self.assertEqual(summary["counts"]["errors"], 1)

    def test_unsafe_artifact_path_is_rejected(self):
        process, output = self.report([
            completed("snapshot", [{"id": "settings", "status": "changed",
                                    "artifacts": {"diff": "../private.png"}}]),
        ])
        self.assertEqual(process.returncode, 2)
        self.assertIn("must stay under", process.stderr)
        self.assertFalse((output / "summary.json").exists())

    def test_duplicate_suite_is_rejected(self):
        process, _ = self.report([completed("snapshot", []), completed("snapshot", [])])
        self.assertEqual(process.returncode, 2)
        self.assertIn("one result per suite", process.stderr)

    def test_duplicate_json_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "result.json"
            source.write_text('{"schema_version":1,"schema_version":1,"suite":"snapshot","status":"completed","renderer_profile":{},"cases":[]}')
            process = subprocess.run([sys.executable, str(REPORTER), "--input", str(source),
                                      "--output", str(Path(temporary) / "report")],
                                     text=True, capture_output=True, check=False)
        self.assertEqual(process.returncode, 2)
        self.assertIn("duplicate JSON key", process.stderr)


if __name__ == "__main__":
    unittest.main()
