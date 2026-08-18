#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 5 ]]; then
  echo "usage: $0 <app> <Development|Production> <bundle-id> <container-id> <development|production>" >&2
  exit 2
fi

APP_PATH="$1"
EXPECTED_ENVIRONMENT="$2"
EXPECTED_BUNDLE_ID="$3"
EXPECTED_CONTAINER="$4"
EXPECTED_APS_ENVIRONMENT="$5"

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: app bundle not found: $APP_PATH" >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/muesli-cloud-entitlements.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ENTITLEMENTS_PLIST="$TEMP_DIR/entitlements.plist"
if ! codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PLIST" 2>/dev/null; then
  echo "ERROR: unable to extract signed app entitlements" >&2
  exit 1
fi

VALIDATOR_ARGS=(
  --entitlements "$ENTITLEMENTS_PLIST"
  --environment "$EXPECTED_ENVIRONMENT"
  --bundle-id "$EXPECTED_BUNDLE_ID"
  --container "$EXPECTED_CONTAINER"
  --aps-environment "$EXPECTED_APS_ENVIRONMENT"
)

PROFILE="$APP_PATH/Contents/embedded.provisionprofile"
if [[ -f "$PROFILE" ]]; then
  PROFILE_PLIST="$TEMP_DIR/profile.plist"
  if ! security cms -D -i "$PROFILE" > "$PROFILE_PLIST" 2>/dev/null; then
    if ! openssl smime -inform der -verify -noverify -in "$PROFILE" -out "$PROFILE_PLIST" >/dev/null 2>&1; then
      echo "ERROR: unable to decode embedded provisioning profile" >&2
      exit 1
    fi
  fi
  VALIDATOR_ARGS+=(--profile "$PROFILE_PLIST")
fi

python3 "$ROOT/scripts/verify_cloud_entitlements.py" "${VALIDATOR_ARGS[@]}"
