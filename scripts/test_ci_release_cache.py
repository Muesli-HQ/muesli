#!/usr/bin/env python3
"""Portable regression checks for the release cache rollout (no Swift required)."""

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import ci_release_cache as cache


class ReleaseCacheTests(unittest.TestCase):
    def test_exact_key_and_narrow_fallback(self):
        key, prefix = cache.cache_keys({"swift": "6.3", "lockfile": "abc"}, "a" * 40)
        self.assertEqual(key, prefix + "a" * 40)
        self.assertRegex(prefix, r"^ci-release-v1-[0-9a-f]{64}-$")
        newer, same_prefix = cache.cache_keys({"lockfile": "abc", "swift": "6.3"}, "b" * 40)
        self.assertEqual(same_prefix, prefix)
        self.assertNotEqual(newer, key)

    def test_each_compatibility_fact_invalidates_fallback(self):
        facts = dict.fromkeys(("architecture", "os", "image", "xcode", "swift", "sdk",
                              "sdk_path", "workspace", "scratch", "command", "manifest",
                              "lockfile", "helper"), "original")
        _, original = cache.cache_keys(facts, "a" * 40)
        for field in facts:
            with self.subTest(field=field):
                _, changed = cache.cache_keys({**facts, field: "changed"}, "a" * 40)
                self.assertNotEqual(original, changed)

    def test_malformed_revisions_rejected(self):
        for revision in ("", "abc", "main", "a" * 41, "A" * 40, "a" * 40 + "\n"):
            with self.subTest(revision=revision), self.assertRaises(ValueError):
                cache.cache_keys({}, revision)

    def test_build_is_locked_optimized_product_and_isolated(self):
        scratch = cache.scratch_path()
        self.assertEqual(scratch.relative_to(Path.home()).as_posix(),
                         "Library/Caches/muesli-spm/ci/release")
        self.assertEqual(cache.build_command(scratch), [
            "swift", "build", "--package-path", "native/MuesliNative", "--scratch-path",
            str(scratch), "-c", "release", "--product", "MuesliNativeApp",
            "--force-resolved-versions"])

    def test_timing_and_incomplete_phase(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(cache.time, "monotonic", side_effect=[1, 2, 4]):
                cache.mark("begin", "pipeline", root)
                cache.mark("begin", "restore", root)
                cache.mark("end", "restore", root)
            data = json.loads((root / "timings.json").read_text())
            self.assertEqual(cache.durations(data), {"pipeline": None, "restore": 2})
            with self.assertRaises(ValueError):
                cache.mark("end", "restore", root)
            with self.assertRaises(ValueError):
                cache.mark("end", "save", root)

    def test_report_records_fallback_hit_and_failed_save(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "timings.json").write_text('{"build":{"begin":1,"end":5}}')
            (root / "build.json").write_text('{"exit_code":0}')
            env = {"GITHUB_STEP_SUMMARY": str(root / "summary"), "GITHUB_EVENT_NAME": "pull_request",
                   "CACHE_MATCHED_KEY": "compatible-older-main", "CACHE_EXACT_HIT": "false",
                   "CACHE_RESTORE_OUTCOME": "success", "CACHE_SAVE_OUTCOME": "failure"}
            with patch.object(cache, "RESULTS", root), patch.dict(os.environ, env):
                cache.report()
            data = json.loads((root / "measurement.json").read_text())
            self.assertEqual(data["cache_matched_key"], "compatible-older-main")
            self.assertEqual(data["save_outcome"], "failure")
            self.assertEqual(data["phase_seconds"]["build"], 4)

    def test_failed_compilation_still_fails_job(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = Mock(stdout=iter(["compiler error\n"]))
            process.wait.return_value = 1
            with patch.object(cache, "RESULTS", root), patch.object(cache, "mark") as mark, \
                    patch.object(cache.subprocess, "Popen", return_value=process) as popen:
                with self.assertRaises(SystemExit) as exited:
                    cache.build()
            self.assertEqual(exited.exception.code, 1)
            self.assertEqual(json.loads((root / "build.json").read_text())["exit_code"], 1)
            popen.assert_called_once()
            self.assertEqual(mark.call_count, 2)

    def test_prepare_fingerprints_real_build_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = {"CACHE_REVISION": "a" * 40, "GITHUB_OUTPUT": str(root / "output")}
            with patch.object(cache, "RESULTS", root), \
                    patch.object(cache, "scratch_path", return_value=root / "scratch"), \
                    patch.object(cache.subprocess, "check_output", return_value="toolchain"), \
                    patch.object(cache, "digest", return_value="digest"), \
                    patch.dict(os.environ, env), patch("builtins.print"):
                cache.prepare()
            facts = json.loads((root / "environment.json").read_text())
            self.assertEqual(set(facts), {"architecture", "os", "image", "xcode", "swift",
                                         "sdk", "sdk_path", "workspace", "scratch", "command",
                                         "manifest", "lockfile", "helper"})
            key, prefix = cache.cache_keys(facts, "a" * 40)
            self.assertIn(f"key={key}\nprefix={prefix}\n", (root / "output").read_text())

    def test_workflow_trust_policy_and_unconditional_build(self):
        # Keep this dependency-free for the Linux classifier job. Match complete
        # step blocks rather than merely checking that a condition appears somewhere.
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/ci.yml").read_text()
        job = workflow.split("  build_release:\n", 1)[1].split("\n  test_shards:", 1)[0]
        steps = job.split("      - name: ")[1:]
        restore = next(step for step in steps if "uses: actions/cache/restore@v4" in step)
        save = next(step for step in steps if "uses: actions/cache/save@v4" in step)
        build = next(step for step in steps if step.startswith("Build (release)\n"))
        self.assertIn("if: github.event_name == 'pull_request'\n", restore)
        self.assertIn("if: github.event_name == 'push' && github.ref == 'refs/heads/main'\n", save)
        self.assertIn("continue-on-error: true", save)
        self.assertNotIn("if:", build)
        self.assertIn("python3 scripts/ci_release_cache.py build", build)
        self.assertEqual(job.count("uses: actions/cache/"), 2)
        for step in (restore, save):
            self.assertIn("path: ${{ steps.release-cache.outputs.scratch }}\n", step)
        self.assertIn("restore-keys: ${{ steps.release-cache.outputs.prefix }}\n", restore)
        self.assertIn("CACHE_REVISION: ${{ github.event.pull_request.base.sha || github.sha }}", job)


if __name__ == "__main__":
    unittest.main()
