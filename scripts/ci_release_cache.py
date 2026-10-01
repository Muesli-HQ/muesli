#!/usr/bin/env python3
"""Release-only CI cache identity, build execution, and phase measurements."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time

PACKAGE = Path("native/MuesliNative")
RESULTS = Path("ci-release-results")
PHASES = ("pipeline", "restore", "build", "save")


def scratch_path():
    return Path.home() / "Library/Caches/muesli-spm/ci/release"


def build_command(scratch):
    return ["swift", "build", "--package-path", str(PACKAGE), "--scratch-path",
            str(scratch), "-c", "release", "--product", "MuesliNativeApp",
            "--force-resolved-versions"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cache_keys(facts, revision):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Cache revision must be a full commit SHA")
    fingerprint = hashlib.sha256(json.dumps(facts, sort_keys=True).encode()).hexdigest()
    prefix = f"ci-release-v1-{fingerprint}-"
    return prefix + revision, prefix


def prepare():
    scratch = scratch_path()
    if scratch.exists():
        raise RuntimeError("Expected a fresh hosted runner with no release scratch directory")

    def capture(*command):
        return subprocess.check_output(command, text=True).strip()

    facts = {
        "architecture": platform.machine(),
        "os": platform.mac_ver()[0],
        "image": os.environ.get("ImageVersion", "unknown"),
        "xcode": capture("xcodebuild", "-version"),
        "swift": capture("swift", "--version"),
        "sdk": capture("xcrun", "--sdk", "macosx", "--show-sdk-version"),
        "sdk_path": capture("xcrun", "--sdk", "macosx", "--show-sdk-path"),
        "workspace": str(Path.cwd()),
        "scratch": str(scratch),
        "command": build_command(scratch),
        "manifest": digest(PACKAGE / "Package.swift"),
        "lockfile": digest(PACKAGE / "Package.resolved"),
        "helper": digest(Path(__file__)),
    }
    key, prefix = cache_keys(facts, os.environ["CACHE_REVISION"])
    RESULTS.mkdir(exist_ok=True)
    (RESULTS / "environment.json").write_text(json.dumps(facts, indent=2) + "\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"scratch={scratch}\nkey={key}\nprefix={prefix}\n")
    print(f"Release cache key: {key}\n{json.dumps(facts, indent=2)}")


def mark(action, phase, results=RESULTS):
    if action not in ("begin", "end") or phase not in PHASES:
        raise ValueError("Unknown timing marker")
    path = results / "timings.json"
    data = json.loads(path.read_text()) if path.exists() else {}
    entry = data.setdefault(phase, {})
    if action in entry or (action == "end" and "begin" not in entry):
        raise ValueError("Duplicate or out-of-order timing marker")
    entry[action] = time.monotonic()
    path.write_text(json.dumps(data, indent=2) + "\n")


def durations(data):
    return {phase: round(entry["end"] - entry["begin"], 3) if "end" in entry else None
            for phase, entry in data.items()}


def build():
    # A cache hit NEVER skips compilation or changes build flags.
    mark("begin", "build")
    command = build_command(scratch_path())
    started = time.monotonic()
    with (RESULTS / "build.log").open("w") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True)
        for line in process.stdout:
            stamped = f"[{time.monotonic() - started:8.1f}s] {line}"
            print(stamped, end="", flush=True)
            log.write(stamped)
        code = process.wait()
    mark("end", "build")
    (RESULTS / "build.json").write_text(json.dumps({"exit_code": code, "command": command}) + "\n")
    raise SystemExit(code)


def report():
    if not RESULTS.exists():
        return
    timing_path = RESULTS / "timings.json"
    times = durations(json.loads(timing_path.read_text())) if timing_path.exists() else {}
    build_path = RESULTS / "build.json"
    data = json.loads(build_path.read_text()) if build_path.exists() else {"exit_code": None}
    data.update({"phase_seconds": times,
                 "event": os.environ["GITHUB_EVENT_NAME"],
                 "cache_matched_key": os.environ.get("CACHE_MATCHED_KEY", ""),
                 "cache_exact_hit": os.environ.get("CACHE_EXACT_HIT", ""),
                 "restore_outcome": os.environ.get("CACHE_RESTORE_OUTCOME", "skipped"),
                 "save_outcome": os.environ.get("CACHE_SAVE_OUTCOME", "skipped")})
    (RESULTS / "measurement.json").write_text(json.dumps(data, indent=2) + "\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write("## Release cache measurements\n\n")
        summary.write(f"Event: `{data['event']}`; build exit: `{data['exit_code']}`.\n\n")
        summary.write(f"Restored key: `{data['cache_matched_key'] or 'none (clean build)'}`.\n\n")
        summary.write(f"Restore: `{data['restore_outcome']}`; save: `{data['save_outcome']}`.\n\n")
        summary.write("| Phase | Seconds |\n| --- | ---: |\n")
        for phase, seconds in times.items():
            summary.write(f"| {phase} | {seconds if seconds is not None else 'INCOMPLETE'} |\n")
        summary.write("\nPipeline includes intervening steps and overlaps its phases; do not sum them. "
                      "Queue, checkout, preparation, reporting, and artifact upload are excluded.\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "build", "report", "begin", "end"))
    parser.add_argument("phase", nargs="?", choices=PHASES)
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        parser.error("This helper only runs on GitHub Actions")
    if args.action in ("begin", "end"):
        mark(args.action, args.phase)
    else:
        {"prepare": prepare, "build": build, "report": report}[args.action]()


if __name__ == "__main__":
    main()
