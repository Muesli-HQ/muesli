#!/usr/bin/env bash
set -euo pipefail

# Creates a local Sales Caddie app bundle and DMG without requiring the full
# signed/notarized release pipeline. Use release.sh for customer distribution.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${MUESLI_INSTALL_DIR:-$ROOT/dist-native/install}"
APP_PATH="$INSTALL_DIR/Sales Caddie.app"
OUTPUT_DIR="${MUESLI_DEV_DMG_DIR:-$ROOT/dist-native}"

mkdir -p "$INSTALL_DIR" "$OUTPUT_DIR"

MUESLI_APP_NAME="${MUESLI_APP_NAME:-Sales Caddie}" \
MUESLI_DISPLAY_NAME="${MUESLI_DISPLAY_NAME:-Sales Caddie}" \
MUESLI_APP_BUNDLE_NAME="${MUESLI_APP_BUNDLE_NAME:-Sales Caddie.app}" \
MUESLI_EXECUTABLE_NAME="${MUESLI_EXECUTABLE_NAME:-Sales Caddie}" \
MUESLI_SUPPORT_DIR_NAME="${MUESLI_SUPPORT_DIR_NAME:-Sales Caddie}" \
MUESLI_BUNDLE_ID="${MUESLI_BUNDLE_ID:-com.salescaddie.app.dev}" \
MUESLI_INSTALL_DIR="$INSTALL_DIR" \
MUESLI_SKIP_SIGN="${MUESLI_SKIP_SIGN:-1}" \
"$ROOT/scripts/build_native_app.sh" release

MUESLI_SKIP_DMG_SIGN="${MUESLI_SKIP_DMG_SIGN:-1}" "$ROOT/scripts/create_dmg.sh" "$APP_PATH" "$OUTPUT_DIR"

echo "Packaged Sales Caddie:"
echo "  App: $APP_PATH"
echo "  DMG: $OUTPUT_DIR/$(defaults read "$APP_PATH/Contents/Info" CFBundleDisplayName)-$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString).dmg"
