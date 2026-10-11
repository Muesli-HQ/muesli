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
PROFILE = {
    "architecture": "arm64", "macos_version": "26.0", "macos_build": "TEST", "xcode_version": "26.6",
    "xcode_build": "TEST", "display": {"display": "test"}, "scale": 2, "color_space": "sRGB",
    "locale": "en_US", "calendar": "gregorian", "time_zone": "UTC", "appearance": "Dark",
}
PROVENANCE = {"root": "/trusted/baselines", "revision": "a" * 40, "baseline_id": "test-profile"}


def completed(suite, cases, expected_cases=None):
    return {"schema_version": 1, "suite": suite, "status": "completed", "renderer_profile": PROFILE,
            "baseline_provenance": PROVENANCE, "expected_cases": expected_cases or [case["id"] for case in cases],
            "cases": cases}


def case(case_id, status="changed", artifacts=None):
    if artifacts is None:
        artifacts = {"actual": f"cases/{case_id}/actual.png"}
        if status in {"matched", "changed"}:
            artifacts["expected"] = f"cases/{case_id}/expected.png"
        if status == "changed":
            artifacts["diff"] = f"cases/{case_id}/diff.png"
    return {"id": case_id, "status": status, "artifacts": artifacts}


class UIRenderingReportTests(unittest.TestCase):
    def report(self, documents, expected_profile=None, expected_cases=None, baseline_root=None,
               baseline_revision=None, baseline_id=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        output = root / "report"
        for document in documents:
            for item in document.get("cases", []):
                for artifact in item.get("artifacts", {}).values():
                    path = output / artifact
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b"png")
        inputs = []
        for index, document in enumerate(documents):
            path = root / f"{index}.json"
            path.write_text(json.dumps(document))
            inputs.extend(["--input", str(path)])
        command = [sys.executable, str(REPORTER), *inputs, "--output", str(output)]
        if expected_profile:
            path = root / "profile.json"
            path.write_text(json.dumps(expected_profile))
            command += ["--expected-renderer-profile", str(path)]
        if expected_cases:
            path = root / "cases.json"
            path.write_text(json.dumps(expected_cases))
            command += ["--expected-cases", str(path)]
        if baseline_root:
            command += ["--trusted-baseline-root", str(baseline_root),
                        "--trusted-baseline-revision", baseline_revision,
                        "--trusted-baseline-id", baseline_id]
        process = subprocess.run(command, text=True, capture_output=True, check=False)
        return process, output

    def test_image_differences_are_advisory(self):
        process, output = self.report([completed("snapshot", [case("settings-dark")]),
                                       completed("e2e", [case("first-launch", "missing_baseline")])])
        self.assertEqual(process.returncode, 0, process.stderr)
        summary = json.loads((output / "summary.json").read_text())
        self.assertEqual(summary["outcome"], "advisory")
        self.assertTrue(summary["advisory"])
        self.assertEqual(summary["counts"]["changed"], 1)
        self.assertEqual(summary["counts"]["missing_baseline"], 1)
        self.assertEqual(summary["baseline_provenance"], [PROVENANCE, PROVENANCE])

    def test_completed_result_requires_both_suites_and_cases(self):
        process, _ = self.report([completed("snapshot", [])])
        self.assertEqual(process.returncode, 2)
        self.assertIn("non-empty", process.stderr)
        process, _ = self.report([completed("snapshot", [case("a")])])
        self.assertEqual(process.returncode, 2)
        self.assertIn("snapshot and one e2e", process.stderr)

    def test_completed_result_rejects_incomplete_renderer_profile(self):
        bad = completed("snapshot", [case("a")])
        bad["renderer_profile"] = {"architecture": "arm64"}
        process, _ = self.report([bad, completed("e2e", [case("b")])])
        self.assertEqual(process.returncode, 2)
        self.assertIn("renderer_profile is incomplete", process.stderr)

    def test_expected_artifact_must_exist(self):
        document = completed("snapshot", [case("a", "changed", {
            "actual": "cases/a/actual.png", "expected": "cases/a/expected.png", "diff": "cases/a/diff.png",
        })])
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        output = root / "report"
        (output / "cases/a").mkdir(parents=True)
        (output / "cases/a/actual.png").write_bytes(b"png")
        source = root / "result.json"
        source.write_text(json.dumps(document))
        e2e = root / "e2e.json"
        e2e.write_text(json.dumps(completed("e2e", [case("b")])))
        process = subprocess.run([sys.executable, str(REPORTER), "--input", str(source), "--input", str(e2e),
                                  "--output", str(output)], text=True, capture_output=True, check=False)
        self.assertEqual(process.returncode, 2)
        self.assertIn("existing report artifact", process.stderr)

    def test_runner_contract_must_match_suite_results(self):
        contract = {"schema_version": 1, "suites": {"snapshot": ["a"], "e2e": ["b"]}}
        with tempfile.TemporaryDirectory() as temporary:
            trusted = Path(temporary) / "trusted"
            trusted.mkdir()
            documents = [completed("snapshot", [case("a")]), completed("e2e", [case("wrong")])]
            for document in documents:
                document["baseline_provenance"] = {**PROVENANCE, "root": str(trusted.resolve())}
            process, _ = self.report(documents, expected_profile=PROFILE, expected_cases=contract,
                                     baseline_root=trusted, baseline_revision="a" * 40,
                                     baseline_id="test-profile")
        self.assertEqual(process.returncode, 2)
        self.assertIn("expected_cases does not match", process.stderr)

    def test_changed_case_requires_complete_evidence(self):
        incomplete = case("a", "changed", {
            "actual": "cases/a/actual.png", "expected": "cases/a/expected.png",
        })
        process, _ = self.report([
            completed("snapshot", [incomplete]),
            completed("e2e", [case("b", "missing_baseline")]),
        ])
        self.assertEqual(process.returncode, 2)
        self.assertIn("needs exactly", process.stderr)

    def test_trusted_baseline_id_must_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            trusted = Path(temporary) / "trusted"
            trusted.mkdir()
            documents = [completed("snapshot", [case("a")]), completed("e2e", [case("b")])]
            for document in documents:
                document["baseline_provenance"] = {**PROVENANCE, "root": str(trusted.resolve())}
            process, _ = self.report(documents, baseline_root=trusted, baseline_revision="a" * 40,
                                     baseline_id="different-profile")
        self.assertEqual(process.returncode, 2)
        self.assertIn("baseline_provenance does not match", process.stderr)

    def test_harness_error_is_reported_not_advisory(self):
        error = {"schema_version": 1, "suite": "snapshot", "status": "harness_error", "renderer_profile": {},
                 "baseline_provenance": {}, "expected_cases": [], "cases": [], "error": "test host crashed"}
        process, output = self.report([error, completed("e2e", [case("b")])])
        self.assertEqual(process.returncode, 0, process.stderr)
        summary = json.loads((output / "summary.json").read_text())
        self.assertEqual(summary["outcome"], "harness_error")
        self.assertFalse(summary["advisory"])

    def test_duplicate_json_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "result.json"
            source.write_text('{"schema_version":1,"schema_version":1,"suite":"snapshot"}')
            process = subprocess.run([sys.executable, str(REPORTER), "--input", str(source), "--output", str(Path(temporary) / "report")], text=True, capture_output=True, check=False)
        self.assertEqual(process.returncode, 2)
        self.assertIn("duplicate JSON key", process.stderr)


if __name__ == "__main__":
    unittest.main()
