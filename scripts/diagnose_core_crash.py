#!/usr/bin/env python3
"""Narrow a crashed core shard without changing the required parallel run."""

import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
GROUP_NAMES = ("vidshot", "other-1", "other-2", "other-3")


def groups():
    output = subprocess.check_output(
        ["bash", "scripts/run_ci_test_shard.sh", "--list-filters", "core"],
        cwd=ROOT, text=True,
    )
    result = {name: [] for name in GROUP_NAMES}
    other_index = 0
    for name in output.splitlines():
        if name.startswith("FeedbackCapture") or name == "CapturesCLITests":
            result["vidshot"].append(name)
        else:
            result[GROUP_NAMES[1 + other_index % 3]].append(name)
            other_index += 1
    return result


def main():
    assigned = groups()
    if sys.argv[1:] == ["--list-groups"]:
        for group, names in assigned.items():
            for name in names:
                print(group, name)
        return
    if sys.argv[1:]:
        raise SystemExit("usage: diagnose_core_crash.py [--list-groups]")

    build_args = ["--package-path", "native/MuesliNative", "--build-system", "native"]
    scratch = os.environ.get("MUESLI_SWIFTPM_SCRATCH_PATH")
    if scratch:
        build_args += ["--scratch-path", scratch]
    bin_path = Path(subprocess.check_output(
        ["swift", "build", *build_args, "--show-bin-path"], cwd=ROOT, text=True,
    ).strip())
    metallibs = list(bin_path.glob("**/mlx-swift_Cmlx.bundle/**/default.metallib"))
    metallib = metallibs[0] if metallibs else bin_path / "muesli-test.metallib"
    if not metallib.is_file():
        raise SystemExit("Core diagnostic cannot find the prebuilt MLX test metallib")
    env = dict(os.environ, MUESLI_MLX_EVAL_METALLIB=str(metallib))
    env.pop("MUESLI_CLEANUP_EVALUATION_ONLY", None)

    deadline = time.monotonic() + 420

    def run_group(group, names):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            print(f"Diagnostic {group}: time budget exhausted", flush=True)
            return False
        if not names:
            raise SystemExit(f"Empty diagnostic group: {group}")
        command = ["swift", "test", *build_args, "--skip-build"]
        for name in names:
            command += ["--filter", name]
        print(f"::group::Core crash diagnostic: {group} ({len(names)} suites)", flush=True)
        print("Suites:", ", ".join(names), flush=True)
        with tempfile.TemporaryFile(mode="w+t") as output:
            process = subprocess.Popen(command, cwd=ROOT, env=env, start_new_session=True,
                                       stdout=output, stderr=subprocess.STDOUT)
            try:
                status = process.wait(timeout=min(120, remaining))
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                status = None
            output.seek(0)
            log = output.read()
        print(log, end="", flush=True)
        if status is None:
            print(f"Diagnostic {group}: timed out", flush=True)
        else:
            print(f"Diagnostic {group}: exit status {status}", flush=True)
        print("::endgroup::", flush=True)
        return status in (-signal.SIGSEGV, 128 + signal.SIGSEGV) or "unexpected signal code 11" in log

    crashed = [(group, names) for group, names in assigned.items() if run_group(group, names)]
    if not crashed:
        print("No isolated group reproduced the crash; checking Vidshot interactions.", flush=True)
        for group in GROUP_NAMES[1:]:
            names = assigned["vidshot"] + assigned[group]
            if run_group(f"vidshot+{group}", names):
                crashed.append((f"vidshot+{group}", names))

    while crashed and time.monotonic() < deadline:
        group, names = crashed.pop(0)
        if len(names) == 1:
            print(f"Crash reproduced in suite {names[0]}", flush=True)
            continue
        midpoint = len(names) // 2
        children = [(f"{group}/1", names[:midpoint]), (f"{group}/2", names[midpoint:])]
        reproduced = [(child, subset) for child, subset in children if run_group(child, subset)]
        if not reproduced:
            print(f"Crash did not reproduce in either half of {group}; interaction or flakiness remains possible.", flush=True)
        crashed.extend(reproduced)


if __name__ == "__main__":
    main()
