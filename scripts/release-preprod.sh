#!/usr/bin/env bash
set -euo pipefail

# Pre-production Sparkle release pipeline.
#
# This is the safe end-to-end updater channel for testing Sparkle before a
# stable release. It intentionally does not touch the production appcast,
# landing page, llms.txt, or Homebrew tap.
#
# It builds:
#   - App name: MuesliPreprod
#   - Bundle ID: com.muesli.preprod
#   - Support dir: ~/Library/Application Support/MuesliPreprod
#   - Sparkle feed: https://muesli-hq.github.io/muesli/appcast-preprod.xml
#
# Usage: ./scripts/release-preprod.sh [version]
#   e.g. ./scripts/release-preprod.sh 0.6.3-preprod.1
#   If no version is given, auto-increments from the next stable patch base.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/muesli_spm_cache.sh"

PACKAGE_DIR="$ROOT/native/MuesliNative"
SWIFTPM_SCRATCH_PATH=""
SWIFT_TEST_ARGS=(--package-path "$PACKAGE_DIR")
BUILD_ENV=()
# The preprod channel is intentionally shared across worktrees. Do not run this
# script concurrently from multiple worktrees unless you set an isolated
# MUESLI_SWIFTPM_SCRATCH_PATH or MUESLI_SWIFTPM_SCRATCH_CHANNEL.
if ! muesli_spm_scratch_disabled; then
  SWIFTPM_SCRATCH_PATH="$(muesli_resolve_spm_scratch_path preprod)"
  SWIFT_TEST_ARGS+=(--scratch-path "$SWIFTPM_SCRATCH_PATH")
  BUILD_ENV+=(MUESLI_SWIFTPM_SCRATCH_PATH="$SWIFTPM_SCRATCH_PATH")
else
  BUILD_ENV+=(MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1)
fi
PROFILE_NAME="${MUESLI_NOTARY_PROFILE:-MuesliNotary}"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)}"
APP_NAME="MuesliPreprod"
BUNDLE_ID="com.muesli.preprod"
SUPPORT_DIR_NAME="MuesliPreprod"
PREPROD_FEED_URL="https://muesli-hq.github.io/muesli/appcast-preprod.xml"
OUTPUT_DIR="$ROOT/dist-preprod"
INSTALL_DIR="$OUTPUT_DIR/install-root"
APP_DIR="$INSTALL_DIR/${APP_NAME}.app"
APPCAST_PATH="$ROOT/docs/appcast-preprod.xml"
GENERATE_APPCAST="$(muesli_spm_artifacts_dir "$PACKAGE_DIR" "$SWIFTPM_SCRATCH_PATH")/sparkle/Sparkle/bin/generate_appcast"
UPDATE_APPCAST_RELEASE_NOTES="$ROOT/scripts/update_appcast_release_notes.py"
VERIFY_DIR=""
HOSTED_MOUNT_POINT=""

cleanup() {
  if [[ -n "$HOSTED_MOUNT_POINT" ]]; then
    hdiutil detach "$HOSTED_MOUNT_POINT" -quiet 2>/dev/null || true
  fi
  if [[ -n "$VERIFY_DIR" && -d "$VERIFY_DIR" ]]; then
    rm -rf "$VERIFY_DIR"
  fi
}

trap cleanup EXIT

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  LATEST_STABLE=$(gh release list --limit 30 --json tagName,isPrerelease \
    -q '[.[] | select(.isPrerelease == false)] | .[0].tagName' 2>/dev/null || echo "")

  if [[ -z "$LATEST_STABLE" ]]; then
    echo "ERROR: Could not determine latest stable release from GitHub." >&2
    exit 1
  fi

  LATEST_STABLE_VERSION="${LATEST_STABLE#v}"
  IFS='.' read -r MAJOR MINOR PATCH <<< "$LATEST_STABLE_VERSION"
  PATCH="${PATCH%%[-+]*}"
  NEXT_PATCH=$((PATCH + 1))
  BASE="${MAJOR}.${MINOR}.${NEXT_PATCH}"

  LATEST_N=$(gh release list --limit 100 --json tagName,isPrerelease \
    -q "[.[] | select(.isPrerelease == true) | .tagName \
        | select(startswith(\"v${BASE}-preprod.\")) \
        | ltrimstr(\"v${BASE}-preprod.\") \
        | tonumber] | max // 0" 2>/dev/null || echo "0")

  NEXT_N=$((LATEST_N + 1))
  VERSION="${BASE}-preprod.${NEXT_N}"

  echo "Latest stable:   ${LATEST_STABLE}"
  echo "Proposed preprod: v${VERSION}"
  echo ""
  read -p "Release as v${VERSION}? [Y/n] " confirm
  if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
    read -p "Enter version: " VERSION
  fi
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: Working tree must be clean before running the preprod release pipeline." >&2
  exit 1
fi

if [[ ! -f "$UPDATE_APPCAST_RELEASE_NOTES" ]]; then
  echo "ERROR: update_appcast_release_notes.py not found at $UPDATE_APPCAST_RELEASE_NOTES" >&2
  exit 1
fi

TAG="v${VERSION}"
DMG_PATH="$OUTPUT_DIR/${APP_NAME}-${VERSION}.dmg"
RELEASE_TITLE="${APP_NAME} ${VERSION}"

if [[ ! "$VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-preprod\.([0-9]+)$ ]]; then
  echo "ERROR: preprod version must look like 0.6.3-preprod.1" >&2
  exit 1
fi
SPARKLE_BUILD_VERSION="$((10#${BASH_REMATCH[1]} * 100000000 + 10#${BASH_REMATCH[2]} * 1000000 + 10#${BASH_REMATCH[3]} * 1000 + 10#${BASH_REMATCH[4]}))"

RELEASE_NOTES="$(cat <<EOF
## ${APP_NAME} ${VERSION}

Pre-production build for validating the Sparkle update flow before a stable release.

### Install
1. Download \`${APP_NAME}-${VERSION}.dmg\`
2. Open the DMG and drag ${APP_NAME} to Applications
3. Launch ${APP_NAME} from Applications

### Notes
- Installs alongside production Muesli.
- Stores data separately in \`~/Library/Application Support/${SUPPORT_DIR_NAME}/\`.
- Uses the pre-production Sparkle feed: \`${PREPROD_FEED_URL}\`.
- Does not update the production appcast, public download page, or Homebrew tap.
EOF
)"

echo "=== ${APP_NAME} Preprod v${VERSION} ==="
echo ""

mkdir -p "$OUTPUT_DIR"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# --- Step 1: Run tests ---
echo "[1/11] Running tests..."
if [[ -n "$SWIFTPM_SCRATCH_PATH" ]]; then
  mkdir -p "$SWIFTPM_SCRATCH_PATH"
  echo "  SwiftPM scratch path: $SWIFTPM_SCRATCH_PATH"
else
  echo "  SwiftPM scratch path: package-local .build"
fi
swift test "${SWIFT_TEST_ARGS[@]}"
echo "  Tests passed."

# --- Step 2: Build and sign ---
echo "[2/11] Building and signing..."
PREPROD_BUILD_ENV=(
  MUESLI_INSTALL_DIR="$INSTALL_DIR"
  "${BUILD_ENV[@]}"
  MUESLI_BUILD_VERSION="$VERSION"
  MUESLI_BUNDLE_VERSION="$SPARKLE_BUILD_VERSION"
  MUESLI_SHORT_VERSION="$VERSION"
  MUESLI_APP_NAME="$APP_NAME"
  MUESLI_APP_BUNDLE_NAME="${APP_NAME}.app"
  MUESLI_BUNDLE_ID="$BUNDLE_ID"
  MUESLI_DISPLAY_NAME="$APP_NAME"
  MUESLI_SUPPORT_DIR_NAME="$SUPPORT_DIR_NAME"
  MUESLI_SPARKLE_FEED_URL="$PREPROD_FEED_URL"
  MUESLI_SIGN_IDENTITY="$SIGN_IDENTITY"
)
env "${PREPROD_BUILD_ENV[@]}" "$ROOT/scripts/build_native_app.sh" > /dev/null
echo "  Installed to $APP_DIR"
if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "ERROR: generate_appcast not found at $GENERATE_APPCAST" >&2
  exit 1
fi

FLAGS=$(codesign -dvvv "$APP_DIR" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)')
echo "  Signature: $FLAGS"

# --- Step 3: Notarize app bundle ---
echo "[3/11] Notarizing app bundle with Apple..."
APP_ZIP="$OUTPUT_DIR/${APP_NAME}-app-${VERSION}.zip"
ditto -c -k --keepParent "$APP_DIR" "$APP_ZIP"
NOTARY_OUTPUT=$(xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$PROFILE_NAME" \
  --wait 2>&1)
echo "$NOTARY_OUTPUT"
rm -f "$APP_ZIP"

if ! echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
  echo "  App notarization FAILED. Fetching log..."
  SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE_NAME" 2>&1
  exit 1
fi
echo "  App notarization accepted."

# --- Step 4: Staple app bundle ---
echo "[4/11] Stapling app bundle..."
xcrun stapler staple "$APP_DIR"
echo "  App stapled."

# --- Step 5: Create DMG ---
echo "[5/11] Creating DMG..."
"$ROOT/scripts/create_dmg.sh" "$APP_DIR" "$OUTPUT_DIR"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "ERROR: expected DMG not found at $DMG_PATH" >&2
  exit 1
fi

# --- Step 6: Notarize DMG ---
echo "[6/11] Notarizing DMG with Apple..."
NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$PROFILE_NAME" \
  --wait 2>&1)
echo "$NOTARY_OUTPUT"

if ! echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
  echo "  DMG notarization FAILED. Fetching log..."
  SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE_NAME" 2>&1
  exit 1
fi
echo "  DMG notarization accepted."

# --- Step 7: Staple and verify local DMG ---
echo "[7/11] Stapling and verifying local DMG..."
xcrun stapler staple "$DMG_PATH"

MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse 2>&1 | grep "/Volumes" | awk -F'\t' '{print $NF}')
if [[ -z "$MOUNT_POINT" ]]; then
  echo "ERROR: Could not mount DMG for verification." >&2
  exit 1
fi

SPCTL_RESULT=$(spctl -a -vv "$MOUNT_POINT/${APP_NAME}.app" 2>&1)
STAPLE_RESULT=$(xcrun stapler validate "$MOUNT_POINT/${APP_NAME}.app" 2>&1)
hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null

if ! echo "$SPCTL_RESULT" | grep -q "accepted"; then
  echo "  RELEASE ABORTED: App inside DMG rejected by Gatekeeper."
  exit 1
fi
if ! echo "$STAPLE_RESULT" | grep -q "worked"; then
  echo "  RELEASE ABORTED: App inside DMG missing valid staple."
  exit 1
fi

DMG_FLAGS=$(codesign -dvvv "$DMG_PATH" 2>&1)
if ! echo "$DMG_FLAGS" | grep -q "runtime"; then
  echo "  RELEASE ABORTED: DMG missing hardened runtime flag."
  exit 1
fi
echo "  Local DMG verified."

# --- Step 8: Tag ---
echo "[8/11] Tagging..."
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "ERROR: Local tag ${TAG} already exists." >&2
  exit 1
fi
if git ls-remote --tags origin "refs/tags/${TAG}" | grep -q .; then
  echo "ERROR: Remote tag ${TAG} already exists." >&2
  exit 1
fi

git tag -a "$TAG" -m "Preprod release ${VERSION}"
git push origin "$TAG"
echo "  Pushed tag $TAG."

# --- Step 9: Create draft GitHub prerelease ---
echo "[9/11] Creating draft GitHub prerelease..."
gh release create "$TAG" \
  --draft \
  --prerelease \
  --verify-tag \
  --title "$RELEASE_TITLE" \
  --notes "$RELEASE_NOTES" \
  "$DMG_PATH"

DRAFT_URL=$(gh release view "$TAG" --json url -q .url)
echo "  Draft prerelease: $DRAFT_URL"

# --- Step 10: Verify hosted asset and publish ---
echo "[10/11] Verifying hosted DMG and publishing..."
VERIFY_DIR=$(mktemp -d)
HOSTED_DMG="$VERIFY_DIR/${APP_NAME}-${VERSION}.dmg"

gh release download "$TAG" \
  -p "${APP_NAME}-${VERSION}.dmg" \
  -D "$VERIFY_DIR" \
  --clobber >/dev/null

LOCAL_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
HOSTED_SHA=$(shasum -a 256 "$HOSTED_DMG" | awk '{print $1}')
echo "  Local SHA256:  $LOCAL_SHA"
echo "  Hosted SHA256: $HOSTED_SHA"

if [[ "$LOCAL_SHA" != "$HOSTED_SHA" ]]; then
  echo "  RELEASE ABORTED: Hosted DMG SHA256 mismatch."
  exit 1
fi

HOSTED_SPCTL=$(spctl -a -vv -t open --context context:primary-signature "$HOSTED_DMG" 2>&1)
HOSTED_STAPLE=$(xcrun stapler validate "$HOSTED_DMG" 2>&1)
if ! echo "$HOSTED_SPCTL" | grep -q "accepted"; then
  echo "  RELEASE ABORTED: Hosted DMG rejected by Gatekeeper."
  exit 1
fi
if ! echo "$HOSTED_STAPLE" | grep -q "worked"; then
  echo "  RELEASE ABORTED: Hosted DMG missing valid staple."
  exit 1
fi

HOSTED_MOUNT_POINT=$(hdiutil attach "$HOSTED_DMG" -nobrowse 2>&1 | grep "/Volumes" | awk -F'\t' '{print $NF}')
HOSTED_APP_SPCTL=$(spctl -a -vv "$HOSTED_MOUNT_POINT/${APP_NAME}.app" 2>&1)
hdiutil detach "$HOSTED_MOUNT_POINT" -quiet 2>/dev/null
HOSTED_MOUNT_POINT=""

if ! echo "$HOSTED_APP_SPCTL" | grep -q "accepted"; then
  echo "  RELEASE ABORTED: App inside hosted DMG rejected by Gatekeeper."
  exit 1
fi

gh release edit "$TAG" \
  --draft=false \
  --title "$RELEASE_TITLE" \
  --notes "$RELEASE_NOTES"

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)
echo "  Hosted asset verified and prerelease published."

# --- Step 11: Update preprod appcast ---
echo "[11/11] Updating preprod appcast..."
"$GENERATE_APPCAST" "$OUTPUT_DIR" -o "$APPCAST_PATH"

perl -0pi -e 's{https://muesli-hq\.github\.io/muesli/(MuesliPreprod-([0-9][0-9A-Za-z\.\-]*)\.dmg)}{"https://github.com/Muesli-HQ/muesli/releases/download/v$2/$1"}ge' "$APPCAST_PATH"
perl -0pi -e 's{^\h*<enclosure\b[^>]*\bsparkle:deltaFrom="[^"]*"[^>]*/>\n}{}mg' "$APPCAST_PATH"
perl -0pi -e 's{^\h*<sparkle:deltas>\s*</sparkle:deltas>\n}{}mg' "$APPCAST_PATH"
python3 - "$APPCAST_PATH" "$SPARKLE_BUILD_VERSION" "$VERSION" <<'PY'
import re
import sys

appcast_path, sparkle_version, short_version = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(appcast_path, encoding="utf-8").read()

item_re = re.compile(r"\n[ \t]*<item>\n.*?\n[ \t]*</item>", re.S)
items = list(item_re.finditer(text))
if not items:
    raise SystemExit("ERROR: appcast has no items after generation")

target = None
for item in items:
    if (
        f"<sparkle:version>{sparkle_version}</sparkle:version>" in item.group(0)
        and f"<sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>" in item.group(0)
    ):
        target = item
        break

if target is None:
    raise SystemExit(f"ERROR: generated appcast is missing version {short_version} ({sparkle_version})")
if target == items[0]:
    raise SystemExit(0)

target_block = target.group(0)
without_target = text[:target.start()] + text[target.end():]
first_item = item_re.search(without_target)
if first_item is None:
    raise SystemExit("ERROR: appcast has no insertion point after reordering")

updated = without_target[:first_item.start()] + target_block + without_target[first_item.start():]
open(appcast_path, "w", encoding="utf-8").write(updated)
PY
printf '%s\n' "$RELEASE_NOTES" | python3 "$UPDATE_APPCAST_RELEASE_NOTES" \
  "$APPCAST_PATH" \
  --sparkle-version "$SPARKLE_BUILD_VERSION" \
  --short-version "$VERSION"

"$ROOT/scripts/verify_update_flow.sh" \
  --version "$SPARKLE_BUILD_VERSION" \
  --short-version "$VERSION" \
  --artifact-version "$VERSION" \
  --appcast "$APPCAST_PATH" \
  --dmg "$DMG_PATH" \
  --app-name "$APP_NAME" \
  --feed-url "$PREPROD_FEED_URL" \
  --require-release-notes \
  --require-notarized

git add "$APPCAST_PATH"
if git diff --cached --quiet; then
  echo "  No preprod appcast changes to commit."
else
  git commit -m "Update preprod appcast for v${VERSION}"
  git push origin HEAD
  echo "  Pushed preprod appcast update."
fi

echo ""
echo "=== Preprod release complete ==="
echo "  Version:  ${VERSION}"
echo "  Tag:      ${TAG}"
echo "  DMG:      $DMG_PATH"
echo "  Release:  $RELEASE_URL"
echo "  Appcast:  $PREPROD_FEED_URL"
echo "  Stable:   production appcast/site/Homebrew unchanged"
