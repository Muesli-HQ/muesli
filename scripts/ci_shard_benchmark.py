#!/usr/bin/env python3
"""Opt-in test-shard build-reuse benchmark; never part of the required CI gate.

Each measured shard invokes the production runner and consumes its audited xUnit
results. The shared-runner layout reuses the prepared build and Metal library;
the artifact layout ships one prepared scratch directory to fresh runners.
"""

import argparse
from datetime import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import stat
import subprocess
import sys
import time
from ci_test_coverage_audit import recorded_tests

PACKAGE = Path("native/MuesliNative")
SCRATCH = PACKAGE / ".build"  # The shard script's default (unset MUESLI_SWIFTPM_SCRATCH_PATH).
SHARD_SCRIPT = Path("scripts/run_ci_test_shard.sh")
WATCHDOG = Path("scripts/sample_core_test_hang.sh")
SHARDS = ("core", "dictation-transcription", "meetings")
SCENARIOS = ("cold-parallel", "serial-reuse", "cached-parallel", "artifact-parallel")
SEED = "seed"
PRODUCER = "artifact-build"
SETUP = (SEED, PRODUCER)  # Build-only jobs: no shard results to compare.
# Execution order. Each group becomes eligible when the previous one completes.
EXPECTED_JOBS = {SEED: 1, "cold-parallel": 3, "serial-reuse": 1, "cached-parallel": 3,
                 PRODUCER: 1, "artifact-parallel": 3}
PREVIOUS = {SEED: "guard", "cold-parallel": SEED, "serial-reuse": "cold-parallel",
            "cached-parallel": "serial-reuse", PRODUCER: "cached-parallel", "artifact-parallel": PRODUCER}
# Layouts whose PR-path cost spans several job groups. The layout row covers
# every phase, from the first phase's eligibility to the last job's completion.
LAYOUT_PHASES = {"artifact-parallel": {"build": PRODUCER, "shards": "artifact-parallel"}}
KEY_NAMESPACE = "ci-shard-bench-debug-v1-"
RESTORE_STEP = "Restore isolated debug cache"
SAVE_STEP = "Save isolated debug cache"
ARCHIVE_STEP = "Archive exact scratch"
UPLOAD_STEP = "Upload build artifact"
DOWNLOAD_STEP = "Download build artifact"
EXTRACT_STEP = "Verify and restore exact scratch"
TRANSFER_STEPS = {SEED: (SAVE_STEP,), "cached-parallel": (RESTORE_STEP,),
                  PRODUCER: (ARCHIVE_STEP, UPLOAD_STEP), "artifact-parallel": (DOWNLOAD_STEP, EXTRACT_STEP)}
REQUIRED_TRANSFERS = ("cached-parallel", PRODUCER, "artifact-parallel")
# Deliberately outside the report's ci-shard-bench-* download pattern.
ARTIFACT_PATTERN = re.compile(r"shard-bench-scratch-[0-9]+-[0-9]+")
ARCHIVE_NAME = "scratch.tar"
MANIFEST_NAME = "manifest.json"
ARCHIVE_FIELDS = ("artifact", "cache_key", "scratch", "sha256", "bytes", "tree_sha256", "entries")
TOOLCHAIN_FACTS = ("architecture", "os", "image", "xcode", "swift", "sdk")

SENTINEL_SHARD = "core"
SENTINEL_SUITE = "WordCountTests"
SENTINEL_TEST = "ciShardBenchmarkSentinel"
SENTINEL_SOURCE = f"""

// CI shard benchmark sentinel: appended only inside disposable benchmark checkouts.
extension {SENTINEL_SUITE} {{
    @Test func {SENTINEL_TEST}() {{
        #expect("{SENTINEL_TEST}".hasPrefix("ciShard"))
    }}
}}
"""


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def digest_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 24), b""):
            digest.update(chunk)
    return digest.hexdigest()


def results_dir():
    explicit = os.environ.get("CI_SHARD_BENCH_RESULTS")
    return Path(explicit) if explicit else Path(os.environ["RUNNER_TEMP"]) / "ci-shard-bench"


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def write_output(**values):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.writelines(f"{key}={value}\n" for key, value in values.items())


# --- identity -----------------------------------------------------------------

def cache_key(facts):
    revision = facts.get("revision", "")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Cache revision must be a full commit SHA")
    fingerprint = digest_bytes(json.dumps(facts, sort_keys=True).encode())
    return f"{KEY_NAMESPACE}{fingerprint}-{revision}"


def prepare(scenario):
    def capture(*command):
        return subprocess.check_output(command, text=True).strip()

    revision = capture("git", "rev-parse", "HEAD")
    if revision != os.environ.get("EXPECTED_REVISION"):
        raise SystemExit(f"Checked out {revision}, expected the selected main revision")
    if SCRATCH.exists() or SCRATCH.is_symlink():
        raise SystemExit(f"{SCRATCH} already exists; measured runs require a fresh runner")
    facts = {
        "architecture": platform.machine(),
        "os": platform.mac_ver()[0],
        "image": os.environ.get("ImageVersion", "unknown"),
        "xcode": capture("xcodebuild", "-version"),
        "swift": capture("swift", "--version"),
        "sdk": capture("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdk_path": capture("xcrun", "--sdk", "macosx", "--show-sdk-path"),
        "workspace": str(Path.cwd()),
        "scratch": str(SCRATCH.resolve()),
        "manifest": digest_bytes((PACKAGE / "Package.swift").read_bytes()),
        "lockfile": digest_bytes((PACKAGE / "Package.resolved").read_bytes()),
        "shard_script": digest_bytes(SHARD_SCRIPT.read_bytes()),
        "harness": digest_bytes(Path(__file__).read_bytes()),
        "revision": revision,
        "workload": os.environ["BENCHMARK_WORKLOAD"],
        "run_id": os.environ["GITHUB_RUN_ID"],
        "run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
    }
    key = cache_key(facts)
    write_output(key=key, scratch=facts["scratch"])
    write_json(results_dir() / "environment.json", {"scenario": scenario, "facts": facts, "cache_key": key})
    print(f"Scenario {scenario}; isolated cache key {key}\n{json.dumps(facts, indent=2)}")


def load_environment(scenario):
    environment = json.loads((results_dir() / "environment.json").read_text())
    if environment.get("scenario") != scenario:
        raise SystemExit(f"Environment evidence is for {environment.get('scenario')!r}, expected {scenario!r}")
    return environment


# --- build artifact -------------------------------------------------------------

def tree_digest(root):
    """Paths, types, permissions, file sizes and link targets; mtimes excluded."""
    root = Path(root)
    digest, entries = hashlib.sha256(), 0
    for directory, dirs, files in os.walk(root):
        dirs.sort()
        base = Path(directory)
        for name in sorted(dirs + files):
            path = base / name
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                line = f"l\0{os.readlink(path)}"  # Symlink modes differ by platform.
            elif stat.S_ISDIR(info.st_mode):
                line = f"d\0{info.st_mode & 0o777:o}"
            elif stat.S_ISREG(info.st_mode):
                line = f"f\0{info.st_mode & 0o777:o}\0{info.st_size}"
            else:
                line = "o"
            digest.update(f"{path.relative_to(root).as_posix()}\0{line}\n".encode())
            entries += 1
    return {"tree_sha256": digest.hexdigest(), "entries": entries}


def archive_scratch(out_dir, artifact, scratch=SCRATCH):
    """Tar the exact prepared scratch directory (symlinks and modes intact)."""
    started = time.monotonic()
    if not ARTIFACT_PATTERN.fullmatch(artifact):
        raise SystemExit(f"Unexpected build artifact name {artifact!r}")
    scratch = Path(scratch)
    if scratch.is_symlink() or not scratch.is_dir():
        raise SystemExit(f"{scratch} must be the prepared scratch directory")
    environment = load_environment(PRODUCER)
    if environment["facts"]["scratch"] != str(scratch.resolve()):
        raise SystemExit(f"{scratch.resolve()} is not the identified scratch {environment['facts']['scratch']}")
    out = Path(out_dir)
    if out.exists() and any(out.iterdir()):
        raise SystemExit(f"{out} must be empty")
    out.mkdir(parents=True, exist_ok=True)
    archive = out / ARCHIVE_NAME
    tree = tree_digest(scratch)
    subprocess.run(["tar", "-C", str(scratch.resolve().parent), "-cf", str(archive), scratch.name], check=True)
    manifest = {"artifact": artifact, "cache_key": environment["cache_key"], "scratch": str(scratch.resolve()),
                "archive": ARCHIVE_NAME, "sha256": digest_file(archive), "bytes": archive.stat().st_size, **tree}
    manifest["seconds"] = round(time.monotonic() - started, 3)
    write_json(out / MANIFEST_NAME, manifest)
    write_json(results_dir() / "archive.json", manifest)
    write_output(artifact=artifact)
    print(f"Archived {tree['entries']} entries, {manifest['bytes']} bytes, sha256 {manifest['sha256']}")
    return manifest


def restore_scratch(in_dir, scratch=SCRATCH):
    """Verify the producer's identity and archive, then extract to the same path."""
    started = time.monotonic()
    source = Path(in_dir)
    manifest = json.loads((source / MANIFEST_NAME).read_text())
    environment = load_environment("artifact-parallel")
    target = Path(scratch)
    if target.exists() or target.is_symlink():
        raise SystemExit(f"{target} already exists; restore requires a fresh runner")
    for field, expected in (("cache_key", environment["cache_key"]), ("scratch", str(target.resolve())),
                            ("archive", ARCHIVE_NAME)):
        if manifest.get(field) != expected:
            raise SystemExit(f"Build artifact {field} {manifest.get(field)!r} does not match this runner's {expected!r}")
    if not ARTIFACT_PATTERN.fullmatch(str(manifest.get("artifact"))):
        raise SystemExit(f"Unexpected build artifact name {manifest.get('artifact')!r}")
    archive = source / ARCHIVE_NAME
    actual = {"sha256": digest_file(archive), "bytes": archive.stat().st_size}
    for field, value in actual.items():
        if manifest.get(field) != value:
            raise SystemExit(f"Build artifact {field} {value!r} differs from the producer's {manifest.get(field)!r}")
    parent = target.resolve().parent
    before = set(os.listdir(parent))
    subprocess.run(["tar", "-C", str(parent), "-xpf", str(archive)], check=True)
    after = set(os.listdir(parent))
    if after - before != {target.name} or before - after:
        raise SystemExit(f"Archive changed more than {target.name}: added {sorted(after - before)}, "
                         f"removed {sorted(before - after)}")
    tree = tree_digest(target)
    for field, value in tree.items():
        if manifest.get(field) != value:
            raise SystemExit(f"Restored scratch {field} {value!r} differs from the producer's {manifest.get(field)!r}")
    archive.unlink()  # Leave the runner's disk as the producer left its own.
    record = {field: manifest[field] for field in ARCHIVE_FIELDS}
    record["seconds"] = round(time.monotonic() - started, 3)
    write_json(results_dir() / "restore.json", record)
    print(f"Restored {tree['entries']} entries to {target.resolve()} (sha256 {manifest['sha256']})")
    return record


# --- sentinel -------------------------------------------------------------------

def list_filters(shard):
    out = subprocess.check_output(["bash", str(SHARD_SCRIPT), "--list-filters", shard], text=True)
    return out.split()


def edit_sentinel(test_root=PACKAGE / "Tests/MuesliTests", filters=None):
    filters = list_filters(SENTINEL_SHARD) if filters is None else filters
    if SENTINEL_SUITE not in filters:
        raise SystemExit(f"{SENTINEL_SUITE} is no longer in the {SENTINEL_SHARD} shard")
    declaration = re.compile(r"^(?:(?:private|fileprivate|internal|public|final)\s+)*"
                             rf"(?:struct|class|actor|enum)\s+{SENTINEL_SUITE}\b", re.M)
    sources = sorted(test_root.rglob("*.swift"))
    if any(SENTINEL_TEST in path.read_text() for path in sources):
        raise SystemExit("Sentinel already present; refusing to edit twice")
    hosts = [path for path in sources if declaration.search(path.read_text())]
    if len(hosts) != 1 or not re.search(r"^import Testing$", hosts[0].read_text(), re.M):
        raise SystemExit(f"Expected one top-level Swift Testing {SENTINEL_SUITE} declaration, found {hosts}")
    with hosts[0].open("a") as stream:
        stream.write(SENTINEL_SOURCE)
    record = {"file": str(hosts[0]), "sentinel_sha256": digest_bytes(SENTINEL_SOURCE.encode()),
              "edited_file_sha256": digest_bytes(hosts[0].read_bytes())}
    print(f"Appended sentinel {SENTINEL_SUITE}/{SENTINEL_TEST}() to {hosts[0]}")
    return record


def run_shard_script(shard, env, watchdog=False, mode=None):
    """Exactly the ci.yml step: optional core hang sampler + the normal entrypoint."""
    sampler = subprocess.Popen(["bash", str(WATCHDOG)], env=env, start_new_session=True) if watchdog else None
    started = time.monotonic()
    try:
        command = ["bash", str(SHARD_SCRIPT), *([mode] if mode else []), shard]
        code = subprocess.call(command, env=env)
    finally:
        if sampler is not None:
            try:
                os.killpg(sampler.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            sampler.wait()
    return {"shard": shard, "exit_code": code, "seconds": round(time.monotonic() - started, 3)}


def run(scenario, shards):
    if scenario == "serial-reuse" and tuple(shards) != SHARDS:
        raise SystemExit(f"serial-reuse must run all shards in order: {' '.join(SHARDS)}")
    if scenario != "serial-reuse" and (len(shards) != 1 or shards[0] not in SHARDS):
        raise SystemExit("parallel scenarios run exactly one known shard per job")
    results = results_dir()
    env = dict(os.environ, MUESLI_CI_SHARD_RESULTS=str(results / "shard-results"))
    env.pop("MUESLI_SWIFTPM_SCRATCH_PATH", None)
    # Serial shards share one runner and build directory: the first invocation
    # builds; later invocations reuse its products and Metal library. Artifact
    # shards reuse the producer's restored scratch and never compile.
    records = []
    for index, shard in enumerate(shards):
        reuse = scenario == "artifact-parallel" or (scenario == "serial-reuse" and index)
        records.append(run_shard_script(shard, env, watchdog=shard == "core",
                                        mode="--reuse-build" if reuse else None))
    write_json(results / "shards.json", {"scenario": scenario, "shards": records})
    failed = [r["shard"] for r in records if r["exit_code"] != 0]
    if failed:
        print(f"::error::Shard(s) failed: {', '.join(failed)}")
    return 1 if failed else 0


def prepare_build(scenario):
    """Build tests and Metal via the shard script itself so artifacts match exactly."""
    results = results_dir()
    env = dict(os.environ)
    env.pop("MUESLI_SWIFTPM_SCRATCH_PATH", None)
    record = run_shard_script("core", env, mode="--prepare-only")
    write_json(results / "shards.json", {"scenario": scenario, "shards": [record]})
    return record["exit_code"]


# --- reporting ------------------------------------------------------------------

def parse_junit(paths):
    actual = recorded_tests(path for path in paths if path.stat().st_size)
    return {test_id: (status,) for test_id, status in actual.items()}


def is_sentinel(test_id):
    suite, _, name = test_id.rpartition("/")
    return suite == f"MuesliTests.{SENTINEL_SUITE}" and name == f"{SENTINEL_TEST}()"


def load_artifacts(root):
    scenarios = {name: {"shards": {}, "environments": [], "sentinels": [], "archives": [], "restores": []}
                 for name in SCENARIOS + SETUP}
    errors = []
    for env_path in sorted(Path(root).glob("*/environment.json")):
        directory = env_path.parent
        environment = json.loads(env_path.read_text())
        scenario = scenarios.get(environment.get("scenario"))
        if scenario is None:
            errors.append(f"{directory.name}: unknown scenario")
            continue
        scenario["environments"].append(environment)
        for kind, filename in (("sentinels", "sentinel.json"), ("archives", "archive.json"),
                               ("restores", "restore.json")):
            if (directory / filename).exists():
                scenario[kind].append(json.loads((directory / filename).read_text()))
        shards_path = directory / "shards.json"
        for record in json.loads(shards_path.read_text())["shards"] if shards_path.exists() else []:
            shard = record["shard"]
            if shard in scenario["shards"]:
                errors.append(f"{environment['scenario']}: duplicate {shard} results")
            evidence = list((directory / "shard-results").glob(f"{shard}.*/timing.txt"))
            prepare_seconds = test_seconds = 0
            reports = []
            if len(evidence) == 1:
                prepare_seconds, test_seconds = map(int, evidence[0].read_text().split())
                reports = sorted(evidence[0].parent.glob("*.xml"))
            scenario["shards"][shard] = {
                "exit_code": record["exit_code"], "script_seconds": record["seconds"],
                "prepare_seconds": prepare_seconds, "test_seconds": test_seconds,
                "test_invocations": len(evidence), "results": parse_junit(reports),
            }
    return scenarios, errors


def compare_results(scenarios):
    """Exact (shard, test ID) -> statuses parity against the current cold layout."""
    errors, rows = [], []
    flat = {}
    for name in SCENARIOS:
        shards = scenarios[name]["shards"]
        flat[name] = {}
        for shard in SHARDS:
            data = shards.get(shard)
            if data is None:
                errors.append(f"{name}: no {shard} results")
                continue
            if data["exit_code"] != 0:
                errors.append(f"{name}/{shard}: shard script exited {data['exit_code']}")
            if data["test_invocations"] != 1 or not data["results"]:
                errors.append(f"{name}/{shard}: expected one executed swift test with JUnit results")
            counts = {status: 0 for status in ("passed", "failed", "skipped")}
            for statuses in data["results"].values():
                for status in statuses:
                    counts[status] += 1
            rows.append({"scenario": name, "shard": shard, **counts,
                         "tests": len(data["results"])})
            flat[name].update({(shard, test_id): statuses for test_id, statuses in data["results"].items()})
        sentinel = {key: value for key, value in flat[name].items() if is_sentinel(key[1])}
        if list(sentinel.values()) != [("passed",)] or next(iter(sentinel))[0] != SENTINEL_SHARD:
            errors.append(f"{name}: sentinel must execute and pass exactly once in {SENTINEL_SHARD}; got {sentinel}")
    baseline = flat["cold-parallel"]
    for name in SCENARIOS[1:]:
        missing = sorted(set(baseline) - set(flat[name]))
        extra = sorted(set(flat[name]) - set(baseline))
        changed = sorted(key for key in set(baseline) & set(flat[name]) if baseline[key] != flat[name][key])
        for label, keys in (("missing", missing), ("extra", extra), ("changed status", changed)):
            if keys:
                sample = ", ".join(f"{s}:{t}" for s, t in keys[:10])
                errors.append(f"{name} vs cold-parallel: {len(keys)} {label} test(s): {sample}")
    return rows, errors


def check_identity(scenarios):
    errors, warnings = [], []
    environments = [env for data in scenarios.values() for env in data["environments"]]
    revisions = {env["facts"]["revision"] for env in environments}
    if len(revisions) != 1:
        errors.append(f"Scenarios used different revisions: {sorted(revisions)}")
    toolchains = {json.dumps({k: env["facts"][k] for k in TOOLCHAIN_FACTS}, sort_keys=True) for env in environments}
    if len(toolchains) > 1:
        errors.append("Runner image/toolchain differed between jobs; timings are less comparable")
    workload = os.environ.get("BENCHMARK_WORKLOAD")
    digests = set()
    for name, data in scenarios.items():
        if len(data["environments"]) != EXPECTED_JOBS[name]:
            errors.append(f"{name}: incomplete environment evidence")
        # Only the seed's edit depends on the workload; the producer builds the edited tree.
        expected_edits = EXPECTED_JOBS[name] if name != SEED or workload == "unchanged" else 0
        if len(data["sentinels"]) != expected_edits:
            errors.append(f"{name}: expected {expected_edits} edit records, found {len(data['sentinels'])}")
        digests.update((s["sentinel_sha256"], s["edited_file_sha256"]) for s in data["sentinels"])
    if len(digests) > 1:
        errors.append("Scenarios did not apply an identical sentinel edit")
    for group, label in (((SEED, "cached-parallel"), "Cached jobs computed a different cache identity from the seed"),
                         ((PRODUCER, "artifact-parallel"),
                          "Artifact jobs computed a different build identity from the producer")):
        if len({env["cache_key"] for name in group for env in scenarios[name]["environments"]}) > 1:
            errors.append(label)
    return errors, warnings


def check_artifact_transfer(scenarios):
    """The producer built successfully and every consumer restored its exact archive."""
    errors = []
    producer = scenarios[PRODUCER]["shards"].get("core")
    if producer is None or producer["exit_code"] != 0:
        errors.append(f"{PRODUCER}: --prepare-only core build did not succeed")
    archives = scenarios[PRODUCER]["archives"]
    if len(archives) != 1:
        return errors + [f"{PRODUCER}: expected one archive manifest, found {len(archives)}"]
    restores = scenarios["artifact-parallel"]["restores"]
    if len(restores) != EXPECTED_JOBS["artifact-parallel"]:
        errors.append(f"artifact-parallel: expected {EXPECTED_JOBS['artifact-parallel']} verified restores, "
                      f"found {len(restores)}")
    for restore in restores:
        differing = [field for field in ARCHIVE_FIELDS if restore.get(field) != archives[0].get(field)]
        if differing:
            errors.append(f"artifact-parallel: restored scratch differs from the producer's in {differing}")
    return errors


def _time(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _span(start, end):
    return (_time(end) - _time(start)).total_seconds()


def job_scenario(name):
    base = name.split(" (", 1)[0]
    return base if base in EXPECTED_JOBS else None


def _timing(entries):
    """entries: (job, ready_at) pairs, where ready_at is when the job became eligible."""
    execution = [_span(job["started_at"], job["completed_at"]) for job, _ in entries]
    queue = [_span(ready, job["started_at"]) for job, ready in entries]
    first = min((ready for _, ready in entries), key=_time)
    last = max((job["completed_at"] for job, _ in entries), key=_time)
    return {
        "queue_to_completion_seconds": _span(first, last),
        "max_queue_seconds": max(queue),
        "queue_seconds_total": sum(queue),
        "longest_job_seconds": max(execution),
        "runner_minutes": round(sum(execution) / 60, 2),
        "rounded_job_minutes": sum(math.ceil(seconds / 60) for seconds in execution),
    }


def _step_seconds(job, name):
    for step in job.get("steps", []):
        if (step.get("name") == name and step.get("conclusion") == "success"
                and step.get("started_at") and step.get("completed_at")):
            return _span(step["started_at"], step["completed_at"])
    return None


def summarize_jobs(jobs):
    """Aggregate the Actions job timeline. All values are seconds unless noted."""
    summary, errors, entries = {}, [], {}
    for group, expected in EXPECTED_JOBS.items():
        selected = [job for job in jobs if job_scenario(job["name"]) == group]
        record = {"jobs": len(selected), "conclusions": sorted(str(j.get("conclusion")) for j in selected)}
        complete = len(selected) == expected and all(j.get("started_at") and j.get("completed_at") for j in selected)
        if not complete:
            errors.append(f"{group}: expected {expected} completed job(s), found {len(selected)}")
        elif any(j.get("conclusion") != "success" for j in selected):
            errors.append(f"{group}: job conclusions {record['conclusions']}")
        if complete:
            # The workflow runs groups consecutively. Earlier benchmark jobs
            # are setup for this group and must not inflate its queue time.
            previous = PREVIOUS[group]
            ready = [j["completed_at"] for j in jobs if j["name"].split(" (", 1)[0] == previous and j.get("completed_at")]
            if not ready:
                errors.append(f"{group}: missing completion time for {previous}")
            eligible = max(ready, key=_time) if ready else min((j["created_at"] for j in selected), key=_time)
            entries[group] = [(job, eligible) for job in selected]
            if any(_span(eligible, job["started_at"]) < 0 for job in selected):
                errors.append(f"{group}: job started before its prerequisite completed")
            record.update(_timing(entries[group]))
        steps = TRANSFER_STEPS.get(group, ())
        transfers = [seconds for job in selected for name in steps
                     if (seconds := _step_seconds(job, name)) is not None]
        record.update(transfer_steps=len(transfers), transfer_seconds_total=sum(transfers),
                      transfer_seconds_max=max(transfers, default=0))
        if group in REQUIRED_TRANSFERS and (len(selected) != expected or len(transfers) != expected * len(steps)):
            errors.append(f"{group}: every job must record successful {', '.join(map(repr, steps))} step(s)")
        summary[group] = record
    for layout, phases in LAYOUT_PHASES.items():
        records = {label: summary[group] for label, group in phases.items()}
        combined = {
            "jobs": sum(r["jobs"] for r in records.values()),
            "conclusions": sorted(c for r in records.values() for c in r["conclusions"]),
            "transfer_steps": sum(r["transfer_steps"] for r in records.values()),
            "transfer_seconds_total": sum(r["transfer_seconds_total"] for r in records.values()),
            "transfer_seconds_max": max(r["transfer_seconds_max"] for r in records.values()),
            "phases": records,
        }
        if all(group in entries for group in phases.values()):
            combined.update(_timing([entry for group in phases.values() for entry in entries[group]]))
        summary[layout] = combined
    return summary, errors


def _fmt(seconds):
    return "n/a" if seconds is None else f"{seconds:.0f}s"


def _gb(size):
    return f"{size / 1e9:.2f} GB"


def _timeline_row(label, r):
    return (f"| {label} | {r['jobs']} | {_fmt(r.get('queue_to_completion_seconds'))} | "
            f"{_fmt(r.get('max_queue_seconds'))} | {_fmt(r.get('queue_seconds_total'))} | "
            f"{_fmt(r.get('longest_job_seconds'))} | {r.get('runner_minutes', 'n/a')} | "
            f"{r.get('rounded_job_minutes', 'n/a')} | "
            f"{_fmt(r['transfer_seconds_total'])} / {_fmt(r['transfer_seconds_max'])} |")


def render(report):
    t = report["timeline"]
    lines = ["## CI shard benchmark", "",
             f"Revision `{report['revision']}` · {report['workload']} workload · attempt {report['run_attempt']}.", "",
             "| Layout | Jobs | Queue→completion | Max queue | Total queue | Longest job | Runner min | "
             "Rounded job min | Transfer (sum / max) |",
             "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for name in SCENARIOS:
        r = t[name]
        if name in LAYOUT_PHASES:
            lines.append(_timeline_row(f"{name} (all phases)", r))
            for label, group in LAYOUT_PHASES[name].items():
                lines.append(_timeline_row(f"↳ {label}: {group} (included above)", r["phases"][label]))
        else:
            lines.append(_timeline_row(name, r))
    lines.append(_timeline_row(f"{SEED} (trusted-main cost; not on any PR path)", t[SEED]))
    lines += ["", "| Layout | Shard | Script | Build + Metal preparation | swift test | Exit | Tests | Passed | Failed | Skipped |",
              "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for row in report["results"]:
        shard = report["shards"][row["scenario"]][row["shard"]]
        lines.append(f"| {row['scenario']} | {row['shard']} | {_fmt(shard['script_seconds'])} | "
                     f"{_fmt(shard['prepare_seconds'])} | {_fmt(shard['test_seconds'])} | {shard['exit_code']} | "
                     f"{row['tests']} | {row['passed']} | {row['failed']} | {row['skipped']} |")
    cache = report.get("seed_cache")
    lines += ["", f"Seed cache: `{cache['key']}`, {_gb(cache['size_bytes'])} compressed."
              if cache else "Seed cache size unavailable (entry missing or pre-existing lookup only)."]
    artifact = report.get("build_artifact")
    if artifact:
        uploaded = (f"{_gb(artifact['uploaded_bytes'])} uploaded" if artifact.get("uploaded_bytes") is not None
                    else "uploaded size unavailable")
        lines.append(f"Build artifact: `{artifact['artifact']}`, {_gb(artifact['bytes'])} tar of "
                     f"{artifact['entries']} entries ({uploaded}); producer `--prepare-only core` "
                     f"{_fmt(artifact.get('producer_seconds'))}, archive {_fmt(artifact.get('archive_seconds'))}; "
                     f"verified restore on {artifact['restores']}/{EXPECTED_JOBS['artifact-parallel']} runners.")
    else:
        lines.append("Build artifact manifest unavailable.")
    lines += ["", "Definitions: *Queue→completion* = layout eligibility to its last job completion "
              "(excludes unrelated gate jobs); for artifact-parallel it runs from producer eligibility through the "
              "last shard. *Max/Total queue* = wait from each job's prerequisite completing to that job starting. "
              "*Runner min* = sum of job execution time; *Rounded job min* rounds each job up to a whole minute "
              "(unweighted estimate). Transfer is the cache save/restore or archive/upload/download/restore step "
              "time and is already inside job time; do not add it. Script/build/test are in-job and overlap job "
              "time. Seed is a trusted-main cost, not per-PR; the artifact producer is per-PR and included."]
    for title, items in (("Errors", report["errors"]), ("Warnings", report["warnings"])):
        if items:
            lines += ["", f"### {title}", ""] + [f"- {item}" for item in items]
    lines += ["", "**Result: " + ("INVALID — do not use these timings" if report["errors"] else
                                   "valid: identical executed tests/results and sentinel in every scenario") + "**", ""]
    return "\n".join(lines)


def build_report(artifacts, jobs, caches=None, run_attempt="1", uploads=None):
    scenarios, errors = load_artifacts(artifacts)
    rows, result_errors = compare_results(scenarios)
    identity_errors, warnings = check_identity(scenarios)
    transfer_errors = check_artifact_transfer(scenarios)
    timeline, timeline_errors = summarize_jobs(jobs)
    if str(run_attempt) != "1":
        warnings.append("Re-run attempt: carried-over jobs may distort queue/runner timings")
    seed_key = next((env["cache_key"] for env in scenarios[SEED]["environments"]), None)
    entry = next((c for c in (caches or {}).get("actions_caches", []) if c.get("key") == seed_key), None)
    archive = next(iter(scenarios[PRODUCER]["archives"]), None)
    build_artifact = None
    if archive:
        upload = next((a for a in (uploads or {}).get("artifacts", []) if a.get("name") == archive["artifact"]), None)
        producer = scenarios[PRODUCER]["shards"].get("core", {})
        build_artifact = {**{field: archive[field] for field in ARCHIVE_FIELDS},
                          "archive_seconds": archive.get("seconds"), "producer_seconds": producer.get("script_seconds"),
                          "uploaded_bytes": upload.get("size_in_bytes") if upload else None,
                          "restores": len(scenarios["artifact-parallel"]["restores"])}
    revisions = sorted({env["facts"]["revision"] for data in scenarios.values() for env in data["environments"]})
    return {
        "revision": ", ".join(revisions) or "unknown", "run_attempt": run_attempt,
        "workload": os.environ.get("BENCHMARK_WORKLOAD", "unknown"),
        "timeline": timeline, "results": rows,
        "shards": {name: {shard: {k: v for k, v in data.items() if k != "results"}
                          for shard, data in scenarios[name]["shards"].items()} for name in SCENARIOS},
        "seed_cache": {"key": seed_key, "size_bytes": entry["size_in_bytes"]} if entry else None,
        "build_artifact": build_artifact,
        "errors": errors + result_errors + identity_errors + transfer_errors + timeline_errors,
        "warnings": warnings,
    }


def _optional_json(path):
    return json.loads(Path(path).read_text()) if path and Path(path).exists() else None


def report(artifacts, jobs_path, caches_path, uploads_path=None):
    jobs = [json.loads(line) for line in Path(jobs_path).read_text().splitlines() if line.strip()]
    data = build_report(artifacts, jobs, _optional_json(caches_path), os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
                        _optional_json(uploads_path))
    write_json(results_dir() / "report.json", data)
    text = render(data)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
            summary.write(text)
    return 1 if data["errors"] else 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("prepare").add_argument("scenario", choices=SCENARIOS + SETUP)
    sub.add_parser("edit-sentinel")
    sub.add_parser("prepare-build").add_argument("scenario", choices=SETUP)
    archiver = sub.add_parser("archive-scratch")
    archiver.add_argument("out_dir")
    archiver.add_argument("artifact")
    sub.add_parser("restore-scratch").add_argument("in_dir")
    runner = sub.add_parser("run")
    runner.add_argument("scenario", choices=SCENARIOS)
    runner.add_argument("shards", nargs="+", choices=SHARDS)
    rep = sub.add_parser("report")
    rep.add_argument("artifacts")
    rep.add_argument("jobs")
    rep.add_argument("caches", nargs="?")
    rep.add_argument("uploads", nargs="?")
    args = parser.parse_args(argv)
    if os.environ.get("GITHUB_ACTIONS") != "true":
        parser.error("Run only on GitHub Actions; use scripts/test_ci_shard_benchmark.py locally")
    if args.action == "prepare":
        prepare(args.scenario)
    elif args.action == "edit-sentinel":
        write_json(results_dir() / "sentinel.json", edit_sentinel())
    elif args.action == "prepare-build":
        return prepare_build(args.scenario)
    elif args.action == "archive-scratch":
        archive_scratch(args.out_dir, args.artifact)
    elif args.action == "restore-scratch":
        restore_scratch(args.in_dir)
    elif args.action == "run":
        return run(args.scenario, args.shards)
    else:
        return report(args.artifacts, args.jobs, args.caches, args.uploads)
    return 0


if __name__ == "__main__":
    sys.exit(main())
