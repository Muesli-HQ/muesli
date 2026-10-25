#!/usr/bin/env bash
# Private tester build. No stable/preprod feed, data directory, or publishing step.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Reuse this branch's warm cache for either preview identity, sequentially only.
export MUESLI_SWIFTPM_SCRATCH_CHANNEL="${MUESLI_SWIFTPM_SCRATCH_CHANNEL:-plus-preview}"
export MUESLI_XCODEBUILD_DERIVED_DATA="${MUESLI_XCODEBUILD_DERIVED_DATA:-$HOME/Library/Caches/muesli-spm/plus-preview/xcodebuild}"
export MUESLI_PLUS_PREVIEW=1
if [[ "${1:-}" == "--lane" ]]; then
  [[ "$#" == 2 && "$2" == "C" ]] || { echo "Usage: $0 --lane C" >&2; exit 2; }
  exec "$ROOT/scripts/dev-test.sh" --lane C --local-only
fi
export MUESLI_APP_NAME=MuesliPlusPreview
export MUESLI_DISPLAY_NAME="Muesli Plus Preview"
export MUESLI_APP_BUNDLE_NAME=MuesliPlusPreview.app
export MUESLI_EXECUTABLE_NAME=MuesliPlusPreview
export MUESLI_BUNDLE_ID=com.muesli.plus.preview
export MUESLI_SUPPORT_DIR_NAME=MuesliPlusPreview
export MUESLI_SPARKLE_FEED_URL=""
export MUESLI_SPARKLE_EDKEY=""
export MUESLI_TELEMETRYDECK_APP_ID=""
export MUESLI_TELEMETRY_CHANNEL=unconfigured
export MUESLI_USE_XCODE_BUILD=1
export MUESLI_ENTITLEMENTS="$ROOT/scripts/MuesliLocalOnly.entitlements"
export MUESLI_PROVISIONING_PROFILE=""
exec "$ROOT/scripts/build_native_app.sh" "${1:-debug}"
