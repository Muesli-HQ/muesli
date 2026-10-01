#!/usr/bin/env python3
"""Isolated SwiftPM release-cache benchmark; never used by the required CI gate."""

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
PROBE = PACKAGE / "Sources/MuesliNativeApp/AboutView.swift"
MARKER = "About — CI cache invalidation probe"
SCENARIOS = ("cold", "raw", "unchanged", "edited", "raw-edited")
PHASES = ("pipeline", "cache-save", "cache-restore", "input-validation", "snapshot", "probe-edit")


def mark_phase(action, phase, results=Path("ci-cache-results")):
    """Use the same host's monotonic clock across workflow steps."""
    if action not in ("begin", "end") or phase not in PHASES:
        raise ValueError("Unknown timing marker")
    path = results / "timings.json"
    timings = json.loads(path.read_text()) if path.exists() else {}
    entry = timings.setdefault(phase, {})
    if action in entry or (action == "end" and "begin" not in entry):
        raise ValueError("Duplicate or out-of-order timing marker")
    entry[action] = time.monotonic()
    path.write_text(json.dumps(timings, indent=2) + "\n")


def phase_durations(timings):
    durations = {}
    for name, entry in timings.items():
        if "end" not in entry:
            durations[name] = None  # Never misreport a failed/incomplete phase as free.
        else:
            elapsed = entry["end"] - entry["begin"]
            if elapsed < 0:
                raise ValueError("Non-monotonic phase timing")
            durations[name] = round(elapsed, 3)
    return durations


def report():
    results = Path("ci-cache-results")
    path = results / "measurement.json"
    if not path.exists():
        print("No build measurement; see failing setup/cache step and timings.json")
        return
    measurement = json.loads(path.read_text())
    timings_path = results / "timings.json"
    timings = json.loads(timings_path.read_text()) if timings_path.exists() else {}
    durations = phase_durations(timings)
    measurement["phase_seconds"] = durations
    measurement["timing_scope"] = (
        "pipeline includes restore/save, timestamp work, edit, build, binary validation, "
        "and intervening steps; excludes runner queue, checkout, prepare, report/artifact upload"
    )
    path.write_text(json.dumps(measurement, indent=2) + "\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write(f"## {measurement['scenario']}\n\n")
        summary.write(f"Build: {measurement['build_seconds']:.1f}s; exit: {measurement['exit_code']}.\n\n")
        summary.write("| Measured phase | Seconds |\n| --- | ---: |\n")
        for name, seconds in durations.items():
            value = "INCOMPLETE" if seconds is None else f"{seconds:.1f}"
            summary.write(f"| {name} | {value} |\n")
        summary.write(f"\n{measurement['timing_scope']}. Phases overlap with pipeline; do not sum them.\n\n")
        summary.write(f"Compile progress counts: `{measurement['compile_progress_counts']}`\n\n")
        summary.write(f"Edited binary verified: `{measurement.get('edited_binary_verified')}`\n")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def capture(command):
    return subprocess.check_output(command, text=True).strip()


def scratch_path():
    return Path.home() / "Library/Caches/muesli-spm/ci-cache-experiment/release"


def emit_output(name, value):
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write(f"{name}={value}\n")


def prepare(scenario):
    scratch = scratch_path()
    if scratch.exists():
        raise RuntimeError("Expected a fresh runner with no experiment scratch directory")
    facts = {
        "architecture": platform.machine(),
        "os": platform.mac_ver()[0],
        "image": os.environ.get("ImageVersion", "unknown"),
        "xcode": capture(["xcodebuild", "-version"]),
        "swift": capture(["swift", "--version"]),
        "sdk": capture(["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
        "sdk_path": capture(["xcrun", "--sdk", "macosx", "--show-sdk-path"]),
        "workspace": str(Path.cwd()),
        "scratch": str(scratch),
        "configuration": "release",
        "product": "MuesliNativeApp",
        "manifest": digest(PACKAGE / "Package.swift"),
        "lockfile": digest(PACKAGE / "Package.resolved"),
        "harness": digest(Path(__file__)),
    }
    fingerprint = hashlib.sha256(json.dumps(facts, sort_keys=True).encode()).hexdigest()
    # Run-scoped keys cannot become a shared main/release cache accidentally.
    key = f"experiment-spm-v1-{fingerprint}-{os.environ['GITHUB_RUN_ID']}-{os.environ['GITHUB_RUN_ATTEMPT']}"
    emit_output("scratch", scratch)
    emit_output("fingerprint", fingerprint)
    emit_output("cache_key", key)
    results = Path("ci-cache-results")
    results.mkdir(exist_ok=True)
    (results / "environment.json").write_text(json.dumps(facts, indent=2) + "\n")
    print(f"Scenario: {scenario}\nCache key: {key}\n{json.dumps(facts, indent=2)}")


def safe_file(root, relative):
    """Reject traversal, absolute paths and symlinks from restored metadata."""
    path = root / relative
    if Path(relative).is_absolute() or ".." in Path(relative).parts:
        raise ValueError(f"Unsafe input path: {relative}")
    if not path.is_file() or path.is_symlink():
        return None
    if not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Input escapes root: {relative}")
    return path


def input_roots():
    return {"package": PACKAGE, "dependencies": scratch_path() / "checkouts"}


def snapshot():
    records = {}
    roots = input_roots()
    tracked = subprocess.check_output(["git", "ls-files", "-z", "--", str(PACKAGE)])
    paths = [Path(os.fsdecode(name)) for name in tracked.split(b"\0") if name]
    records["package"] = snapshot_files(roots["package"], paths)
    dep_root = roots["dependencies"]
    paths = [p for p in dep_root.rglob("*") if ".git" not in p.relative_to(dep_root).parts]
    records["dependencies"] = snapshot_files(dep_root, paths)
    (scratch_path() / "benchmark-inputs.json").write_text(json.dumps(records))


def snapshot_files(root, paths):
    records = {}
    for path in paths:
        relative = str(path.relative_to(root))
        if safe_file(root, relative) is not None:
            records[relative] = {"sha256": digest(path), "mtime_ns": path.stat().st_mtime_ns}
    return records


def restore_files(root, records):
    restored = 0
    for relative, record in records.items():
        path = safe_file(root, relative)
        # A real edit never inherits the cached file's timestamp.
        if path is not None and digest(path) == record["sha256"]:
            os.utime(path, ns=(path.stat().st_atime_ns, record["mtime_ns"]))
            restored += 1
    return restored


def restore_inputs():
    records = json.loads((scratch_path() / "benchmark-inputs.json").read_text())
    for name, root in input_roots().items():
        print(f"Restored timestamps: {name}: {restore_files(root, records[name])}")


def edit_source(path=PROBE):
    source = path.read_text()
    old = 'Text("About")'
    if source.count(old) != 1:
        raise RuntimeError("Expected exactly one source probe location")
    path.write_text(source.replace(old, f'Text("{MARKER}")'))


def compile_counts(lines):
    counts = {"app": 0, "c_family": 0, "swift_syntax": 0, "other": 0}
    for line in lines:
        match = re.search(r"\] Compiling (.+)", line)
        if not match:
            continue
        detail = match.group(1)
        if detail.startswith("MuesliNativeApp "):
            counts["app"] += 1
        elif re.search(r"\.(cpp|cc|m)$", detail):
            # Approximate C-family progress count, not exclusive MLX timing.
            counts["c_family"] += 1
        elif detail.startswith(("SwiftSyntax", "SwiftParser", "SwiftCompilerPlugin")):
            counts["swift_syntax"] += 1
        else:
            counts["other"] += 1
    return counts


def build(scenario):
    results = Path("ci-cache-results")
    results.mkdir(exist_ok=True)
    command = ["swift", "build", "--package-path", str(PACKAGE), "--scratch-path",
               str(scratch_path()), "-c", "release", "--product", "MuesliNativeApp",
               "--force-resolved-versions"]
    started = time.monotonic()
    lines = []
    with (results / "build.log").open("w") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1)
        for line in process.stdout:
            elapsed = time.monotonic() - started
            log.write(f"{elapsed:10.3f}s {line}")
            log.flush()
            print(line, end="", flush=True)
            lines.append(line)
        code = process.wait()
    elapsed = time.monotonic() - started
    counts = compile_counts(lines)
    measurement = {"scenario": scenario, "build_seconds": round(elapsed, 3),
                   "exit_code": code, "compile_progress_counts": counts,
                   "command": command}
    (results / "measurement.json").write_text(json.dumps(measurement, indent=2) + "\n")
    if code:
        raise SystemExit(code)
    if scenario in ("edited", "raw-edited") and counts["app"] == 0:
        raise RuntimeError("Edited app source did not trigger app recompilation")
    # Never ship or execute this benchmark product. Inspect the edited binary to
    # catch falsely 'successful' reuse of the old app artifact.
    if scenario in ("edited", "raw-edited"):
        bin_command = command[:-1] + ["--show-bin-path"]
        binary = Path(capture(bin_command)) / "MuesliNativeApp"
        if MARKER.encode() not in binary.read_bytes():
            raise RuntimeError("Edited marker missing from rebuilt app binary")
        print("Verified edited marker in the rebuilt app binary")
        measurement["edited_binary_verified"] = True
        (results / "measurement.json").write_text(json.dumps(measurement, indent=2) + "\n")
    print(capture(["du", "-sh", str(scratch_path())]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "build", "snapshot", "restore-inputs", "edit", "begin", "end", "report"))
    parser.add_argument("value", nargs="?")
    args = parser.parse_args()
    if os.environ.get("GITHUB_ACTIONS") != "true":
        parser.error("Run only on an ephemeral GitHub Actions runner; use the unit tests locally")
    if args.action in ("prepare", "build"):
        if args.value not in SCENARIOS:
            parser.error("valid scenario required")
        {"prepare": prepare, "build": build}[args.action](args.value)
    elif args.action in ("begin", "end"):
        mark_phase(args.action, args.value)
    else:
        {"snapshot": snapshot, "restore-inputs": restore_inputs, "edit": edit_source, "report": report}[args.action]()


if __name__ == "__main__":
    main()
