#!/usr/bin/env bash
set -euo pipefail

# Alpha release pipeline — signed, notarized, GitHub prerelease.
#
# What this does:
#   - Builds and signs with the same Developer ID as stable releases
#   - Notarizes + staples both the app bundle and the DMG
#   - Creates a GitHub prerelease tagged v{VERSION}-alpha.N
#   - Verifies the hosted asset matches the local artifact
#
# What this does NOT do (intentional):
#   - Does not update docs/appcast.xml (stable Sparkle feed is untouched)
#   - Does not update docs/index.html or docs/llms.txt (site stays on stable)
#   - Does not update the Homebrew tap
#   - Does not commit or push to main
#
# Sparkle is disabled in alpha builds. Use scripts/release-preprod.sh when you
# need a signed, notarized build that exercises the Sparkle update flow.
#
# Usage: ./scripts/release-alpha.sh [version]
#   e.g.: ./scripts/release-alpha.sh 0.5.6-alpha.1
#   If no version given, auto-increments from the current stable base.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/muesli_spm_cache.sh"
PACKAGE_DIR="$ROOT/native/MuesliNative"
SWIFTPM_SCRATCH_PATH=""
SWIFT_TEST_ARGS=(--package-path "$PACKAGE_DIR")
BUILD_ENV=()
# The alpha channel is intentionally shared across worktrees. Do not run this
# script concurrently from multiple worktrees unless you set an isolated
# MUESLI_SWIFTPM_SCRATCH_PATH or MUESLI_SWIFTPM_SCRATCH_CHANNEL.
if ! muesli_spm_scratch_disabled; then
  SWIFTPM_SCRATCH_PATH="$(muesli_resolve_spm_scratch_path alpha)"
  SWIFT_TEST_ARGS+=(--scratch-path "$SWIFTPM_SCRATCH_PATH")
  BUILD_ENV+=(MUESLI_SWIFTPM_SCRATCH_PATH="$SWIFTPM_SCRATCH_PATH")
else
  BUILD_ENV+=(MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1)
fi
PROFILE_NAME="${MUESLI_NOTARY_PROFILE:-MuesliNotary}"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)}"
APP_DIR="/Applications/MuesliCanary.app"
OUTPUT_DIR="$ROOT/dist-release"
HOSTED_MOUNT_POINT=""
VERIFY_DIR=""

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
  # Derive base from latest stable: bump patch by 1
  LATEST_STABLE=$(gh release list --limit 20 --json tagName,isPrerelease \
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

  # Find the highest existing alpha.N for this base
  LATEST_N=$(gh release list --limit 100 --json tagName,isPrerelease \
    -q "[.[] | select(.isPrerelease == true) | .tagName \
        | select(startswith(\"v${BASE}-alpha.\")) \
        | ltrimstr(\"v${BASE}-alpha.\") \
        | tonumber] | max // 0" 2>/dev/null || echo "0")

  NEXT_N=$((LATEST_N + 1))
  VERSION="${BASE}-alpha.${NEXT_N}"

  echo "Latest stable:  ${LATEST_STABLE}"
  echo "Proposed alpha: v${VERSION}"
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

TAG="v${VERSION}"
RELEASE_TITLE="MuesliCanary ${VERSION}"
DMG_PATH="$OUTPUT_DIR/MuesliCanary-${VERSION}.dmg"

RELEASE_NOTES="$(cat <<EOF
## MuesliCanary ${VERSION}

Alpha build — signed and notarized, but not yet stable.
Installs as **MuesliCanary** alongside your existing Muesli install.

### Install
1. Download \`MuesliCanary-${VERSION}.dmg\`
2. Open the DMG and drag MuesliCanary to Applications
3. Launch MuesliCanary from Applications

### Notes
- Stores data separately in \`~/Library/Application Support/MuesliCanary/\`
- Raw ASR + post-processed pairs logged to \`MuesliCanary/postproc-pairs.jsonl\`
- Sparkle is disabled; use MuesliPreprod for updater-flow testing

### Not linked from the main site
Download from [GitHub Releases](https://github.com/Muesli-HQ/muesli/releases).
EOF
)"

echo "=== MuesliCanary Alpha v${VERSION} ==="
echo ""

mkdir -p "$OUTPUT_DIR"

# --- Step 1: Run tests ---
echo "[1/10] Running tests..."
if [[ -n "$SWIFTPM_SCRATCH_PATH" ]]; then
  mkdir -p "$SWIFTPM_SCRATCH_PATH"
  echo "  SwiftPM scratch path: $SWIFTPM_SCRATCH_PATH"
else
  echo "  SwiftPM scratch path: package-local .build"
fi
swift test "${SWIFT_TEST_ARGS[@]}"
echo "  Tests passed."

# --- Step 2: Build and sign ---
echo "[2/10] Building and signing (version: ${VERSION})..."
ALPHA_BUILD_ENV=(
  MUESLI_BUILD_VERSION="$VERSION"
  "${BUILD_ENV[@]}"
  MUESLI_APP_NAME=MuesliCanary
  MUESLI_BUNDLE_ID=com.muesli.canary
  MUESLI_DISPLAY_NAME=MuesliCanary
  MUESLI_SUPPORT_DIR_NAME=MuesliCanary
  MUESLI_SPARKLE_FEED_URL=""
)
echo "y" | env "${ALPHA_BUILD_ENV[@]}" "$ROOT/scripts/build_native_app.sh" > /dev/null
echo "  Installed to $APP_DIR"

FLAGS=$(codesign -dvvv "$APP_DIR" 2>&1 | grep -o 'flags=0x[0-9a-f]*([^)]*)')
echo "  Signature: $FLAGS"

# --- Step 3: Notarize app bundle ---
echo "[3/10] Notarizing app bundle (this may take several minutes)..."
APP_ZIP="$OUTPUT_DIR/MuesliCanary-app-${VERSION}.zip"
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
echo "[4/10] Stapling app bundle..."
xcrun stapler staple "$APP_DIR"
echo "  App stapled."

# --- Step 5: Create DMG from stapled app ---
echo "[5/10] Creating DMG from stapled app..."
"$ROOT/scripts/create_dmg.sh" "$APP_DIR" "$OUTPUT_DIR"
# create_dmg.sh reads CFBundleShortVersionString from the app, so the DMG is
# already named MuesliCanary-{VERSION}.dmg — no rename needed.

# --- Step 6: Notarize DMG ---
echo "[6/10] Notarizing DMG..."
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

# --- Step 7: Staple + verify DMG ---
echo "[7/10] Stapling and verifying DMG..."
xcrun stapler staple "$DMG_PATH"

MOUNT_POINT=$(hdiutil attach "$DMG_PATH" -nobrowse 2>&1 | grep "/Volumes" | awk -F'\t' '{print $NF}')
if [[ -z "$MOUNT_POINT" ]]; then
  echo "ERROR: Could not mount DMG for verification." >&2
  exit 1
fi

SPCTL_RESULT=$(spctl -a -vv "$MOUNT_POINT/MuesliCanary.app" 2>&1)
STAPLE_RESULT=$(xcrun stapler validate "$MOUNT_POINT/MuesliCanary.app" 2>&1)
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
echo "  Gatekeeper, staple, and hardened runtime verified."

# --- Step 8: Tag ---
echo "[8/10] Tagging..."
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  echo "ERROR: Local tag ${TAG} already exists." >&2
  exit 1
fi
if git ls-remote --tags origin "refs/tags/${TAG}" | grep -q .; then
  echo "ERROR: Remote tag ${TAG} already exists." >&2
  exit 1
fi

git tag -a "$TAG" -m "Alpha release ${VERSION}"
git push origin "$TAG"
echo "  Pushed tag $TAG (pointing at current main HEAD — no commit to main)."

# --- Step 9: Create draft GitHub prerelease + upload DMG ---
echo "[9/10] Creating draft GitHub prerelease..."
gh release create "$TAG" \
  --draft \
  --prerelease \
  --verify-tag \
  --title "$RELEASE_TITLE" \
  --notes "$RELEASE_NOTES" \
  "$DMG_PATH"

DRAFT_URL=$(gh release view "$TAG" --json url -q .url)
echo "  Draft prerelease: $DRAFT_URL"

# --- Step 10: Verify hosted asset + publish ---
echo "[10/10] Verifying hosted DMG and publishing..."
VERIFY_DIR=$(mktemp -d)
HOSTED_DMG="$VERIFY_DIR/MuesliCanary-${VERSION}.dmg"

gh release download "$TAG" \
  -p "MuesliCanary-${VERSION}.dmg" \
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
HOSTED_APP_SPCTL=$(spctl -a -vv "$HOSTED_MOUNT_POINT/MuesliCanary.app" 2>&1)
hdiutil detach "$HOSTED_MOUNT_POINT" -quiet 2>/dev/null
HOSTED_MOUNT_POINT=""

if ! echo "$HOSTED_APP_SPCTL" | grep -q "accepted"; then
  echo "  RELEASE ABORTED: App inside hosted DMG rejected by Gatekeeper."
  exit 1
fi
echo "  Hosted asset verified."

gh release edit "$TAG" \
  --draft=false \
  --title "$RELEASE_TITLE" \
  --notes "$RELEASE_NOTES"

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)

echo ""
echo "=== Alpha release complete ==="
echo "  Version:  ${VERSION}"
echo "  Tag:      ${TAG} (no commit pushed to main)"
echo "  DMG:      $DMG_PATH"
echo "  Release:  $RELEASE_URL"
echo "  Sparkle:  disabled (use release-preprod.sh for updater-flow testing)"
echo "  Site:     unchanged (freedspeech.xyz stays on stable)"
