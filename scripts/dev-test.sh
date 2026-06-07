#!/usr/bin/env bash
set -euo pipefail

# Builds and launches an isolated "MuesliDev" app for end-to-end testing.
#
# - Separate bundle ID (com.muesli.dev) — won't interfere with production Muesli
# - Separate data directory (~/Library/Application Support/MuesliDev/)
# - Preserves existing dev config and database by default
# - Signed with Developer ID by default (Accessibility permission persists across rebuilds)
# - External contributors can set MUESLI_SKIP_SIGN=1 to build without the
#   maintainer signing certificate
# - Uses a shared, worktree-isolated SwiftPM scratch path by default; set
#   MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1 to use package-local .build instead
# - Installs to /Applications/MuesliDev.app
#
# Usage:
#   ./scripts/dev-test.sh              # Build and launch
#   ./scripts/dev-test.sh --reset      # Reset onboarding only (keeps data)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_SUPPORT_DIR="$HOME/Library/Application Support/MuesliDev"
DEV_APP="/Applications/MuesliDev.app"
ONBOARDING_PROGRESS_FILE="$DEV_SUPPORT_DIR/onboarding-progress.json"

# Parse args
RESET=0
for arg in "$@"; do
  case "$arg" in
    --clean)
      echo "Error: --clean has been removed because it deletes MuesliDev data." >&2
      echo "To test a fresh profile, create a named backup first and use a separate support directory." >&2
      exit 2
      ;;
    --reset) RESET=1 ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

# Kill any running dev instance
pkill -f "MuesliDev.app" 2>/dev/null || true
sleep 0.5

# Reset onboarding only if requested
if [[ "$RESET" -eq 1 ]] && [[ -f "$DEV_SUPPORT_DIR/config.json" ]]; then
  echo "Resetting onboarding flag..."
  python3 -c "
import json, os, pathlib
p = pathlib.Path('$DEV_SUPPORT_DIR/config.json')
c = json.loads(p.read_text())
c['has_completed_onboarding'] = False
mode = p.stat().st_mode & 0o777
p.write_text(json.dumps(c, indent=2) + '\n')
os.chmod(p, mode)
progress = pathlib.Path('$ONBOARDING_PROGRESS_FILE')
if progress.exists():
    progress.unlink()
    print('  Cleared transient onboarding progress')
print('  Onboarding reset (data preserved)')
"
fi

# Build with isolated identity
echo "Building MuesliDev (debug, signed)..."
MUESLI_APP_NAME=MuesliDev \
MUESLI_BUNDLE_ID=com.muesli.dev \
MUESLI_SUPPORT_DIR_NAME=MuesliDev \
MUESLI_DISPLAY_NAME=MuesliDev \
MUESLI_SPARKLE_FEED_URL="" \
"$ROOT/scripts/build_native_app.sh" debug

echo ""
echo "Launching MuesliDev..."
open "$DEV_APP"

echo ""
echo "=== Dev Test Ready ==="
echo "  App: $DEV_APP"
echo "  Data: $DEV_SUPPORT_DIR"
echo "  DB: $DEV_SUPPORT_DIR/muesli.db"
echo ""
echo "Tips:"
echo "  ./scripts/dev-test.sh --reset    # Re-run onboarding (keep data)"
echo "  pkill -f MuesliDev               # Kill dev app"
