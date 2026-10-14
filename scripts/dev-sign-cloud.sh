#!/usr/bin/env bash
set -euo pipefail

# Re-signs an installed dev app with iCloud (CloudKit) and APNs entitlements from a provisioning
# profile, using the signing identity you give it. Use it after ./scripts/dev-test.sh when the app
# is built unsigned (MUESLI_SKIP_SIGN=1), which is the only path that works without the LocalVQE
# runtime. The signing identity stays the same across rebuilds, so macOS permissions persist.
#
#   MUESLI_DEV_BUNDLE_ID=com.example.muesli.dev MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh
#   MUESLI_SIGN_IDENTITY="Apple Development: Name (TEAMID)" \
#   MUESLI_PROVISIONING_PROFILE=/path/to/Mac.provisionprofile \
#   MUESLI_ICLOUD_CONTAINER_ID=iCloud.com.example.muesli \
#   MUESLI_ICLOUD_CONTAINER_ENVIRONMENT=Development \
#   ./scripts/dev-sign-cloud.sh [/Applications/MuesliDev.app]
#
# The profile must be for the app's bundle id, list the container (the whole identifier, not a
# prefix of one) and permit the CloudKit environment. Create one with Xcode's automatic signing (a
# stub app with the same bundle id and entitlements and -allowProvisioningUpdates).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-/Applications/MuesliDev.app}"
IDENTITY="${MUESLI_SIGN_IDENTITY:?set MUESLI_SIGN_IDENTITY}"
PROFILE="${MUESLI_PROVISIONING_PROFILE:?set MUESLI_PROVISIONING_PROFILE}"
CONTAINER="${MUESLI_ICLOUD_CONTAINER_ID:?set MUESLI_ICLOUD_CONTAINER_ID}"
ENVIRONMENT="${MUESLI_ICLOUD_CONTAINER_ENVIRONMENT:-Development}"
BASE_ENTITLEMENTS="${MUESLI_ENTITLEMENTS:-$ROOT/scripts/MuesliLocalOnly.entitlements}"

case "$(printf '%s' "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]')" in
  development) ENVIRONMENT="Development" ;;
  production) ENVIRONMENT="Production" ;;
  *) echo "ERROR: MUESLI_ICLOUD_CONTAINER_ENVIRONMENT must be Development or Production." >&2; exit 2 ;;
esac

[[ -d "$APP" ]] || { echo "ERROR: app not found: $APP" >&2; exit 1; }
[[ -f "$PROFILE" ]] || { echo "ERROR: profile not found: $PROFILE" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/muesli-cloud-sign.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PROFILE_PLIST="$WORK/profile.plist"
ENTITLEMENTS="$WORK/entitlements.plist"
security cms -D -i "$PROFILE" > "$PROFILE_PLIST" 2>/dev/null \
  || { echo "ERROR: could not decode profile $PROFILE" >&2; exit 1; }

profile_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$PROFILE_PLIST" 2>/dev/null || true; }
APP_IDENTIFIER="$(profile_value Entitlements:com.apple.application-identifier)"
TEAM_ID="$(profile_value Entitlements:com.apple.developer.team-identifier)"
APS_ENVIRONMENT="$(profile_value Entitlements:com.apple.developer.aps-environment)"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"

# profile_list_has <entitlement> <value>: true when the profile's entitlement, an array or a plain
# string, holds <value> as a whole element. Never a substring match: a profile that lists
# iCloud.com.example.muesli.dev does not grant iCloud.com.example.muesli.
profile_list_has() {
  local key="Entitlements:$1" want="$2" value i=0
  if ! value="$(/usr/libexec/PlistBuddy -c "Print :$key:0" "$PROFILE_PLIST" 2>/dev/null)"; then
    [[ "$(profile_value "$key")" == "$want" ]]
    return
  fi
  while value="$(/usr/libexec/PlistBuddy -c "Print :$key:$i" "$PROFILE_PLIST" 2>/dev/null)"; do
    [[ "$value" == "$want" ]] && return 0
    i=$((i + 1))
  done
  return 1
}

if [[ -z "$APP_IDENTIFIER" || -z "$TEAM_ID" ]]; then
  echo "ERROR: profile has no application identifier or no team identifier." >&2
  exit 1
fi
if [[ "${APP_IDENTIFIER#*.}" != "$BUNDLE_ID" ]]; then
  echo "ERROR: profile is for '${APP_IDENTIFIER#*.}' but the app is '$BUNDLE_ID'." >&2
  exit 1
fi
if ! profile_list_has com.apple.developer.icloud-container-identifiers "$CONTAINER"; then
  echo "ERROR: profile does not list container $CONTAINER." >&2
  exit 1
fi
if ! profile_list_has com.apple.developer.icloud-container-environment "$ENVIRONMENT"; then
  echo "ERROR: profile does not permit CloudKit environment $ENVIRONMENT." >&2
  exit 1
fi

# Every key is deleted before it is added, so a base file that already carries it (such as
# scripts/Muesli.entitlements) is overridden instead of making PlistBuddy fail on a duplicate.
cp "$BASE_ENTITLEMENTS" "$ENTITLEMENTS"
plist() { /usr/libexec/PlistBuddy -c "$1" "$ENTITLEMENTS"; }
plist_replace() {
  local key="$1" type="$2"
  shift 2
  plist "Delete :$key" >/dev/null 2>&1 || true
  if [[ "$type" == array ]]; then
    plist "Add :$key array"
    local i=0 element
    for element in "$@"; do
      plist "Add :$key:$i string $element"
      i=$((i + 1))
    done
  else
    plist "Add :$key $type $1"
  fi
}
plist_replace com.apple.application-identifier string "$APP_IDENTIFIER"
plist_replace com.apple.developer.team-identifier string "$TEAM_ID"
plist_replace com.apple.developer.icloud-container-identifiers array "$CONTAINER"
plist_replace com.apple.developer.icloud-services array CloudKit
plist_replace com.apple.developer.icloud-container-environment string "$ENVIRONMENT"
if [[ -n "$APS_ENVIRONMENT" ]]; then
  plist_replace com.apple.developer.aps-environment string "$APS_ENVIRONMENT"
else
  # The profile does not grant APNs, so a leftover entitlement would fail launch validation.
  plist "Delete :com.apple.developer.aps-environment" >/dev/null 2>&1 || true
fi

# Stop the running copy. The pattern is anchored and regex-escaped so it matches only this app.
APP_PATTERN="$(printf '%s' "$(cd "$APP" && pwd)" | sed 's/[][\.*^$+?(){}|\/]/\\&/g')"
pkill -f "^$APP_PATTERN/Contents/MacOS/" 2>/dev/null || true
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# Nested code first with the identity only, then the app itself with the entitlements.
codesign --force --deep --timestamp=none --sign "$IDENTITY" \
  --preserve-metadata=identifier,flags "$APP"
codesign --force --timestamp=none --sign "$IDENTITY" \
  --entitlements "$ENTITLEMENTS" --preserve-metadata=identifier,flags "$APP"
codesign --verify --deep --strict "$APP"

echo "Signed $APP as $BUNDLE_ID"
echo "  container:   $CONTAINER ($ENVIRONMENT)"
echo "  aps:         ${APS_ENVIRONMENT:-none}"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | grep -E "icloud|aps|application-identifier|team-identifier"
