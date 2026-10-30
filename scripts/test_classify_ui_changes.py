#!/usr/bin/env python3
"""Linux-compatible contract tests for scripts/classify_ui_changes.py."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLASSIFIER = ROOT / "scripts/classify_ui_changes.py"


class ClassifyUIChangesTests(unittest.TestCase):
    def classify(self, document):
        process = subprocess.run([sys.executable, str(CLASSIFIER)], input=json.dumps(document), text=True,
                                 capture_output=True, check=False)
        return process, json.loads(process.stdout) if process.stdout else None

    def test_added_ui_view_runs(self):
        process, result = self.classify({"schema_version": 1, "complete": True, "changes": [
            {"status": "added", "path": "native/MuesliNative/Sources/MuesliNativeApp/SettingsView.swift"}
        ]})
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(result["decision"], "run")
        self.assertEqual(result["matched_changes"][0]["categories"], ["ui"])

    def test_visual_test_source_runs(self):
        process, result = self.classify({"schema_version": 1, "complete": True, "changes": [
            {"status": "modified",
             "path": "native/MuesliNative/Sources/MuesliNativeApp/VisualTesting/VisualSnapshotCapture.swift"}
        ]})
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(result["decision"], "run")
        self.assertEqual(result["matched_changes"][0]["categories"], ["fixtures_and_baselines"])

    def test_deleted_cli_path_skips(self):
        process, result = self.classify({"schema_version": 1, "complete": True, "changes": [
            {"status": "deleted", "path": "native/MuesliNative/Sources/MuesliCLI/TranscribeCommand.swift"}
        ]})
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(result["decision"], "skip")
        self.assertEqual(result["unmatched_paths"], ["native/MuesliNative/Sources/MuesliCLI/TranscribeCommand.swift"])

    def test_rename_checks_both_paths(self):
        process, result = self.classify({"schema_version": 1, "complete": True, "changes": [
            {"status": "renamed", "old_path": "native/MuesliNative/Sources/MuesliNativeApp/OldView.swift",
             "path": "docs/old-view.md"}
        ]})
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(result["eligible"])
        self.assertEqual(result["matched_changes"][0]["paths"]["old_path"],
                         "native/MuesliNative/Sources/MuesliNativeApp/OldView.swift")

    def test_mixed_changes_do_not_suppress_ui_run(self):
        process, result = self.classify({"schema_version": 1, "complete": True, "changes": [
            {"status": "modified", "path": "README.md"},
            {"status": "modified", "path": "native/VisualTesting/Fixtures/v1/onboarding.json"}
        ]})
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(result["decision"], "run")
        self.assertEqual(result["unmatched_paths"], ["README.md"])

    def test_malformed_json_fails_closed(self):
        process = subprocess.run([sys.executable, str(CLASSIFIER)], input="{not json", text=True,
                                 capture_output=True, check=False)
        self.assertEqual(process.returncode, 2)
        self.assertIn("invalid JSON", process.stderr)

    def test_incomplete_diff_fails_closed(self):
        process, result = self.classify({"schema_version": 1, "complete": False, "changes": []})
        self.assertEqual(process.returncode, 2)
        self.assertIsNone(result)
        self.assertIn("complete: true", process.stderr)

    def test_extra_record_field_fails_closed(self):
        process, result = self.classify({"schema_version": 1, "complete": True, "changes": [
            {"status": "added", "path": "README.md", "old_path": "README.old"}
        ]})
        self.assertEqual(process.returncode, 2)
        self.assertIsNone(result)
        self.assertIn("incompatible", process.stderr)

    def test_duplicate_json_key_fails_closed(self):
        process = subprocess.run([sys.executable, str(CLASSIFIER)],
                                 input='{"schema_version": 1, "schema_version": 1, "complete": true, "changes": []}',
                                 text=True, capture_output=True, check=False)
        self.assertEqual(process.returncode, 2)
        self.assertIn("duplicate JSON key", process.stderr)


if __name__ == "__main__":
    unittest.main()
