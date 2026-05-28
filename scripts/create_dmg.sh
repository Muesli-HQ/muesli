#!/usr/bin/env bash
set -euo pipefail

# Creates a signed DMG from the installed app bundle with a custom Finder
# window layout (dark background, icon positions, no toolbar/sidebar).
# Usage: ./scripts/create_dmg.sh [app_path] [output_dir]

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-/Applications/Muesli.app}"
OUTPUT_DIR="${2:-$ROOT/dist-release}"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)}"
SKIP_DMG_SIGN="${MUESLI_SKIP_DMG_SIGN:-0}"
BACKGROUND_DIR="$ROOT/scripts/assets"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found: $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$BACKGROUND_DIR/dmg-background.png" ]]; then
  echo "DMG background not found: $BACKGROUND_DIR/dmg-background.png" >&2
  echo "Run: python3 scripts/generate_dmg_background.py" >&2
  exit 1
fi

# Extract version from Info.plist
VERSION=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "0.0.0")
APP_NAME=$(defaults read "$APP_PATH/Contents/Info" CFBundleDisplayName 2>/dev/null || echo "Muesli")
export MUESLI_DMG_APP_NAME="$APP_NAME"
APP_BUNDLE_NAME="$(basename "$APP_PATH")"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
APPLESCRIPT_APP_NAME=$(APPLESCRIPT_VALUE="$APP_NAME" python3 - <<'PY'
import os

value = os.environ["APPLESCRIPT_VALUE"]
print('"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"')
PY
)
APPLESCRIPT_APP_BUNDLE_NAME=$(APPLESCRIPT_VALUE="$APP_BUNDLE_NAME" python3 - <<'PY'
import os

value = os.environ["APPLESCRIPT_VALUE"]
print('"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"')
PY
)

mkdir -p "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
TEMP_DMG="$OUTPUT_DIR/_temp_${DMG_NAME}"

# Clean up any previous DMG
rm -f "$DMG_PATH" "$TEMP_DMG"

echo "Creating DMG: $DMG_NAME"

# P1 fix: track mount point so the EXIT trap can detach it if anything fails mid-flight.
MOUNT_POINT=""
STAGING=$(mktemp -d)

cleanup() {
  rm -rf "$STAGING"
  if [[ -n "${MOUNT_POINT}" ]]; then
    hdiutil detach "${MOUNT_POINT}" -force -quiet 2>/dev/null || true
  fi
}
trap cleanup EXIT

# App bundle + Applications symlink
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Background images (hidden folder — macOS Finder reads .background/)
mkdir -p "$STAGING/.background"
cp "$BACKGROUND_DIR/dmg-background.png"    "$STAGING/.background/dmg-background.png"
cp "$BACKGROUND_DIR/dmg-background@2x.png" "$STAGING/.background/dmg-background@2x.png"

# Create writable DMG from staging
hdiutil create -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDRW \
  "$TEMP_DMG"

# P1 fix: write plist to a temp file to avoid binary data corruption in bash variables.
ATTACH_PLIST_FILE=$(mktemp /tmp/hdiutil_attach_XXXXX.plist)
hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen -plist > "$ATTACH_PLIST_FILE" 2>/dev/null
MOUNT_POINT=$(python3 -c "
import plistlib
with open('$ATTACH_PLIST_FILE', 'rb') as f:
    data = plistlib.load(f)
for entity in data.get('system-entities', []):
    mp = entity.get('mount-point', '')
    if mp.startswith('/Volumes'):
        print(mp)
        break
")
rm -f "$ATTACH_PLIST_FILE"

if [[ -z "$MOUNT_POINT" ]]; then
  echo "ERROR: Could not mount writable DMG for window configuration" >&2
  exit 1
fi

echo "Configuring Finder window at: $MOUNT_POINT"
# Wait briefly for Finder to register the mounted volume. If Finder is slow or
# unavailable, the AppleScript block below fails non-fatally and the DMG remains usable.
open "$MOUNT_POINT" >/dev/null 2>&1 || true
sleep 1

# Configure Finder window via AppleScript:
#   - 1080×760pt window (full artboard size), icon size 152
#   - Custom dark background from .background/dmg-background.png (@2x Retina at 2160×1520)
#   - App icon at left (260, 313), Applications symlink at right (820, 313)
#   - No toolbar, no sidebar, icon view
#   - Bounds set 3× (before first close, after re-open, after update) to ensure it sticks
#
# P1 fix: AppleScript requires a GUI session and Automation TCC consent.
# On headless CI this can fail with -1743. Treat as a non-fatal warning so
# the release pipeline continues — the DMG is functional, just with default layout.
if ! osascript <<APPLESCRIPT
tell application "Finder"
  tell disk ${APPLESCRIPT_APP_NAME}
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    set the bounds of container window to {100, 100, 1180, 860}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 152
    set text size of theViewOptions to 10
    set label position of theViewOptions to bottom
    set background picture of theViewOptions to file ".background:dmg-background.png"
    set position of item ${APPLESCRIPT_APP_BUNDLE_NAME} of container window to {260, 305}
    set position of item "Applications" of container window to {820, 305}
    set the bounds of container window to {100, 100, 1180, 860}
    close
    open
    set the bounds of container window to {100, 100, 1180, 860}
    update without registering applications
    delay 5
    set the bounds of container window to {100, 100, 1180, 860}
    close
  end tell
end tell
APPLESCRIPT
then
  echo "WARNING: Finder window configuration skipped (no GUI session or Automation permission)" >&2
  echo "  DMG will open with default Finder layout. Grant Terminal Automation access to enable." >&2
fi

sync

# P1 fix: retry detach — Spotlight or Finder can hold the volume briefly.
DETACH_OK=false
for attempt in 1 2 3; do
  if hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null; then
    DETACH_OK=true
    break
  fi
  sleep 2
  hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null && DETACH_OK=true && break
done
if [[ "$DETACH_OK" != true ]]; then
  echo "ERROR: Could not detach $MOUNT_POINT after 3 attempts" >&2
  exit 1
fi
MOUNT_POINT=""  # already detached — prevent double-detach in cleanup trap

# Convert to compressed read-only DMG
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_PATH"
rm -f "$TEMP_DMG"

if [[ "$SKIP_DMG_SIGN" != "1" ]]; then
  # Sign the DMG
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
  echo "Signed with: $SIGN_IDENTITY"
else
  echo "DMG signing skipped for local/internal build."
fi

echo "DMG created: $DMG_PATH ($(du -sh "$DMG_PATH" | cut -f1))"
