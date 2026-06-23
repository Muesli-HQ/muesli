#!/usr/bin/env bash
set -euo pipefail

# Builds and launches an isolated dev app for end-to-end testing.
#
# - Separate bundle ID (com.muesli.dev*) — won't interfere with production Muesli
# - Separate data directory (~/Library/Application Support/MuesliDev*/)
# - Preserves existing dev config and database by default
# - Signed with Developer ID by default (Accessibility permission persists across rebuilds)
# - External contributors can set MUESLI_SKIP_SIGN=1 to build without the
#   maintainer signing certificate
# - Uses a shared, worktree-isolated SwiftPM scratch path by default; set
#   MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1 to use package-local .build instead
# - Installs to /Applications/MuesliDev*.app
#
# Usage:
#   ./scripts/dev-test.sh                         # Build and launch MuesliDev
#   ./scripts/dev-test.sh --lane A                # Build and launch MuesliDevA
#   ./scripts/dev-test.sh --lane A --local-only   # Omit iCloud/APNs entitlements
#   ./scripts/dev-test.sh --reset                 # Reset onboarding only (keeps data)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Build and launch a local Muesli dev app.

Options:
  --lane A|B|C            Build a fixed reusable dev lane: MuesliDevA/B/C.
  --local-only            Sign without iCloud/APNs entitlements.
                          Alias: --without-cloud-entitlements.
  --cloud-entitlements    Sign with the default cloud entitlements file.
                          Alias: --with-cloud-entitlements.
  --reset                 Reset onboarding only for the selected lane.
  --help                  Show this help text.

Default behavior without --lane is unchanged: MuesliDev, com.muesli.dev,
~/Library/Application Support/MuesliDev, and /Applications/MuesliDev.app.
Named lanes default to --local-only unless --cloud-entitlements is provided.
EOF
}

# Parse args
RESET=0
LANE=""
ENTITLEMENTS_MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      echo "Error: --clean has been removed because it deletes MuesliDev data." >&2
      echo "To test a fresh profile, create a named backup first and use a separate support directory." >&2
      exit 2
      ;;
    --reset)
      RESET=1
      shift
      ;;
    --lane)
      [[ $# -ge 2 ]] || { echo "Error: --lane requires A, B, or C." >&2; exit 2; }
      LANE="$2"
      shift 2
      ;;
    --lane=*)
      LANE="${1#--lane=}"
      shift
      ;;
    --local-only|--without-cloud-entitlements)
      ENTITLEMENTS_MODE="local-only"
      shift
      ;;
    --cloud-entitlements|--with-cloud-entitlements)
      ENTITLEMENTS_MODE="cloud"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$LANE" in
  "")
    DEV_APP_NAME="MuesliDev"
    DEV_BUNDLE_ID="com.muesli.dev"
    ;;
  A|a|B|b|C|c)
    LANE_UPPER="$(printf '%s' "$LANE" | tr '[:lower:]' '[:upper:]')"
    LANE_LOWER="$(printf '%s' "$LANE" | tr '[:upper:]' '[:lower:]')"
    DEV_APP_NAME="MuesliDev${LANE_UPPER}"
    DEV_BUNDLE_ID="com.muesli.dev.${LANE_LOWER}"
    ;;
  *)
    echo "Error: unsupported lane '$LANE'. Allowed lanes: A, B, C." >&2
    exit 2
    ;;
esac

if [[ -z "$ENTITLEMENTS_MODE" ]]; then
  if [[ -n "$LANE" ]]; then
    ENTITLEMENTS_MODE="local-only"
  else
    ENTITLEMENTS_MODE="cloud"
  fi
fi

DEV_SUPPORT_DIR="$HOME/Library/Application Support/$DEV_APP_NAME"
DEV_APP="/Applications/$DEV_APP_NAME.app"
ONBOARDING_PROGRESS_FILE="$DEV_SUPPORT_DIR/onboarding-progress.json"
BUILD_ENV=(
  MUESLI_APP_NAME="$DEV_APP_NAME"
  MUESLI_BUNDLE_ID="$DEV_BUNDLE_ID"
  MUESLI_SUPPORT_DIR_NAME="$DEV_APP_NAME"
  MUESLI_DISPLAY_NAME="$DEV_APP_NAME"
  MUESLI_SPARKLE_FEED_URL=""
)
if [[ -n "$LANE" ]]; then
  BUILD_ENV+=(MUESLI_EXECUTABLE_NAME="$DEV_APP_NAME")
fi

case "$ENTITLEMENTS_MODE" in
  local-only)
    BUILD_ENV+=(
      MUESLI_ENTITLEMENTS="$ROOT/scripts/MuesliLocalOnly.entitlements"
      MUESLI_PROVISIONING_PROFILE=""
      MUESLI_APS_ENVIRONMENT=""
    )
    ;;
  cloud)
    ;;
  *)
    echo "Error: internal unsupported entitlements mode '$ENTITLEMENTS_MODE'." >&2
    exit 2
    ;;
esac

# Kill any running dev instance
pkill -f "$DEV_APP" 2>/dev/null || true
sleep 0.5

# Reset onboarding only if requested
if [[ "$RESET" -eq 1 ]] && [[ -f "$DEV_SUPPORT_DIR/config.json" ]]; then
  echo "Resetting onboarding flag for $DEV_APP_NAME..."
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
echo "Building $DEV_APP_NAME (debug, signed)..."
echo "  Bundle ID:    $DEV_BUNDLE_ID"
echo "  Data:         $DEV_SUPPORT_DIR"
echo "  Entitlements: $ENTITLEMENTS_MODE"
env "${BUILD_ENV[@]}" "$ROOT/scripts/build_native_app.sh" debug

echo ""
echo "Launching $DEV_APP_NAME..."
open "$DEV_APP"

echo ""
echo "=== Dev Test Ready ==="
echo "  App: $DEV_APP"
echo "  Data: $DEV_SUPPORT_DIR"
echo "  DB: $DEV_SUPPORT_DIR/muesli.db"
echo ""
echo "Tips:"
if [[ -n "$LANE" ]]; then
  echo "  ./scripts/dev-test.sh --lane $LANE --reset    # Re-run onboarding for this lane (keep data)"
else
  echo "  ./scripts/dev-test.sh --reset                 # Re-run onboarding (keep data)"
fi
echo "  pkill -f \"$DEV_APP\"                         # Kill this dev app"
