#!/usr/bin/env python3
"""Local tests do not compile, touch the user's caches, or post keyboard events."""
import os
from pathlib import Path
import tempfile
import unittest

from ci_cache_experiment import (MARKER, compile_counts, edit_source, restore_files,
                                 safe_file, snapshot_files)


class CacheExperimentTests(unittest.TestCase):
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
