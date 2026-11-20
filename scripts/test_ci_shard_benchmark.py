#!/usr/bin/env python3
"""Local checks for the shard benchmark harness. No Swift build, no network, no caches."""
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_shard_benchmark as bench  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/ci-shard-benchmark.yml"
SENTINEL_ID = "MuesliTests.WordCountTests/ciShardBenchmarkSentinel()"
PRODUCER = bench.PRODUCER


def junit(*cases):
    body = "".join(f'<testcase classname="{c}" name="{n}">{extra}</testcase>' for c, n, extra in cases)
    return f"<testsuites><testsuite>{body}</testsuite></testsuites>"


def shard_data(results, exit_code=0):
    return {"exit_code": exit_code, "script_seconds": 10, "prepare_seconds": 5,
            "test_seconds": 4, "test_invocations": 1, "results": results}


def scenarios(overrides=None):
    base = {"core": {SENTINEL_ID: ("passed",), "M.A/a()": ("passed",)},
            "dictation-transcription": {"M.B/b()": ("skipped",)},
            "meetings": {"M.C/c()": ("passed",)}}
    data = {name: {"shards": {s: shard_data(dict(r)) for s, r in base.items()}} for name in bench.SCENARIOS}
    for (name, shard), results in (overrides or {}).items():
        data[name]["shards"][shard]["results"] = results
    return data


class ResultTests(unittest.TestCase):
    def test_parse_junit_records_pass_fail_skip_and_ignores_empty_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path, empty = Path(directory) / "a.xml", Path(directory) / "b.xml"
            path.write_text(junit(("M.S", "ok()", ""), ("M.S", "bad()", "<failure message='x'/>"),
                                  ("M.S", "skip()", "<skipped/>"), ("M.S", "err()", "<error/>")))
            empty.write_text("")
            self.assertEqual(bench.parse_junit([path, empty]), {
                "M.S/ok()": ("passed",), "M.S/bad()": ("failed",),
                "M.S/skip()": ("skipped",), "M.S/err()": ("failed",)})

    def test_identical_scenarios_pass(self):
        rows, errors = bench.compare_results(scenarios())
        self.assertEqual(errors, [])
        self.assertEqual(len(rows), 12)
        self.assertEqual(sum(r["skipped"] for r in rows), 4)

    def test_detects_missing_extra_and_changed_including_skips(self):
        _, errors = bench.compare_results(scenarios({
            ("serial-reuse", "dictation-transcription"): {"M.B/b()": ("passed",)},
            ("cached-parallel", "meetings"): {"M.C/c()": ("passed",), "M.D/d()": ("passed",)},
            ("cached-parallel", "core"): {SENTINEL_ID: ("passed",)},
            ("artifact-parallel", "meetings"): {},
        }))
        text = "\n".join(errors)
        self.assertIn("serial-reuse vs cold-parallel: 1 changed status", text)
        self.assertIn("cached-parallel vs cold-parallel: 1 missing", text)
        self.assertIn("cached-parallel vs cold-parallel: 1 extra", text)
        self.assertIn("artifact-parallel vs cold-parallel: 1 missing", text)

    def test_sentinel_must_execute_and_pass_in_core_once(self):
        for results in ({}, {SENTINEL_ID: ("skipped",)}, {SENTINEL_ID: ("passed", "passed")}):
            _, errors = bench.compare_results(scenarios({("serial-reuse", "core"): results}))
            self.assertTrue(any("serial-reuse: sentinel" in e for e in errors), results)
        data = scenarios({("cached-parallel", "core"): {}})
        data["cached-parallel"]["shards"]["meetings"]["results"][SENTINEL_ID] = ("passed",)
        _, errors = bench.compare_results(data)
        self.assertTrue(any("cached-parallel: sentinel" in e for e in errors))

    def test_failed_or_unmeasured_shards_invalidate_the_run(self):
        data = scenarios()
        data["cold-parallel"]["shards"]["core"]["exit_code"] = 1
        data["serial-reuse"]["shards"]["meetings"]["test_invocations"] = 0
        del data["cached-parallel"]["shards"]["meetings"]
        data["artifact-parallel"]["shards"]["core"]["exit_code"] = 1
        errors = "\n".join(bench.compare_results(data)[1])
        self.assertIn("cold-parallel/core: shard script exited 1", errors)
        self.assertIn("serial-reuse/meetings: expected one executed swift test", errors)
        self.assertIn("cached-parallel: no meetings results", errors)
        self.assertIn("artifact-parallel/core: shard script exited 1", errors)


def job(name, created, started, completed, steps=(), conclusion="success"):
    return {"name": name, "created_at": created, "started_at": started, "completed_at": completed,
            "conclusion": conclusion, "steps": [{"name": n, "conclusion": "success", "started_at": s,
                                                 "completed_at": e} for n, s, e in steps]}


def t(minute, second=0):
    minute, second = minute + second // 60, second % 60
    return f"2026-11-20T{10 + minute // 60:02d}:{minute % 60:02d}:{second:02d}Z"


class TimelineTests(unittest.TestCase):
    def jobs(self):
        restore = lambda m: [(bench.RESTORE_STEP, t(m), t(m, 40))]
        transfer = lambda m, s: [(bench.DOWNLOAD_STEP, t(m, s), t(m, s + 20)),
                                 (bench.EXTRACT_STEP, t(m, s + 20), t(m, s + 50))]
        return [
            job("guard", t(0), t(0), t(0, 15)),
            job("cold-parallel (core)", t(1), t(2), t(20)),
            job("cold-parallel (dictation-transcription)", t(1), t(3), t(25, 30)),
            job("cold-parallel (meetings)", t(1), t(2), t(22)),
            job("serial-reuse", t(1), t(26), t(40)),
            job("seed", t(0), t(0, 15), t(1), [(bench.SAVE_STEP, t(0, 30), t(1))]),
            *(job(f"cached-parallel ({s})", t(1), t(41), t(49), restore(42)) for s in bench.SHARDS),
            job("report", t(31), t(31), t(32)),
            # Appended so index-based edits in other tests stay stable.
            job("artifact-build", t(1), t(50), t(58),
                [(bench.ARCHIVE_STEP, t(55), t(56)), (bench.UPLOAD_STEP, t(56), t(57, 30))]),
            job("artifact-parallel (core)", t(1), t(59), t(66), transfer(59, 0)),
            job("artifact-parallel (dictation-transcription)", t(1), t(60), t(67), transfer(60, 0)),
            job("artifact-parallel (meetings)", t(1), t(59, 30), t(65), transfer(59, 30)),
        ]

    def test_aggregation_definitions(self):
        summary, errors = bench.summarize_jobs(self.jobs())
        self.assertEqual(errors, [])
        cold = summary["cold-parallel"]
        self.assertEqual(cold["queue_to_completion_seconds"], 24.5 * 60)  # seed done -> last completed
        self.assertEqual(cold["max_queue_seconds"], 120)
        self.assertEqual(cold["queue_seconds_total"], 60 + 120 + 60)
        self.assertEqual(cold["longest_job_seconds"], 22.5 * 60)
        self.assertEqual(cold["runner_minutes"], round((18 + 22.5 + 20), 2))
        self.assertEqual(cold["rounded_job_minutes"], 18 + 23 + 20)  # each job rounds up
        self.assertEqual(summary["serial-reuse"]["rounded_job_minutes"], 14)
        cached = summary["cached-parallel"]
        self.assertEqual((cached["transfer_steps"], cached["transfer_seconds_total"], cached["transfer_seconds_max"]),
                         (3, 120, 40))
        self.assertEqual(cached["queue_seconds_total"], 3 * 60)
        self.assertEqual(summary["seed"]["transfer_seconds_total"], 30)
        self.assertNotIn("guard", summary)

    def test_artifact_layout_includes_producer_queue_and_runtime(self):
        summary, errors = bench.summarize_jobs(self.jobs())
        self.assertEqual(errors, [])
        layout = summary["artifact-parallel"]
        build, shards = layout["phases"]["build"], layout["phases"]["shards"]
        # Producer queues from cached-parallel completion; shards queue from producer completion.
        self.assertIs(build, summary[PRODUCER])
        self.assertEqual((build["max_queue_seconds"], build["runner_minutes"]), (60, 8))
        self.assertEqual((build["transfer_steps"], build["transfer_seconds_total"]), (2, 150))
        self.assertEqual(shards["queue_to_completion_seconds"], 9 * 60)
        self.assertEqual(shards["max_queue_seconds"], 120)
        self.assertEqual(layout["jobs"], 4)
        self.assertEqual(layout["queue_to_completion_seconds"], 18 * 60)  # cached done -> last shard done
        self.assertEqual(layout["max_queue_seconds"], 120)
        self.assertEqual(layout["queue_seconds_total"], 60 + 60 + 120 + 90)
        self.assertEqual(layout["longest_job_seconds"], 8 * 60)
        self.assertEqual(layout["runner_minutes"], 8 + 7 + 7 + 5.5)
        self.assertEqual(layout["rounded_job_minutes"], 8 + 7 + 7 + 6)
        self.assertEqual((layout["transfer_steps"], layout["transfer_seconds_total"], layout["transfer_seconds_max"]),
                         (8, 150 + 3 * 50, 90))

    def test_missing_incomplete_or_failed_jobs_are_errors(self):
        jobs = self.jobs()
        jobs[1]["completed_at"] = None
        jobs[4]["conclusion"] = "failure"
        jobs[6]["steps"] = []
        summary, errors = bench.summarize_jobs(jobs)
        text = "\n".join(errors)
        self.assertIn("cold-parallel: expected 3 completed", text)
        self.assertNotIn("queue_to_completion_seconds", summary["cold-parallel"])
        self.assertIn("serial-reuse: job conclusions", text)
        self.assertIn(f"'{bench.RESTORE_STEP}'", text)

    def test_artifact_phases_require_transfer_steps_and_complete_jobs(self):
        jobs = self.jobs()
        producer = next(j for j in jobs if j["name"] == PRODUCER)
        producer["steps"] = producer["steps"][:1]
        next(j for j in jobs if j["name"] == "artifact-parallel (meetings)")["completed_at"] = None
        summary, errors = bench.summarize_jobs(jobs)
        text = "\n".join(errors)
        self.assertIn(f"artifact-build: every job must record successful '{bench.ARCHIVE_STEP}', "
                      f"'{bench.UPLOAD_STEP}'", text)
        self.assertIn("artifact-parallel: expected 3 completed", text)
        self.assertNotIn("queue_to_completion_seconds", summary["artifact-parallel"])
        self.assertIn("queue_to_completion_seconds", summary["artifact-parallel"]["phases"]["build"])

    def test_artifact_shards_starting_before_producer_completes_is_an_error(self):
        jobs = self.jobs()
        next(j for j in jobs if j["name"] == "artifact-parallel (core)")["started_at"] = t(57)
        _, errors = bench.summarize_jobs(jobs)
        self.assertIn("artifact-parallel: job started before its prerequisite completed", errors)


class OrchestrationTests(unittest.TestCase):
    def test_serial_reuse_builds_once_and_setup_jobs_prepare_only(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"RUNNER_TEMP": directory}), patch.object(
            bench, "run_shard_script", return_value={"exit_code": 0}
        ) as invoke:
            self.assertEqual(bench.run("serial-reuse", list(bench.SHARDS)), 0)
            self.assertEqual([call.args[0] for call in invoke.call_args_list], list(bench.SHARDS))
            self.assertEqual([call.kwargs["mode"] for call in invoke.call_args_list],
                             [None, "--reuse-build", "--reuse-build"])
            for scenario in bench.SETUP:
                bench.prepare_build(scenario)
                self.assertEqual((invoke.call_args.args[0], invoke.call_args.kwargs["mode"]),
                                 ("core", "--prepare-only"))
                written = json.loads((Path(directory) / "ci-shard-bench/shards.json").read_text())
                self.assertEqual(written["scenario"], scenario)

    def test_parallel_layouts_run_one_shard_and_only_artifact_reuses(self):
        for scenario, mode in (("cold-parallel", None), ("cached-parallel", None),
                               ("artifact-parallel", "--reuse-build")):
            with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"RUNNER_TEMP": directory}), \
                    patch.object(bench, "run_shard_script", return_value={"exit_code": 0}) as invoke:
                self.assertEqual(bench.run(scenario, ["meetings"]), 0)
                self.assertEqual(invoke.call_args.kwargs["mode"], mode)
                with self.assertRaises(SystemExit):
                    bench.run(scenario, ["core", "meetings"])


class ArtifactTransferTests(unittest.TestCase):
    ARTIFACT = "shard-bench-scratch-123-1"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name).resolve()
        self.producer, self.consumer = root / "producer", root / "consumer"
        self.package = root / "work/native/MuesliNative"
        self.scratch = self.package / ".build"
        self.out = root / "upload"
        self.env = patch.dict(os.environ, {"CI_SHARD_BENCH_RESULTS": str(self.producer)})
        self.env.start()
        self.package.mkdir(parents=True)
        (self.package / "Package.swift").write_text("// manifest\n")
        debug = self.scratch / "arm64-apple-macosx/debug"
        debug.mkdir(parents=True)
        (debug / "muesli-test.metallib").write_bytes(b"metal" * 100)
        (debug / "MuesliPackageTests.xctest").write_bytes(b"tests")
        (debug / "MuesliPackageTests.xctest").chmod(0o755)
        (self.scratch / "debug").symlink_to("arm64-apple-macosx/debug")
        (self.scratch / "workspace-state.json").write_text(json.dumps({"path": str(self.package)}))
        self.environment(PRODUCER, self.producer)

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def environment(self, scenario, results, key="key-1"):
        bench.write_json(results / "environment.json", {
            "scenario": scenario, "cache_key": key, "facts": {"scratch": str(self.scratch.resolve())}})

    def archive(self):
        return bench.archive_scratch(self.out, self.ARTIFACT, self.scratch)

    def consume(self, key="key-1"):
        self.environment("artifact-parallel", self.consumer, key)
        os.environ["CI_SHARD_BENCH_RESULTS"] = str(self.consumer)

    def move_scratch_away(self):
        self.scratch.rename(self.package / "elsewhere")

    def test_round_trip_restores_exact_tree_at_the_same_path(self):
        manifest = self.archive()
        self.assertEqual(json.loads((self.producer / "archive.json").read_text()), manifest)
        self.assertEqual(json.loads((self.out / bench.MANIFEST_NAME).read_text()), manifest)
        before = bench.tree_digest(self.scratch)
        self.assertEqual((manifest["tree_sha256"], manifest["entries"]), (before["tree_sha256"], 6))
        self.move_scratch_away()
        self.consume()
        record = bench.restore_scratch(self.out, self.scratch)
        self.assertEqual(bench.tree_digest(self.scratch), before)
        self.assertTrue((self.scratch / "debug").is_symlink())
        self.assertEqual((self.scratch / "debug/muesli-test.metallib").read_bytes(), b"metal" * 100)
        self.assertTrue(os.access(self.scratch / "debug/MuesliPackageTests.xctest", os.X_OK))
        self.assertFalse((self.out / bench.ARCHIVE_NAME).exists())
        self.assertEqual({k: record[k] for k in bench.ARCHIVE_FIELDS},
                         {k: manifest[k] for k in bench.ARCHIVE_FIELDS})
        self.assertEqual(json.loads((self.consumer / "restore.json").read_text()), record)

    def test_tree_digest_detects_size_mode_and_link_changes(self):
        before = bench.tree_digest(self.scratch)
        metallib = self.scratch / "arm64-apple-macosx/debug/muesli-test.metallib"
        metallib.write_bytes(b"x")
        self.assertNotEqual(bench.tree_digest(self.scratch), before)
        metallib.write_bytes(b"metal" * 100)
        self.assertEqual(bench.tree_digest(self.scratch), before)
        metallib.chmod(0o600)
        self.assertNotEqual(bench.tree_digest(self.scratch), before)

    def test_producer_rejects_bad_names_wrong_scenario_and_nonempty_output(self):
        with self.assertRaises(SystemExit):
            bench.archive_scratch(self.out, "ci-shard-bench-scratch-1-1", self.scratch)  # Report would download it.
        self.out.mkdir()
        (self.out / "stale").write_text("x")
        with self.assertRaisesRegex(SystemExit, "empty"):
            self.archive()
        self.environment("cached-parallel", self.producer)
        with self.assertRaises(SystemExit):
            bench.archive_scratch(self.out.parent / "fresh", self.ARTIFACT, self.scratch)

    def test_consumer_rejects_identity_mismatch_before_extracting(self):
        self.archive()
        self.move_scratch_away()
        self.consume(key="key-2")
        with self.assertRaisesRegex(SystemExit, "cache_key"):
            bench.restore_scratch(self.out, self.scratch)
        self.assertFalse(self.scratch.exists())
        self.consume()
        other = self.package / "other/.build"
        other.parent.mkdir()
        with self.assertRaisesRegex(SystemExit, "scratch"):
            bench.restore_scratch(self.out, other)
        self.assertFalse(other.exists())

    def test_consumer_rejects_tampered_archive_and_existing_scratch(self):
        self.archive()
        self.consume()
        with self.assertRaisesRegex(SystemExit, "fresh runner"):
            bench.restore_scratch(self.out, self.scratch)
        self.move_scratch_away()
        with (self.out / bench.ARCHIVE_NAME).open("ab") as stream:
            stream.write(b"\0")
        with self.assertRaisesRegex(SystemExit, "sha256|bytes"):
            bench.restore_scratch(self.out, self.scratch)
        self.assertFalse(self.scratch.exists())

    def test_report_requires_every_consumer_to_restore_the_producer_archive(self):
        archive = dict.fromkeys(bench.ARCHIVE_FIELDS, "x")
        good = {PRODUCER: {"shards": {"core": {"exit_code": 0}}, "archives": [archive]},
                "artifact-parallel": {"restores": [dict(archive) for _ in range(3)]}}
        self.assertEqual(bench.check_artifact_transfer(good), [])
        good["artifact-parallel"]["restores"][1]["sha256"] = "y"
        good["artifact-parallel"]["restores"].pop()
        text = "\n".join(bench.check_artifact_transfer(good))
        self.assertIn("expected 3 verified restores, found 2", text)
        self.assertIn("differs from the producer's in ['sha256']", text)
        failed = {PRODUCER: {"shards": {"core": {"exit_code": 1}}, "archives": []},
                  "artifact-parallel": {"restores": []}}
        text = "\n".join(bench.check_artifact_transfer(failed))
        self.assertIn("--prepare-only core build did not succeed", text)
        self.assertIn("expected one archive manifest, found 0", text)


class EvidenceArtifactTests(unittest.TestCase):
    def test_uploaded_native_shard_files_are_read_by_report(self):
        with tempfile.TemporaryDirectory() as root:
            artifact = Path(root) / "ci-shard-bench-cold-parallel-core"
            evidence = artifact / "shard-results/core.unique"
            evidence.mkdir(parents=True)
            (artifact / "environment.json").write_text(json.dumps({"scenario": "cold-parallel"}))
            (artifact / "shards.json").write_text(json.dumps({
                "shards": [{"shard": "core", "exit_code": 0, "seconds": 19}]
            }))
            (evidence / "timing.txt").write_text("11 5")
            (evidence / "results-swift-testing.xml").write_text(
                junit(("MuesliTests.WordCountTests", "ciShardBenchmarkSentinel()", "")))
            loaded, errors = bench.load_artifacts(root)
            self.assertEqual(errors, [])
            shard = loaded["cold-parallel"]["shards"]["core"]
            self.assertEqual(shard["results"], {SENTINEL_ID: ("passed",)})
            self.assertEqual((shard["prepare_seconds"], shard["test_seconds"]), (11, 5))

    def write_fixture(self, root, archive):
        for layout, jobs in bench.EXPECTED_JOBS.items():
            for index in range(jobs):
                folder = root / f"{layout}-{index}"
                facts = dict.fromkeys(bench.TOOLCHAIN_FACTS, "fixture")
                facts["revision"] = "a" * 40
                bench.write_json(folder / "environment.json",
                                 {"scenario": layout, "facts": facts, "cache_key": "seed-key"})
                if layout == bench.SEED:
                    continue
                bench.write_json(folder / "sentinel.json", {"sentinel_sha256": "x", "edited_file_sha256": "y"})
                if layout == PRODUCER:
                    bench.write_json(folder / "shards.json",
                                     {"shards": [{"shard": "core", "exit_code": 0, "seconds": 30}]})
                    bench.write_json(folder / "archive.json", {**archive, "seconds": 4})
                    continue
                if layout == "artifact-parallel":
                    bench.write_json(folder / "restore.json", {**archive, "seconds": 2})
                shards = bench.SHARDS if jobs == 1 else [bench.SHARDS[index]]
                rows = []
                for shard in shards:
                    results = folder / "shard-results" / f"{shard}.unique"
                    results.mkdir(parents=True)
                    (results / "timing.txt").write_text("8 2")
                    case = ("MuesliTests.WordCountTests", "ciShardBenchmarkSentinel()", "") if shard == "core" else (
                        "MuesliTests.OtherTests", f"{shard}()", "<skipped/>")
                    (results / "results-swift-testing.xml").write_text(junit(case))
                    rows.append({"shard": shard, "exit_code": 0, "seconds": 12})
                bench.write_json(folder / "shards.json", {"shards": rows})

    def test_report_from_downloaded_artifacts(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"BENCHMARK_WORKLOAD": "edited"}):
            root = Path(directory)
            archive = {**dict.fromkeys(bench.ARCHIVE_FIELDS, "same"), "artifact": "shard-bench-scratch-1-1",
                       "bytes": 3_000_000_000, "entries": 12}
            self.write_fixture(root, archive)
            uploads = {"artifacts": [{"name": "shard-bench-scratch-1-1", "size_in_bytes": 1_500_000_000}]}
            report = bench.build_report(root, TimelineTests().jobs(), uploads=uploads)
            self.assertEqual(report["errors"], [])
            self.assertEqual(len(report["results"]), 12)
            artifact = report["build_artifact"]
            self.assertEqual((artifact["uploaded_bytes"], artifact["restores"], artifact["producer_seconds"]),
                             (1_500_000_000, 3, 30))
            text = bench.render(report)
            self.assertIn("valid: identical", text)
            self.assertIn("| artifact-parallel (all phases) | 4 | 1080s |", text)
            self.assertIn("↳ build: artifact-build (included above)", text)
            self.assertIn("3.00 GB tar of 12 entries (1.50 GB uploaded)", text)
            self.assertIn("verified restore on 3/3 runners", text)

    def test_report_rejects_artifact_identity_or_restore_gaps(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {"BENCHMARK_WORKLOAD": "unchanged"}):
            root = Path(directory)
            archive = {**dict.fromkeys(bench.ARCHIVE_FIELDS, "same"), "bytes": 1, "entries": 1}
            self.write_fixture(root, archive)
            # unchanged: the seed must also carry the edit; the producer always does.
            bench.write_json(root / "seed-0/sentinel.json", {"sentinel_sha256": "x", "edited_file_sha256": "y"})
            env_path = root / "artifact-parallel-1/environment.json"
            env_path.write_text(env_path.read_text().replace("seed-key", "other-key"))
            (root / "artifact-parallel-2/restore.json").unlink()
            errors = "\n".join(bench.build_report(root, TimelineTests().jobs())["errors"])
            self.assertIn("Artifact jobs computed a different build identity from the producer", errors)
            self.assertIn("expected 3 verified restores, found 2", errors)
            self.assertNotIn("edit records", errors)


class SentinelAndIdentityTests(unittest.TestCase):
    def test_sentinel_appends_once_to_the_unique_suite(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "ModelsTests.swift"
            source.write_text('import Testing\n\n@Suite("WordCount")\nstruct WordCountTests {\n}\n')
            record = bench.edit_sentinel(Path(directory), filters=["WordCountTests"])
            self.assertIn("extension WordCountTests", source.read_text())
            self.assertEqual(record["sentinel_sha256"], bench.digest_bytes(bench.SENTINEL_SOURCE.encode()))
            with self.assertRaises(SystemExit):
                bench.edit_sentinel(Path(directory), filters=["WordCountTests"])
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "A.swift").write_text("import Testing\nstruct WordCountTests {}\n")
            with self.assertRaises(SystemExit):
                bench.edit_sentinel(Path(directory), filters=["OtherTests"])
            (Path(directory) / "B.swift").write_text("import Testing\nstruct WordCountTests {}\n")
            with self.assertRaises(SystemExit):
                bench.edit_sentinel(Path(directory), filters=["WordCountTests"])

    def test_real_repository_sentinel_host_is_valid(self):
        with tempfile.TemporaryDirectory() as directory:
            for path in (ROOT / bench.PACKAGE / "Tests/MuesliTests").glob("*.swift"):
                (Path(directory) / path.name).write_bytes(path.read_bytes())
            filters = (ROOT / "scripts/run_ci_test_shard.sh").read_text()
            core = filters.split("  core)", 1)[1].split(";;", 1)[0].split()
            bench.edit_sentinel(Path(directory), filters=core)

    def test_cache_key_is_isolated_from_release_namespace(self):
        key = bench.cache_key({"revision": "a" * 40, "xcode": "26.6"})
        self.assertTrue(re.fullmatch(r"ci-shard-bench-debug-v1-[0-9a-f]{64}-a{40}", key))
        self.assertFalse(key.startswith("ci-release-"))
        self.assertNotEqual(key, bench.cache_key({"revision": "a" * 40, "xcode": "26.7"}))
        with self.assertRaises(ValueError):
            bench.cache_key({"revision": "main"})


class WorkflowPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text()

    def job(self, name):
        return re.search(r"^  " + re.escape(name) + r":\n(.*?)(?=^  [\w-]+:\n|\Z)", self.text, re.M | re.S)[1]

    def test_manual_dispatch_only_without_secrets_or_paid_runners(self):
        triggers = self.text.split("\non:\n", 1)[1].split("\npermissions:", 1)[0]
        self.assertEqual(re.findall(r"^  (\S+):", triggers, re.M), ["workflow_dispatch"])
        for forbidden in ("secrets.", "blacksmith", "pull_request", "self-hosted", "restore-keys", "ci-release"):
            self.assertNotIn(forbidden, self.text)
        runners = re.findall(r"^    runs-on: (.+)$", self.text, re.M)
        self.assertEqual(sorted(set(runners)), ["macos-26", "ubuntu-latest"])
        self.assertEqual(len(runners), 9)
        self.assertIn("permissions:\n  contents: read\n", self.text)
        self.assertIn("cancel-in-progress: false", self.text)
        guard = self.job("guard")
        for requirement in ('"$REF" != refs/heads/main', '"$EVENT" != workflow_dispatch'):
            self.assertIn(requirement, guard)

    def test_only_trusted_main_seed_writes_and_only_cleanup_deletes(self):
        self.assertEqual(self.text.count("actions/cache/save@"), 1)
        self.assertIn("actions/cache/save@", self.job("seed"))
        self.assertIn("github.ref == 'refs/heads/main'", self.job("seed"))
        self.assertEqual(self.text.count("actions: write"), 1)
        self.assertIn("actions: write", self.job("cleanup"))
        self.assertIn("-X DELETE", self.job("cleanup"))
        for name in ("cold", "serial", "producer", "artifact"):
            self.assertNotIn("actions/cache", self.job(name))
        cached = self.job("cached")
        self.assertIn("key: ${{ needs.seed.outputs.key }}\n          fail-on-cache-miss: true", cached)
        self.assertIn(f"- name: {bench.RESTORE_STEP}\n", cached)
        self.assertIn(f"- name: {bench.SAVE_STEP}\n", self.job("seed"))
        self.assertIn("ci_shard_benchmark.py prepare-build seed", self.job("seed"))

    def test_every_job_uses_the_selected_revision_and_same_sentinel(self):
        checkouts = self.text.count("uses: actions/checkout@v4")
        self.assertEqual(self.text.count("persist-credentials: false"), checkouts)
        for name in ("seed", "cold", "serial", "cached", "producer", "artifact", "report"):
            self.assertIn("ref: ${{ needs.guard.outputs.revision }}", self.job(name))
        for name in ("cold", "serial", "cached", "producer", "artifact"):
            self.assertIn("ci_shard_benchmark.py edit-sentinel", self.job(name))
            self.assertIn("EXPECTED_REVISION: ${{ needs.guard.outputs.revision }}", self.job(name))
        self.assertIn("inputs.workload == 'unchanged'", self.job("seed"))
        self.assertNotRegex(self.text, r"swift (build|test)")
        names = re.findall(r"^    name: (.+)$", self.text, re.M)
        self.assertEqual({bench.job_scenario(n.replace("${{ matrix.shard }}", "core")) for n in names} - {None},
                         set(bench.EXPECTED_JOBS))

    def test_artifact_layout_builds_once_and_consumers_restore_by_identity(self):
        producer, consumer, report = self.job("producer"), self.job("artifact"), self.job("report")
        self.assertIn("    name: artifact-build\n    needs: [guard, cached]\n", producer)
        self.assertIn("ci_shard_benchmark.py prepare artifact-build", producer)
        self.assertLess(producer.index("edit-sentinel"), producer.index("prepare-build artifact-build"))
        self.assertIn(f"- name: {bench.ARCHIVE_STEP}\n        id: archive", producer)
        self.assertIn(f"- name: {bench.UPLOAD_STEP}\n        uses: actions/upload-artifact@v4", producer)
        self.assertIn("ARTIFACT: shard-bench-scratch-${{ github.run_id }}-${{ github.run_attempt }}", producer)
        self.assertIn("name: ${{ steps.archive.outputs.artifact }}", producer)
        self.assertIn("retention-days: 1\n", producer)
        self.assertIn("needs.producer.result == 'success'", consumer)
        markers = ("prepare artifact-parallel", "Require the producer's build identity",
                   f"- name: {bench.DOWNLOAD_STEP}", f"- name: {bench.EXTRACT_STEP}", "edit-sentinel",
                   "run artifact-parallel")
        order = [consumer.index(marker) for marker in markers]
        self.assertEqual(order, sorted(order))
        self.assertIn('test -n "$EXPECTED" && test "$EXPECTED" = "$ACTUAL"', consumer)
        self.assertIn("EXPECTED: ${{ needs.producer.outputs.key }}", consumer)
        self.assertIn("name: ${{ needs.producer.outputs.artifact }}", consumer)
        self.assertNotIn("prepare-build", consumer)
        self.assertIn("needs: [guard, seed, cold, serial, cached, producer, artifact]", report)
        self.assertIn("pattern: ci-shard-bench-*", report)
        self.assertFalse(bench.ARTIFACT_PATTERN.fullmatch("ci-shard-bench-x"))
        self.assertTrue(bench.ARTIFACT_PATTERN.fullmatch("shard-bench-scratch-123-1"))
        self.assertIn('"$RUNNER_TEMP/uploads.json"', report)


if __name__ == "__main__":
    unittest.main()
