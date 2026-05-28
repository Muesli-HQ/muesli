#!/usr/bin/env bash
set -euo pipefail

# Builds and launches an isolated "Sales Caddie Dev" app for end-to-end testing.
#
# - Separate bundle ID (com.muesli.dev) — won't interfere with production Muesli
# - Separate data directory (~/Library/Application Support/MuesliDev/)
# - Preserves existing dev config and database by default
# - Signed with Developer ID by default (Accessibility permission persists across rebuilds)
# - External contributors can set MUESLI_SKIP_SIGN=1 to build without the
#   maintainer signing certificate
# - Installs to /Applications/Sales Caddie Dev.app
#
# Usage:
#   ./scripts/dev-test.sh              # Build and launch
#   ./scripts/dev-test.sh --reset      # Reset onboarding only (keeps data)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_SUPPORT_DIR="$HOME/Library/Application Support/MuesliDev"
DEV_APP="/Applications/Sales Caddie Dev.app"
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
pkill -f "MuesliDev.app|Sales Caddie Dev.app" 2>/dev/null || true
sleep 0.5

# Remove the old pre-rename dev bundle. Keeping two app bundles with the same
# bundle ID makes macOS privacy panes show stale entries and reject grants.
rm -rf "/Applications/MuesliDev.app"

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

# If onboarding is already complete, discard transient resume state. This keeps
# rebuilds from reopening an old onboarding step after permissions/auth are set.
if [[ -f "$DEV_SUPPORT_DIR/config.json" ]]; then
  python3 - "$DEV_SUPPORT_DIR/config.json" "$ONBOARDING_PROGRESS_FILE" <<'PY'
import json
import sys
from pathlib import Path

config = Path(sys.argv[1])
progress = Path(sys.argv[2])
try:
    completed = bool(json.loads(config.read_text()).get("has_completed_onboarding"))
except Exception:
    completed = False

if completed and progress.exists():
    progress.unlink()
    print("Cleared stale onboarding progress.")
PY
fi

if [[ "${MUESLI_SKIP_SIGN:-0}" != "1" ]]; then
  DEFAULT_SIGN_IDENTITY="Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)"
  if ! security find-identity -v -p codesigning | grep -Fq "${MUESLI_SIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}"; then
    LOCAL_SIGN_IDENTITY="$("$ROOT/scripts/dev-ensure-local-codesign.sh")"
    export MUESLI_SIGN_IDENTITY="$LOCAL_SIGN_IDENTITY"
    export MUESLI_SIGN_KEYCHAIN="${MUESLI_LOCAL_SIGN_KEYCHAIN:-$HOME/Library/Keychains/muesli-dev.keychain-db}"
    export MUESLI_CODESIGN_TIMESTAMP="${MUESLI_CODESIGN_TIMESTAMP:-none}"
    export MUESLI_ENTITLEMENTS="${MUESLI_ENTITLEMENTS:-$ROOT/scripts/Muesli.dev.entitlements}"
    echo "Using local stable signing identity: $LOCAL_SIGN_IDENTITY"
  fi
fi

# Build with isolated identity
echo "Building Sales Caddie Dev (debug, signed)..."
MUESLI_APP_NAME="Sales Caddie Dev" \
MUESLI_APP_BUNDLE_NAME="Sales Caddie Dev.app" \
MUESLI_EXECUTABLE_NAME="Sales Caddie" \
MUESLI_BUNDLE_ID=com.muesli.dev \
MUESLI_SUPPORT_DIR_NAME=MuesliDev \
MUESLI_DISPLAY_NAME="Sales Caddie" \
MUESLI_SPARKLE_FEED_URL="" \
"$ROOT/scripts/build_native_app.sh" debug

echo ""
echo "Launching Sales Caddie Dev..."
open "$DEV_APP"

echo ""
echo "=== Dev Test Ready ==="
echo "  App: $DEV_APP"
echo "  Data: $DEV_SUPPORT_DIR"
echo "  DB: $DEV_SUPPORT_DIR/muesli.db"
echo ""
echo "Tips:"
echo "  ./scripts/dev-test.sh --reset    # Re-run onboarding (keep data)"
echo "  pkill -f 'Sales Caddie Dev'      # Kill dev app"
