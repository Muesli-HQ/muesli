#!/bin/bash
# Start the local benchmark host; captures schema and read-only permission checks.
set -euo pipefail
ref=05d14942609e907e3d3a3e09bf1886adeffacb9b
binary="${MUESLI_REFERENCE_DRIVER:-$HOME/Library/Caches/muesli-trycua/$ref/arm64/cua-driver}"
[[ -x "$binary" ]] || { echo "Missing pinned reference binary: $binary" >&2; exit 1; }
if pgrep -x MuesliDevA >/dev/null; then
  echo 'Quit DevA first so the explicit reference launch arguments take effect.' >&2
  exit 1
fi
open -g -a /Applications/MuesliDevA.app --args --trycua-probe-only --trycua-driver "$binary"
echo 'Reference evidence is written under /tmp/muesli-reference-<UUID>.'
echo 'This starts the read-only endpoint probe; use --trycua-driver without --trycua-probe-only for per-command routing.'
