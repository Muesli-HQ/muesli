#!/usr/bin/env bash
set -euo pipefail

# Canonical end-to-end release pipeline for official builds.
# Source of truth:
#   - GitHub Releases hosts the official DMG binaries
#   - GitHub Pages hosts the Sparkle appcast referenced by SUFeedURL
# Everything else is a mirror or marketing surface, not a release source.
#
# End-to-end release pipeline:
#   1. Build and sign the app (hardened runtime + entitlements)
#   2. Notarize + staple the app bundle
#   3. Create a signed DMG from the stapled app
#   4. Notarize + staple the DMG
#   5. Verify the local DMG and the app inside it
#   6. Create GitHub release and upload DMG
#   7. Re-download the hosted DMG from GitHub Releases and verify that exact file
#   8. Update downstream release surfaces from the verified hosted DMG:
#      - GitHub Pages appcast + landing-page metadata
#      - Personal Homebrew tap cask
#
# Prerequisites:
#   - Developer ID cert in keychain
#   - Notary profile stored: xcrun notarytool store-credentials MuesliNotary
#   - gh CLI authenticated
#
# Usage: ./scripts/release.sh [version]
#   e.g.: ./scripts/release.sh 0.5.0
#   If no version given, auto-increments patch from latest GitHub release.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/muesli_spm_cache.sh"
PACKAGE_DIR="$ROOT/native/MuesliNative"
SWIFTPM_SCRATCH_PATH=""
SWIFT_TEST_ARGS=(--package-path "$PACKAGE_DIR")
BUILD_ENV=()
# The release channel is intentionally shared across worktrees. Do not run this
# script concurrently from multiple worktrees unless you set an isolated
# MUESLI_SWIFTPM_SCRATCH_PATH or MUESLI_SWIFTPM_SCRATCH_CHANNEL.
if ! muesli_spm_scratch_disabled; then
  SWIFTPM_SCRATCH_PATH="$(muesli_resolve_spm_scratch_path release)"
  SWIFT_TEST_ARGS+=(--scratch-path "$SWIFTPM_SCRATCH_PATH")
  BUILD_ENV+=(MUESLI_SWIFTPM_SCRATCH_PATH="$SWIFTPM_SCRATCH_PATH")
else
  BUILD_ENV+=(MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1)
fi
PROFILE_NAME="${MUESLI_NOTARY_PROFILE:-MuesliNotary}"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)}"
OUTPUT_DIR="$ROOT/dist-release"
INSTALL_DIR="${MUESLI_RELEASE_INSTALL_DIR:-$OUTPUT_DIR/install-root}"
APP_DIR="${MUESLI_RELEASE_APP_DIR:-$INSTALL_DIR/Muesli.app}"
GENERATE_APPCAST="$(muesli_spm_artifacts_dir "$PACKAGE_DIR" "$SWIFTPM_SCRATCH_PATH")/sparkle/Sparkle/bin/generate_appcast"
UPDATE_APPCAST_RELEASE_NOTES="$ROOT/scripts/update_appcast_release_notes.py"
TAP_REPO="${MUESLI_TAP_REPO:-Muesli-HQ/homebrew-muesli}"
TAP_CASK_REL_PATH="${MUESLI_TAP_CASK_REL_PATH:-Casks/m/muesli.rb}"
SKIP_TAP_UPDATE="${MUESLI_SKIP_TAP_UPDATE:-0}"
VERIFY_DIR=""
HOSTED_MOUNT_POINT=""
TAP_WORK_DIR=""

cleanup() {
  if [[ -n "$HOSTED_MOUNT_POINT" ]]; then
    hdiutil detach "$HOSTED_MOUNT_POINT" -quiet 2>/dev/null || true
  fi
  if [[ -n "$VERIFY_DIR" && -d "$VERIFY_DIR" ]]; then
    rm -rf "$VERIFY_DIR"
  fi
  if [[ -n "$TAP_WORK_DIR" && -d "$TAP_WORK_DIR" ]]; then
    rm -rf "$TAP_WORK_DIR"
  fi
}

trap cleanup EXIT

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  # Auto-increment: get latest release tag, bump patch version
  LATEST_TAG=$(gh release list --limit 1 --json tagName -q '.[0].tagName' 2>/dev/null || echo "")
  if [[ -n "$LATEST_TAG" ]]; then
    LATEST_VERSION="${LATEST_TAG#v}"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$LATEST_VERSION"
    # Strip any pre-release suffix from patch (e.g., "0-beta.1" → "0")
    PATCH="${PATCH%%[-+]*}"
    PATCH=$((PATCH + 1))
    VERSION="${MAJOR}.${MINOR}.${PATCH}"
    echo "Auto-incremented version: ${LATEST_TAG} → v${VERSION}"
  else
    VERSION="0.1.0"
    echo "No previous releases found, starting at v${VERSION}"
  fi
  echo ""
  read -p "Release as v${VERSION}? [Y/n] " confirm
  if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
    read -p "Enter version: " VERSION
  fi
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "ERROR: Working tree must be clean before running the release pipeline." >&2
  exit 1
fi

if [[ ! -f "$UPDATE_APPCAST_RELEASE_NOTES" ]]; then
  echo "ERROR: update_appcast_release_notes.py not found at $UPDATE_APPCAST_RELEASE_NOTES" >&2
  exit 1
fi

DOWNLOAD_URL="https://github.com/Muesli-HQ/muesli/releases/download/v${VERSION}/Muesli-${VERSION}.dmg"
TAG="v${VERSION}"
RELEASE_TITLE="Muesli ${VERSION}"
RELEASE_NOTES="$(cat <<EOF
## Muesli ${VERSION}

Native macOS app — dictation + meeting transcription on Apple Silicon.

### Install
1. Download \`Muesli-${VERSION}.dmg\`
2. Open the DMG and drag Muesli to Applications
3. Launch from Applications

Signed, notarized, and stapled by Apple.
EOF
)"

update_personal_tap() {
  if [[ "$SKIP_TAP_UPDATE" == "1" ]]; then
    echo "  Skipping personal tap update because MUESLI_SKIP_TAP_UPDATE=1."
    return 0
  fi

  TAP_WORK_DIR="$(mktemp -d)"
  echo "  Cloning $TAP_REPO..."
  gh repo clone "$TAP_REPO" "$TAP_WORK_DIR" -- --quiet

  local cask_path="$TAP_WORK_DIR/$TAP_CASK_REL_PATH"
  if [[ ! -f "$cask_path" ]]; then
    echo "ERROR: Personal tap cask not found at $TAP_CASK_REL_PATH in $TAP_REPO." >&2
    return 1
  fi

  perl -0pi -e 's/version "[^"]+"/version "'"$VERSION"'"/; s/sha256 "[^"]+"/sha256 "'"$HOSTED_SHA"'"/' "$cask_path"

  git -C "$TAP_WORK_DIR" add "$TAP_CASK_REL_PATH"
  if git -C "$TAP_WORK_DIR" diff --cached --quiet; then
    echo "  Personal tap already points at v${VERSION}."
    return 0
  fi

  git -C "$TAP_WORK_DIR" commit -m "muesli ${VERSION}"
  git -C "$TAP_WORK_DIR" push origin HEAD
  echo "  Personal tap updated: https://github.com/$TAP_REPO"
}

echo "=== Muesli Release v${VERSION} ==="
echo ""

# --- Step 0: Update version in build script ---
echo "[0/13] Setting version to ${VERSION}..."
sed -i '' "s/^DEFAULT_APP_VERSION=.*/DEFAULT_APP_VERSION=\"${VERSION}\"/" "$ROOT/scripts/build_native_app.sh"

# --- Step 1: Run tests ---
echo "[1/13] Running tests..."
if [[ -n "$SWIFTPM_SCRATCH_PATH" ]]; then
  mkdir -p "$SWIFTPM_SCRATCH_PATH"
  echo "  SwiftPM scratch path: $SWIFTPM_SCRATCH_PATH"
else
  echo "  SwiftPM scratch path: package-local .build"
fi
swift test "${SWIFT_TEST_ARGS[@]}"
echo "  Tests passed."

# --- Step 2: Build and sign ---
echo "[2/13] Building and signing..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
RELEASE_BUILD_ENV=(
  MUESLI_INSTALL_DIR="$INSTALL_DIR"
  "${BUILD_ENV[@]}"
)
echo "y" | env "${RELEASE_BUILD_ENV[@]}" "$ROOT/scripts/build_native_app.sh" > /dev/null 2>&1
echo "  Installed to $APP_DIR"
if [[ ! -x "$GENERATE_APPCAST" ]]; then
  echo "ERROR: generate_appcast not found at $GENERATE_APPCAST" >&2
  exit 1
fi

# Verify signature
FLAGS=$(codesign -dvvv "$APP_DIR" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)')
echo "  Signature: $FLAGS"

# --- Step 3: Notarize app bundle ---
echo "[3/13] Notarizing app bundle with Apple (this may take several minutes)..."
APP_ZIP="$OUTPUT_DIR/Muesli-app-${VERSION}.zip"
ditto -c -k --keepParent "$APP_DIR" "$APP_ZIP"
NOTARY_OUTPUT=$(xcrun notarytool submit "$APP_ZIP" \
  --keychain-profile "$PROFILE_NAME" \
  --wait 2>&1)
echo "$NOTARY_OUTPUT"
rm -f "$APP_ZIP"

if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
  echo "  App notarization accepted."
else
  echo "  App notarization FAILED. Fetching log..."
  SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE_NAME" 2>&1
  exit 1
fi

# --- Step 4: Staple app bundle ---
echo "[4/13] Stapling notarization ticket to app bundle..."
xcrun stapler staple "$APP_DIR"
echo "  App stapled."

# --- Step 5: Create DMG from stapled app ---
echo "[5/13] Creating DMG from stapled app..."
"$ROOT/scripts/create_dmg.sh" "$APP_DIR" "$OUTPUT_DIR"
DMG_PATH="$OUTPUT_DIR/Muesli-${VERSION}.dmg"

# --- Step 6: Notarize DMG ---
echo "[6/13] Notarizing DMG with Apple..."
NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$PROFILE_NAME" \
  --wait 2>&1)
echo "$NOTARY_OUTPUT"

if echo "$NOTARY_OUTPUT" | grep -q "status: Accepted"; then
  echo "  DMG notarization accepted."
else
  echo "  DMG notarization FAILED. Fetching log..."
  SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE_NAME" 2>&1
  exit 1
fi

# --- Step 7: Staple DMG ---
echo "[7/13] Stapling notarization ticket to DMG..."
xcrun stapler staple "$DMG_PATH"
echo "  DMG stapled."

# Verify by mounting DMG and checking the app INSIDE it (simulates user experience)
echo "  Verifying app inside DMG..."
MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse 2>&1 | grep "/Volumes" | awk -F'\t' '{print $NF}')
if [[ -z "$MOUNT_POINT" ]]; then
  echo "  ERROR: Could not mount DMG for verification"
  exit 1
fi

SPCTL_RESULT=$(spctl -a -vv "$MOUNT_POINT/Muesli.app" 2>&1)
echo "  $SPCTL_RESULT"

STAPLE_RESULT=$(xcrun stapler validate "$MOUNT_POINT/Muesli.app" 2>&1)
echo "  $STAPLE_RESULT"

hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null

if ! echo "$SPCTL_RESULT" | grep -q "accepted"; then
  echo ""
  echo "  RELEASE ABORTED: App inside DMG was REJECTED by Gatekeeper."
  echo "  The app bundle was not properly stapled before DMG creation."
  exit 1
fi

if ! echo "$STAPLE_RESULT" | grep -q "worked"; then
  echo ""
  echo "  RELEASE ABORTED: App inside DMG does not have a valid staple."
  exit 1
fi

# Verify DMG itself has hardened runtime flag
DMG_FLAGS=$(codesign -dvvv "$DMG_PATH" 2>&1)
if ! echo "$DMG_FLAGS" | grep -q "runtime"; then
  echo ""
  echo "  RELEASE ABORTED: DMG is missing hardened runtime flag."
  exit 1
fi
echo "  DMG hardened runtime verified."

echo "  Verified: app inside DMG is accepted by Gatekeeper and stapled."
echo ""

# --- Step 8: Commit version metadata before tagging ---
echo "[8/13] Committing release metadata..."
git add scripts/build_native_app.sh
if git diff --cached --quiet; then
  echo "  No version metadata changes to commit."
else
  git commit -m "Prepare release v${VERSION}"
  git push origin main
  echo "  Pushed release prep commit to main."
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "ERROR: Local tag ${TAG} already exists." >&2
  exit 1
fi

if git ls-remote --tags origin "refs/tags/${TAG}" | grep -q .; then
  echo "ERROR: Remote tag ${TAG} already exists." >&2
  exit 1
fi

git tag -a "$TAG" -m "Release ${VERSION}"
git push origin "$TAG"
echo "  Pushed release tag $TAG."

# --- Step 9: Create a draft GitHub release and upload the DMG ---
echo "[9/13] Creating draft GitHub release v${VERSION}..."
gh release create "$TAG" \
  --draft \
  --verify-tag \
  --title "$RELEASE_TITLE" \
  --notes "$RELEASE_NOTES" \
  "$DMG_PATH"

DRAFT_RELEASE_URL=$(gh release view "$TAG" --json url -q .url)
echo "  Draft release: $DRAFT_RELEASE_URL"

# --- Step 10: Verify the hosted draft asset from GitHub Releases ---
echo "[10/13] Verifying hosted GitHub Release DMG..."
VERIFY_DIR=$(mktemp -d)
HOSTED_DMG="$VERIFY_DIR/Muesli-${VERSION}.dmg"

gh release download "$TAG" \
  -p "Muesli-${VERSION}.dmg" \
  -D "$VERIFY_DIR" \
  --clobber >/dev/null

LOCAL_SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
HOSTED_SHA=$(shasum -a 256 "$HOSTED_DMG" | awk '{print $1}')

echo "  Local SHA256:  $LOCAL_SHA"
echo "  Hosted SHA256: $HOSTED_SHA"

if [[ "$LOCAL_SHA" != "$HOSTED_SHA" ]]; then
  echo ""
  echo "  RELEASE ABORTED: Hosted GitHub Release DMG does not match the verified local artifact."
  exit 1
fi

HOSTED_SPCTL_RESULT=$(spctl -a -vv -t open --context context:primary-signature "$HOSTED_DMG" 2>&1)
echo "  $HOSTED_SPCTL_RESULT"

HOSTED_STAPLE_RESULT=$(xcrun stapler validate "$HOSTED_DMG" 2>&1)
echo "  $HOSTED_STAPLE_RESULT"

if ! echo "$HOSTED_SPCTL_RESULT" | grep -q "accepted"; then
  echo ""
  echo "  RELEASE ABORTED: Hosted DMG was rejected by Gatekeeper."
  exit 1
fi

if ! echo "$HOSTED_STAPLE_RESULT" | grep -q "worked"; then
  echo ""
  echo "  RELEASE ABORTED: Hosted DMG does not have a valid staple."
  exit 1
fi

echo "  Verifying app inside hosted DMG..."
HOSTED_MOUNT_POINT=$(hdiutil attach "$HOSTED_DMG" -nobrowse 2>&1 | grep "/Volumes" | awk -F'\t' '{print $NF}')
if [[ -z "$HOSTED_MOUNT_POINT" ]]; then
  echo "  ERROR: Could not mount hosted DMG for verification"
  exit 1
fi

HOSTED_APP_SPCTL_RESULT=$(spctl -a -vv "$HOSTED_MOUNT_POINT/Muesli.app" 2>&1)
echo "  $HOSTED_APP_SPCTL_RESULT"

HOSTED_APP_STAPLE_RESULT=$(xcrun stapler validate "$HOSTED_MOUNT_POINT/Muesli.app" 2>&1)
echo "  $HOSTED_APP_STAPLE_RESULT"

hdiutil detach "$HOSTED_MOUNT_POINT" -quiet 2>/dev/null

if ! echo "$HOSTED_APP_SPCTL_RESULT" | grep -q "accepted"; then
  echo ""
  echo "  RELEASE ABORTED: App inside hosted DMG was rejected by Gatekeeper."
  exit 1
fi

if ! echo "$HOSTED_APP_STAPLE_RESULT" | grep -q "worked"; then
  echo ""
  echo "  RELEASE ABORTED: App inside hosted DMG does not have a valid staple."
  exit 1
fi

# --- Step 11: Publish the verified draft release ---
echo "[11/13] Publishing verified GitHub release..."
gh release edit "$TAG" \
  --draft=false \
  --title "$RELEASE_TITLE" \
  --notes "$RELEASE_NOTES"

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)
echo "  Release published: $RELEASE_URL"

# --- Step 12: Update appcast and landing-page links after release publication ---
echo "[12/13] Updating appcast and release metadata..."
"$GENERATE_APPCAST" "$OUTPUT_DIR" -o "$ROOT/docs/appcast.xml"

# Point appcast enclosures at GitHub Releases, not GitHub Pages.
perl -0pi -e 's{https://muesli-hq\.github\.io/muesli/(Muesli-([0-9][0-9A-Za-z\.\-]*)\.dmg)}{"https://github.com/Muesli-HQ/muesli/releases/download/v$2/$1"}ge' "$ROOT/docs/appcast.xml"

# Delta artifacts are not hosted, so strip delta enclosures from the appcast.
perl -0pi -e 's{^\h*<enclosure\b[^>]*\bsparkle:deltaFrom="[^"]*"[^>]*/>\n}{}mg' "$ROOT/docs/appcast.xml"
printf '%s\n' "$RELEASE_NOTES" | python3 "$UPDATE_APPCAST_RELEASE_NOTES" \
  "$ROOT/docs/appcast.xml" \
  --sparkle-version "$VERSION" \
  --short-version "$VERSION"

# Keep the marketing/docs surface aligned with the published GitHub Release.
sed -i '' "s|https://github.com/Muesli-HQ/muesli/releases/download/[^\"]*\\.dmg|$DOWNLOAD_URL|g" "$ROOT/docs/index.html"
sed -i '' "s|https://github.com/Muesli-HQ/muesli/releases/download/.*\\.dmg|$DOWNLOAD_URL|g" "$ROOT/docs/llms.txt"

echo "  Verifying Sparkle update flow metadata..."
"$ROOT/scripts/verify_update_flow.sh" \
  --version "$VERSION" \
  --dmg "$DMG_PATH" \
  --require-release-notes \
  --require-notarized

git add docs/appcast.xml docs/index.html docs/llms.txt
if git diff --cached --quiet; then
  echo "  No docs changes to commit."
else
  git commit -m "Update release metadata for v${VERSION}"
  git push origin main
  echo "  Pushed appcast and landing-page updates to main."
fi

# --- Step 13: Update the personal Homebrew tap from the verified hosted DMG ---
echo "[13/13] Updating personal Homebrew tap..."
update_personal_tap

echo ""
echo "=== Release complete ==="
echo "  Version: ${VERSION}"
echo "  DMG: $DMG_PATH"
echo "  Release: $RELEASE_URL"
echo "  Hosted asset verified."
if [[ "$SKIP_TAP_UPDATE" != "1" ]]; then
  echo "  Personal tap: https://github.com/$TAP_REPO"
fi
