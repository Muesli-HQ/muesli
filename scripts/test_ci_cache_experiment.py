#!/usr/bin/env python3
"""Local tests do not compile, touch the user's caches, or post keyboard events."""
import os
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from ci_cache_experiment import (MARKER, compile_counts, edit_source, restore_files,
                                 safe_file, snapshot_files, mark_phase, phase_durations, report)


class CacheExperimentTests(unittest.TestCase):
    def test_phase_timer_tracks_transfer_overhead(self):
        with tempfile.TemporaryDirectory() as directory:
            results = Path(directory)
            with patch("ci_cache_experiment.time.monotonic", side_effect=[10, 52]):
                mark_phase("begin", "cache-restore", results)
                mark_phase("end", "cache-restore", results)
            timings = json.loads((results / "timings.json").read_text())
            self.assertEqual(phase_durations(timings), {"cache-restore": 42})
            with self.assertRaises(ValueError):
                mark_phase("end", "cache-restore", results)

    def test_incomplete_phases_are_not_zero(self):
        self.assertEqual(phase_durations({"cache-restore": {"begin": 10}}),
                         {"cache-restore": None})
        with self.assertRaises(ValueError):
            phase_durations({"cache-restore": {"begin": 20, "end": 10}})

    def test_rejects_unknown_or_out_of_order_markers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for action, phase in (("begin", "bogus"), ("end", "pipeline")):
                with self.assertRaises(ValueError):
                    mark_phase(action, phase, root)

    def test_report_persists_overhead_without_double_counting(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            results = root / "ci-cache-results"
            results.mkdir()
            (results / "measurement.json").write_text(json.dumps({
                "scenario": "raw-edited", "build_seconds": 260, "exit_code": 0,
                "compile_progress_counts": {"app": 1}, "edited_binary_verified": True,
            }))
            (results / "timings.json").write_text(json.dumps({
                "pipeline": {"begin": 10, "end": 330},
                "cache-restore": {"begin": 10, "end": 52},
            }))
            original = Path.cwd()
            try:
                os.chdir(root)
                with patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(root / "summary.md")}):
                    report()
            finally:
                os.chdir(original)
            data = json.loads((results / "measurement.json").read_text())
            self.assertEqual(data["phase_seconds"], {"pipeline": 320, "cache-restore": 42})
            self.assertTrue(data["edited_binary_verified"])
            self.assertIn("do not sum", (root / "summary.md").read_text())

    def test_restores_only_identical_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            same, changed = root / "same.swift", root / "changed.swift"
            for path in (same, changed):
                path.write_text("original")
                os.utime(path, ns=(1_000_000_000, 1_000_000_000))
            records = snapshot_files(root, [same, changed])
            os.utime(same, ns=(2_000_000_000, 2_000_000_000))
            changed.write_text("modified")
            modified_time = changed.stat().st_mtime_ns
            self.assertEqual(restore_files(root, records), 1)
            self.assertEqual(same.stat().st_mtime_ns, 1_000_000_000)
            self.assertEqual(changed.stat().st_mtime_ns, modified_time)
            self.assertEqual(changed.read_text(), "modified")

    def test_missing_files_stay_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(restore_files(Path(directory), {"missing": {}}), 0)

    def test_rejects_path_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in ("../escape", "/tmp/escape"):
                with self.assertRaises(ValueError):
                    safe_file(root, path)

    def test_skips_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "source"
            target.write_text("data")
            (root / "link").symlink_to(target)
            self.assertIsNone(safe_file(root, "link"))

    def test_probe_changes_real_source_and_rejects_repeat(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "AboutView.swift"
            path.write_text('Text("About")')
            edit_source(path)
            self.assertIn(MARKER, path.read_text())
            with self.assertRaises(RuntimeError):
                edit_source(path)

    def test_progress_counts(self):
        self.assertEqual(compile_counts([
            "[1/5] Compiling MuesliNativeApp AboutView.swift",
            "[2/5] Compiling binary.cpp",
            "[3/5] Compiling SwiftSyntax AbsolutePosition.swift",
            "[4/5] Compiling FluidAudio Config.swift",
            "[5/5] Linking MuesliNativeApp",
        ]), {"app": 1, "c_family": 1, "swift_syntax": 1, "other": 1})


if __name__ == "__main__":
    unittest.main()
