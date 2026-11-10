#!/usr/bin/env python3
"""Check the crash diagnostic runs every group even if one fails."""

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def main():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        binary = root / "swift"
        log = root / "invocations"
        (root / "muesli-test.metallib").write_bytes(b"fixture")
        binary.write_text("""#!/bin/bash
if [[ "$1" == build ]]; then
  printf '%s\\n' "$FAKE_BIN_PATH"
  exit 0
fi
if [[ "$1" == test ]]; then
  printf '%s\\n' "$*" >> "$FAKE_SWIFT_LOG"
  if [[ "$*" == *FeedbackCaptureInkTests* ]]; then
    echo 'error: Exited with unexpected signal code 11'
    exit 1
  fi
  exit 0
fi
exit 2
""")
        binary.chmod(0o755)
        env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                   FAKE_BIN_PATH=str(root), FAKE_SWIFT_LOG=str(log))
        env.pop("MUESLI_SWIFTPM_SCRATCH_PATH", None)
        result = subprocess.run(["python3", "scripts/diagnose_core_crash.py"], cwd=ROOT,
                                env=env, capture_output=True, text=True, check=True)
        assert "Diagnostic vidshot: exit status 1" in result.stdout, result.stdout
        for name in ("other-1", "other-2", "other-3"):
            assert f"Diagnostic {name}: exit status 0" in result.stdout, result.stdout
        assert "Crash reproduced in suite FeedbackCaptureInkTests" in result.stdout, result.stdout
        invocations = log.read_text().splitlines()
        assert len(invocations) > 4, invocations
        assert all("--skip-build" in line for line in invocations), invocations
    print("Core crash diagnostic execution verified.")


if __name__ == "__main__":
    main()
