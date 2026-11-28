#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path

from ci_test_coverage_audit import compare, expected_tests, recorded_tests


class CoverageTests(unittest.TestCase):
    def test_inventory_and_legacy_ownership(self):
        ids = ["App.One/shared()", "Gemma.Two/shared()", "App.Legacy/existing()"]
        owners = {"App.One": "core", "Gemma.Two": "dictation-transcription"}
        self.assertEqual(expected_tests(ids, owners, {"App.Legacy"}, "core"), {ids[0]})
        with self.assertRaises(ValueError):
            expected_tests(ids + ["App.New/implicit()"], owners, {"App.Legacy"}, "core")
        with self.assertRaises(ValueError):
            expected_tests(ids, owners, {"App.One", "App.Legacy"}, "core")

    def test_missing_method_within_a_partly_executed_suite(self):
        with self.assertRaises(ValueError):
            compare({"App.One/first()", "App.One/second()"}, {"App.One/first()"}, "core")

    def test_xunit_counts_skips_and_rejects_duplicate_methods(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "reports.xml"
            path.write_text('<testsuite><testcase classname="App.One" name="f(_:)"><skipped/>'
                            '</testcase><testcase classname="Gemma.Two" name="f(_:)"/></testsuite>')
            self.assertEqual(recorded_tests([path]), {"App.One/f(_:)": "skipped", "Gemma.Two/f(_:)": "passed"})
            with self.assertRaises(ValueError):
                recorded_tests([path, path])


if __name__ == "__main__":
    unittest.main()
