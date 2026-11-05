#!/usr/bin/env bash
# Private CI selects an exact PR revision before invoking these shared checks.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${MUESLI_CI_CACHE_ROOT:?Set a persistent cache root unique to this runner and toolchain}"
export MUESLI_SWIFTPM_SCRATCH_PATH="$MUESLI_CI_CACHE_ROOT/debug"
case "${1:-}" in
  core|dictation-transcription|meetings)
    bash scripts/run_ci_test_shard.sh "$1"
    ;;
  release)
    # Use the same product, configuration and dependency policy as hosted CI.
    python3 - "$MUESLI_CI_CACHE_ROOT/release" <<'PY'
import sys
import subprocess
from pathlib import Path
sys.path.insert(0, "scripts")
from ci_release_cache import build_command
subprocess.run(build_command(Path(sys.argv[1])), check=True)
PY
    ;;
  ai-elements)
    swift test --package-path native/AIElementsSwift --scratch-path "$MUESLI_CI_CACHE_ROOT/ai-elements"
    python3 native/AIElementsSwift/Scripts/generate_icons.py
    git diff --exit-code -- native/AIElementsSwift/Sources/AIElementsSwift/AIIcon.swift
    ;;
  cli-smoke)
    mkdir -p "$MUESLI_CI_CACHE_ROOT/localvqe"
    # Refuse concurrent use of this runner's LocalVQE cache during pruning/builds.
    lock="$MUESLI_CI_CACHE_ROOT/localvqe/.lock"
    mkdir "$lock" || { echo "LocalVQE cache is already in use" >&2; exit 1; }
    trap 'rmdir "$lock"' EXIT
    fingerprint="$(shasum -a 256 scripts/build_localvqe.sh | cut -d ' ' -f 1)"
    export LOCALVQE_REPO="$MUESLI_CI_CACHE_ROOT/localvqe/$fingerprint/source"
    export MUESLI_LOCALVQE_LIB_DIR="$MUESLI_CI_CACHE_ROOT/localvqe/$fingerprint/lib"
    mkdir -p "$(dirname "$LOCALVQE_REPO")"
    python3 - "$MUESLI_CI_CACHE_ROOT/localvqe" "$fingerprint" <<'PY'
from pathlib import Path
import os
import re
import shutil
import sys
root, current = Path(sys.argv[1]), sys.argv[2]
entries = [p for p in root.iterdir() if re.fullmatch(r"[0-9a-f]{64}", p.name)
           and p.is_dir() and not p.is_symlink() and p.name != current]
for old in sorted(entries, key=lambda p: p.stat().st_mtime, reverse=True)[2:]:
    shutil.rmtree(old)
(root / current).mkdir(exist_ok=True)
os.utime(root / current, None)
PY
    bash scripts/test_packaged_cli.sh
    ;;
  *)
    echo "Unknown macOS check: ${1:-}" >&2
    exit 2
    ;;
esac
