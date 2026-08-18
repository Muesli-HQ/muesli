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
#   8. Open a PR for downstream release surfaces from the verified hosted DMG:
#      - GitHub Pages appcast + landing-page metadata
#      - Official Homebrew cask livecheck/autobump verification
#
# Prerequisites:
#   - Developer ID cert in keychain
#   - Production provisioning profile for com.muesli.app when CloudKit
#     entitlements are enabled:
#       MUESLI_PROVISIONING_PROFILE=/path/to/profile.provisionprofile
#   - Notary profile stored: xcrun notarytool store-credentials MuesliNotary
#   - gh CLI authenticated
#   - Homebrew installed for post-release cask livecheck/autobump verification
#
# Usage: ./scripts/release.sh [version]
#   e.g.: ./scripts/release.sh 0.5.0
#   If no version given, auto-increments patch from latest GitHub release.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/muesli_spm_cache.sh"
source "$ROOT/scripts/muesli_telemetry_channels.sh"
source "$ROOT/scripts/release_publication_gate.sh"
PACKAGE_DIR="$ROOT/native/MuesliNative"
SWIFTPM_SCRATCH_PATH=""
SWIFT_TEST_ARGS=(--package-path "$PACKAGE_DIR")
BUILD_ENV=()
# Pin the compile path to the xcodebuild path (native/MuesliXcode), which is
# the only path that generates Contents/Resources/Metadata.appintents and
# therefore the only path where Shortcuts/Siri actions ship. Production/
# notarized builds must never silently pick up a MUESLI_USE_XCODE_BUILD=0
# override from the ambient environment; to cut an emergency SwiftPM-only
# release, edit this pin deliberately. Requires xcodegen on the release host.
BUILD_ENV+=(MUESLI_USE_XCODE_BUILD=1)
# The release channel is intentionally shared across worktrees. Do not run this
# script concurrently from multiple worktrees unless you set an isolated
# MUESLI_SWIFTPM_SCRATCH_PATH or MUESLI_SWIFTPM_SCRATCH_CHANNEL.
if ! muesli_spm_scratch_disabled; then
  SWIFTPM_SCRATCH_PATH="$(muesli_resolve_spm_scratch_path release)"
  SWIFT_TEST_ARGS+=(--scratch-path "$SWIFTPM_SCRATCH_PATH")
  BUILD_ENV+=(MUESLI_SWIFTPM_SCRATCH_PATH="$SWIFTPM_SCRATCH_PATH")
  # Keep the xcodebuild cache under the same scratch root so an isolated
  # MUESLI_SWIFTPM_SCRATCH_PATH also isolates concurrent DerivedData.
  BUILD_ENV+=(MUESLI_XCODEBUILD_DERIVED_DATA="$SWIFTPM_SCRATCH_PATH/xcodebuild")
else
  BUILD_ENV+=(MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1)
fi
PROFILE_NAME="${MUESLI_NOTARY_PROFILE:-MuesliNotary}"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)}"
PROVISIONING_PROFILE="${MUESLI_PROVISIONING_PROFILE:-}"
OUTPUT_DIR="$ROOT/dist-release"
INSTALL_DIR="${MUESLI_RELEASE_INSTALL_DIR:-$OUTPUT_DIR/install-root}"
APP_DIR="${MUESLI_RELEASE_APP_DIR:-$INSTALL_DIR/Muesli.app}"
GENERATE_APPCAST="$(muesli_spm_artifacts_dir "$PACKAGE_DIR" "$SWIFTPM_SCRATCH_PATH")/sparkle/Sparkle/bin/generate_appcast"
UPDATE_APPCAST_RELEASE_NOTES="$ROOT/scripts/update_appcast_release_notes.py"
MERGE_APPCAST_ITEM="$ROOT/scripts/merge_appcast_item.py"
HOMEBREW_CASK="${MUESLI_HOMEBREW_CASK:-muesli}"
SKIP_HOMEBREW_CHECK="${MUESLI_SKIP_HOMEBREW_CHECK:-0}"
RELEASE_PR_MODE="${MUESLI_RELEASE_PR_MODE:-0}"
VERIFY_DIR=""
MOUNT_POINT=""
HOSTED_MOUNT_POINT=""
HOMEBREW_CHECK_STATUS="skipped"

cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  fi
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

CURRENT_BRANCH="$(git branch --show-current)"
assert_release_branch_contains_origin_main() {
  git fetch origin main --quiet
  if ! git merge-base --is-ancestor origin/main HEAD; then
    echo "ERROR: ${CURRENT_BRANCH} does not contain the latest origin/main." >&2
    echo "Rebase or merge origin/main before publishing a stable release." >&2
    exit 1
  fi
}

if [[ "$RELEASE_PR_MODE" == "1" ]]; then
  echo "ERROR: MUESLI_RELEASE_PR_MODE is no longer allowed to publish stable artifacts." >&2
  echo "Merge the release code and version PR first, then publish from the current origin/main." >&2
  exit 1
fi
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "ERROR: Stable releases must be published from main after the release PR is merged." >&2
  exit 1
fi
assert_release_branch_contains_origin_main
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "ERROR: main must exactly match origin/main before publishing a stable release." >&2
  exit 1
fi

if [[ ! -f "$UPDATE_APPCAST_RELEASE_NOTES" ]]; then
  echo "ERROR: update_appcast_release_notes.py not found at $UPDATE_APPCAST_RELEASE_NOTES" >&2
  exit 1
fi

if [[ ! -f "$MERGE_APPCAST_ITEM" ]]; then
  echo "ERROR: merge_appcast_item.py not found at $MERGE_APPCAST_ITEM" >&2
  exit 1
fi

if [[ -z "$PROVISIONING_PROFILE" ]]; then
  echo "ERROR: stable release builds require MUESLI_PROVISIONING_PROFILE." >&2
  echo "Use the production provisioning profile for bundle ID com.muesli.app with CloudKit container iCloud.com.mueslihq.muesli." >&2
  exit 1
fi

if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
  echo "ERROR: provisioning profile not found: $PROVISIONING_PROFILE" >&2
  exit 1
fi

DOWNLOAD_URL="https://github.com/Muesli-HQ/muesli/releases/download/v${VERSION}/Muesli-${VERSION}.dmg"
TAG="v${VERSION}"
RELEASE_TITLE="Muesli ${VERSION}"
RELEASE_METADATA_BRANCH="${MUESLI_RELEASE_METADATA_BRANCH:-codex/release-${VERSION}-appcast}"
DEFAULT_RELEASE_NOTES_FILE="$ROOT/docs/release-notes/${VERSION}.md"
RELEASE_NOTES_FILE="${MUESLI_RELEASE_NOTES_FILE:-$DEFAULT_RELEASE_NOTES_FILE}"
RELEASE_NOTES=""
RELEASE_NOTES_FROM_FILE=0
RELEASE_NOTES_ARGS=()
RELEASE_METADATA_VALIDATED=0
RELEASE_METADATA_PR_URL=""

if [[ -n "${MUESLI_RELEASE_NOTES_FILE:-}" && ! -f "$RELEASE_NOTES_FILE" ]]; then
  echo "ERROR: release notes file not found: $RELEASE_NOTES_FILE" >&2
  exit 1
fi

if [[ -f "$RELEASE_NOTES_FILE" ]]; then
  RELEASE_NOTES_FROM_FILE=1
  RELEASE_NOTES_ARGS=(--notes-file "$RELEASE_NOTES_FILE")
  echo "Using release notes from $RELEASE_NOTES_FILE"
else
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
  RELEASE_NOTES_ARGS=(--notes "$RELEASE_NOTES")
fi

if ! git check-ref-format --branch "$RELEASE_METADATA_BRANCH" >/dev/null 2>&1; then
  echo "ERROR: Invalid release metadata branch: $RELEASE_METADATA_BRANCH" >&2
  exit 1
fi

verify_homebrew_autobump() {
  if [[ "$SKIP_HOMEBREW_CHECK" == "1" ]]; then
    echo "  Skipping official Homebrew cask livecheck because MUESLI_SKIP_HOMEBREW_CHECK=1."
    HOMEBREW_CHECK_STATUS="skipped"
    return 0
  fi

  echo "  Verifying official Homebrew cask livecheck for ${HOMEBREW_CASK}..."
  HOMEBREW_CHECK_STATUS="verified"
  if ! brew livecheck --cask "$HOMEBREW_CASK"; then
    echo "  WARNING: Homebrew livecheck failed; check ${HOMEBREW_CASK} manually." >&2
    HOMEBREW_CHECK_STATUS="warning"
  fi
  if ! brew bump --cask --no-pull-requests "$HOMEBREW_CASK"; then
    echo "  WARNING: Homebrew autobump verification failed; check ${HOMEBREW_CASK} manually." >&2
    HOMEBREW_CHECK_STATUS="warning"
  fi
  echo "  BrewTestBot should open ${HOMEBREW_CASK} version bump PRs automatically."
}

resume_existing_release_publication() {
  echo "Existing release metadata branch found; validating the hosted release before resuming publication."
  git fetch origin \
    "refs/heads/${RELEASE_METADATA_BRANCH}:refs/remotes/origin/${RELEASE_METADATA_BRANCH}" \
    --quiet

  local metadata_pr_count
  metadata_pr_count=$(gh pr list \
    --repo Muesli-HQ/muesli \
    --base main \
    --head "$RELEASE_METADATA_BRANCH" \
    --state open \
    --json url \
    --jq 'length')
  if [[ "$metadata_pr_count" != "0" && "$metadata_pr_count" != "1" ]]; then
    echo "ERROR: Expected zero or one open metadata PR for $RELEASE_METADATA_BRANCH; found $metadata_pr_count." >&2
    exit 1
  fi
  if [[ "$metadata_pr_count" == "1" ]]; then
    RELEASE_METADATA_PR_URL=$(gh pr list \
      --repo Muesli-HQ/muesli \
      --base main \
      --head "$RELEASE_METADATA_BRANCH" \
      --state open \
      --json url \
      --jq '.[0].url')
  fi

  local release_is_draft
  release_is_draft=$(gh release view "$TAG" --json isDraft --jq '.isDraft' 2>/dev/null || true)
  if [[ "$release_is_draft" != "true" && "$release_is_draft" != "false" ]]; then
    echo "ERROR: Metadata exists, but GitHub release $TAG could not be found." >&2
    exit 1
  fi

  VERIFY_DIR=$(mktemp -d)
  local hosted_dmg="$VERIFY_DIR/Muesli-${VERSION}.dmg"
  local metadata_appcast="$VERIFY_DIR/appcast.xml"
  gh release download "$TAG" \
    -p "Muesli-${VERSION}.dmg" \
    -D "$VERIFY_DIR" \
    --clobber >/dev/null
  git show "origin/${RELEASE_METADATA_BRANCH}:docs/appcast.xml" > "$metadata_appcast"

  local metadata_file
  for metadata_file in docs/index.html docs/llms.txt; do
    local metadata_surface="$VERIFY_DIR/$(basename "$metadata_file")"
    git show "origin/${RELEASE_METADATA_BRANCH}:${metadata_file}" > "$metadata_surface"
    if ! grep -Fq "$DOWNLOAD_URL" "$metadata_surface"; then
      echo "ERROR: $metadata_file on $RELEASE_METADATA_BRANCH does not reference $DOWNLOAD_URL." >&2
      exit 1
    fi
  done

  if ! "$ROOT/scripts/verify_update_flow.sh" \
      --version "$VERSION" \
      --appcast "$metadata_appcast" \
      --dmg "$hosted_dmg" \
      --require-release-notes \
      --require-notarized; then
    echo "ERROR: Existing release metadata or hosted artifact failed update-flow validation." >&2
    exit 1
  fi

  HOSTED_MOUNT_POINT=$(hdiutil attach "$hosted_dmg" -nobrowse -readonly 2>&1 | awk -F'\t' '/\/Volumes\// {print $NF; exit}')
  if [[ -z "$HOSTED_MOUNT_POINT" ]]; then
    echo "ERROR: Could not mount hosted DMG while resuming $TAG." >&2
    exit 1
  fi
  if ! "$ROOT/scripts/verify_signed_cloud_entitlements.sh" \
      "$HOSTED_MOUNT_POINT/Muesli.app" \
      Production \
      com.muesli.app \
      iCloud.com.mueslihq.muesli \
      production; then
    echo "ERROR: Existing hosted app failed Production CloudKit entitlement validation." >&2
    exit 1
  fi
  hdiutil detach "$HOSTED_MOUNT_POINT" -quiet 2>/dev/null
  HOSTED_MOUNT_POINT=""

  if [[ "$metadata_pr_count" == "0" ]]; then
    RELEASE_METADATA_PR_URL=$(gh pr create \
      --repo Muesli-HQ/muesli \
      --base main \
      --head "$RELEASE_METADATA_BRANCH" \
      --title "Update release metadata for v${VERSION}" \
      --body "Publishes the verified v${VERSION} Sparkle appcast entry and aligns the landing-page download metadata with the verified GitHub DMG. The GitHub release was kept as a draft through validation and creation of this PR; the public appcast remains unchanged until this PR is reviewed and merged.")
    echo "  Recreated missing release metadata PR: $RELEASE_METADATA_PR_URL"
  fi

  RELEASE_METADATA_VALIDATED=1
  muesli_require_release_publication_ready \
    "$RELEASE_METADATA_VALIDATED" \
    "$RELEASE_METADATA_PR_URL"
  if [[ "$release_is_draft" == "true" ]]; then
    gh release edit "$TAG" \
      --draft=false \
      --title "$RELEASE_TITLE" \
      "${RELEASE_NOTES_ARGS[@]}"
    echo "  Resumed and published verified GitHub release $TAG."
  else
    echo "  GitHub release $TAG is already public; hosted artifact and metadata were revalidated."
  fi

  RELEASE_URL=$(gh release view "$TAG" --json url -q .url)
  verify_homebrew_autobump
  echo "  Release: $RELEASE_URL"
  echo "  Production appcast publication is pending merge of $RELEASE_METADATA_PR_URL."
  return 0
}

if ! REMOTE_RELEASE_METADATA_REF=$(git ls-remote --heads origin "$RELEASE_METADATA_BRANCH"); then
  echo "ERROR: Could not query remote release metadata branch $RELEASE_METADATA_BRANCH." >&2
  exit 1
fi
if [[ -n "$REMOTE_RELEASE_METADATA_REF" ]]; then
  resume_existing_release_publication
  exit 0
fi
if git show-ref --verify --quiet "refs/heads/${RELEASE_METADATA_BRANCH}"; then
  echo "ERROR: Local release metadata branch exists without its remote counterpart: $RELEASE_METADATA_BRANCH" >&2
  exit 1
fi

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
  MUESLI_PROVISIONING_PROFILE="$PROVISIONING_PROFILE"
  MUESLI_SIGN_IDENTITY="$SIGN_IDENTITY"
  MUESLI_ICLOUD_CONTAINER_ENVIRONMENT="Production"
  MUESLI_TELEMETRYDECK_APP_ID="$MUESLI_TELEMETRYDECK_PRODUCTION_APP_ID"
  MUESLI_TELEMETRY_CHANNEL="production"
  "${BUILD_ENV[@]}"
)
echo "  Bundle ID: com.muesli.app"
echo "  Profile:   $PROVISIONING_PROFILE"
echo "  Identity:  $SIGN_IDENTITY"
echo "y" | env "${RELEASE_BUILD_ENV[@]}" "$ROOT/scripts/build_native_app.sh" > /dev/null
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

"$ROOT/scripts/verify_signed_cloud_entitlements.sh" \
  "$MOUNT_POINT/Muesli.app" \
  Production \
  com.muesli.app \
  iCloud.com.mueslihq.muesli \
  production

hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null
MOUNT_POINT=""

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
RELEASE_PREP_COMMITTED=0
if git diff --cached --quiet; then
  echo "  No version metadata changes to commit."
else
  git commit -m "Prepare release v${VERSION}"
  RELEASE_PREP_COMMITTED=1
fi
if [[ "$RELEASE_PR_MODE" == "1" ]]; then
  git push -u origin HEAD
  echo "  Pushed release prep to ${CURRENT_BRANCH} for review."
elif [[ "$RELEASE_PREP_COMMITTED" == "1" ]]; then
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

if [[ "$RELEASE_PR_MODE" == "1" ]]; then
  assert_release_branch_contains_origin_main
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
  "${RELEASE_NOTES_ARGS[@]}" \
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

"$ROOT/scripts/verify_signed_cloud_entitlements.sh" \
  "$HOSTED_MOUNT_POINT/Muesli.app" \
  Production \
  com.muesli.app \
  iCloud.com.mueslihq.muesli \
  production

hdiutil detach "$HOSTED_MOUNT_POINT" -quiet 2>/dev/null
HOSTED_MOUNT_POINT=""

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

# --- Step 11: Validate appcast metadata and open its PR while release stays draft ---
echo "[11/13] Preparing appcast and release metadata PR..."
GENERATED_APPCAST="$VERIFY_DIR/generated-appcast.xml"
"$GENERATE_APPCAST" "$OUTPUT_DIR" -o "$GENERATED_APPCAST"
if [[ "$RELEASE_NOTES_FROM_FILE" == "1" ]]; then
  python3 "$UPDATE_APPCAST_RELEASE_NOTES" \
    "$GENERATED_APPCAST" \
    --sparkle-version "$VERSION" \
    --short-version "$VERSION" \
    < "$RELEASE_NOTES_FILE"
else
  printf '%s\n' "$RELEASE_NOTES" | python3 "$UPDATE_APPCAST_RELEASE_NOTES" \
    "$GENERATED_APPCAST" \
    --sparkle-version "$VERSION" \
    --short-version "$VERSION"
fi

python3 "$MERGE_APPCAST_ITEM" \
  --existing "$ROOT/docs/appcast.xml" \
  --generated "$GENERATED_APPCAST" \
  --version "$VERSION" \
  --output "$ROOT/docs/appcast.xml"

# Keep the marketing/docs surface aligned with the published GitHub Release.
sed -i '' "s|https://github.com/Muesli-HQ/muesli/releases/download/[^\"]*\\.dmg|$DOWNLOAD_URL|g" "$ROOT/docs/index.html"
sed -i '' "s|https://github.com/Muesli-HQ/muesli/releases/download/.*\\.dmg|$DOWNLOAD_URL|g" "$ROOT/docs/llms.txt"

echo "  Verifying Sparkle update flow metadata..."
"$ROOT/scripts/verify_update_flow.sh" \
  --version "$VERSION" \
  --dmg "$DMG_PATH" \
  --require-release-notes \
  --require-notarized
RELEASE_METADATA_VALIDATED=1

git add docs/appcast.xml docs/index.html docs/llms.txt
if git diff --cached --quiet; then
  echo "ERROR: Release metadata did not change for v${VERSION}; refusing to publish an appcast-less release." >&2
  exit 1
else
  git switch -c "$RELEASE_METADATA_BRANCH"
  git commit --signoff -m "Update release metadata for v${VERSION}"
  git push -u origin "$RELEASE_METADATA_BRANCH"
  RELEASE_METADATA_PR_URL=$(gh pr create \
    --base main \
    --head "$RELEASE_METADATA_BRANCH" \
    --title "Update release metadata for v${VERSION}" \
    --body "Publishes the verified v${VERSION} Sparkle appcast entry and aligns the landing-page download metadata with the verified GitHub DMG. The GitHub release was kept as a draft through validation and creation of this PR; the public appcast remains unchanged until this PR is reviewed and merged.")
  echo "  Release metadata PR: $RELEASE_METADATA_PR_URL"
fi

# --- Step 12: Publish only after appcast validation and metadata PR creation ---
echo "[12/13] Publishing verified GitHub release..."
muesli_require_release_publication_ready \
  "$RELEASE_METADATA_VALIDATED" \
  "${RELEASE_METADATA_PR_URL:-}"
gh release edit "$TAG" \
  --draft=false \
  --title "$RELEASE_TITLE" \
  "${RELEASE_NOTES_ARGS[@]}"

RELEASE_URL=$(gh release view "$TAG" --json url -q .url)
echo "  Release published: $RELEASE_URL"

# --- Step 13: Verify the official Homebrew cask can see the new release ---
echo "[13/13] Verifying official Homebrew cask livecheck..."
verify_homebrew_autobump

echo ""
echo "=== Release complete ==="
echo "  Version: ${VERSION}"
echo "  DMG: $DMG_PATH"
echo "  Release: $RELEASE_URL"
echo "  Hosted asset verified."
echo "  Production appcast publication is pending merge of $RELEASE_METADATA_PR_URL."
if [[ "$HOMEBREW_CHECK_STATUS" == "verified" ]]; then
  echo "  Homebrew cask livecheck verified for ${HOMEBREW_CASK}."
  echo "  Watch Homebrew/homebrew-cask for the BrewTestBot autobump PR."
elif [[ "$HOMEBREW_CHECK_STATUS" == "warning" ]]; then
  echo "  Homebrew cask verification had warnings; check ${HOMEBREW_CASK} manually."
fi
