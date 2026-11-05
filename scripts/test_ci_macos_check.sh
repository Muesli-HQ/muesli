#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/scripts" "$fixture/bin" "$fixture/cache/localvqe"
cp "$ROOT/scripts/run_ci_macos_check.sh" "$fixture/scripts/"
printf '# fixture runtime revision\n' > "$fixture/scripts/build_localvqe.sh"
cat > "$fixture/scripts/test_packaged_cli.sh" <<'SH'
#!/usr/bin/env bash
test "$MUESLI_SWIFTPM_SCRATCH_PATH" = "$MUESLI_CI_CACHE_ROOT/debug"
test -d "$MUESLI_LOCALVQE_LIB_DIR"
exit "${SMOKE_RESULT:-0}"
SH
export MUESLI_CI_CACHE_ROOT="$fixture/cache"
python3 - "$fixture/cache/localvqe" <<'PY'
import os
from pathlib import Path
import sys
root = Path(sys.argv[1])
for n in range(5):
    entry = root / f"{n:064x}"
    entry.mkdir()
    os.utime(entry, (n + 1, n + 1))
(root / "keep-unrelated").mkdir()
PY
bash "$fixture/scripts/run_ci_macos_check.sh" cli-smoke
test "$(find "$fixture/cache/localvqe" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 4
test -d "$fixture/cache/localvqe/keep-unrelated"
test ! -e "$fixture/cache/localvqe/.lock"
if SMOKE_RESULT=17 bash "$fixture/scripts/run_ci_macos_check.sh" cli-smoke; then
  echo "Packaging failure was hidden" >&2; exit 1
else
  test "$?" = 17
fi
test ! -e "$fixture/cache/localvqe/.lock"
mkdir "$fixture/cache/localvqe/.lock"
if bash "$fixture/scripts/run_ci_macos_check.sh" cli-smoke; then
  echo "Concurrent cache access was allowed" >&2; exit 1
fi
rmdir "$fixture/cache/localvqe/.lock"
if bash "$fixture/scripts/run_ci_macos_check.sh" unknown; then
  echo "Unknown check was accepted" >&2; exit 1
fi
echo "macOS check failure propagation and cache retention passed"
