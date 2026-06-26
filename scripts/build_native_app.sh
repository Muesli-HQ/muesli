#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/muesli_spm_cache.sh"
PACKAGE_DIR="$ROOT/native/MuesliNative"
DIST_DIR="$ROOT/dist-native"
INSTALL_DIR="${MUESLI_INSTALL_DIR:-/Applications}"
BUILD_CONFIG="${1:-release}"
APP_BINARY="MuesliNativeApp"
CLI_BINARY="muesli-cli"
APP_NAME="${MUESLI_APP_NAME:-Muesli}"
APP_DISPLAY_NAME="${MUESLI_DISPLAY_NAME:-$APP_NAME}"
APP_BUNDLE_NAME="${MUESLI_APP_BUNDLE_NAME:-$APP_NAME.app}"
APP_EXECUTABLE_NAME="${MUESLI_EXECUTABLE_NAME:-Muesli}"
APP_SUPPORT_DIR_NAME="${MUESLI_SUPPORT_DIR_NAME:-$APP_DISPLAY_NAME}"
BUNDLE_ID="${MUESLI_BUNDLE_ID:-com.muesli.app}"
DEFAULT_APP_VERSION="0.7.1"
APP_VERSION="${MUESLI_BUILD_VERSION:-$DEFAULT_APP_VERSION}"
APP_BUNDLE_VERSION="${MUESLI_BUNDLE_VERSION:-$APP_VERSION}"
APP_SHORT_VERSION="${MUESLI_SHORT_VERSION:-$APP_VERSION}"
SPARKLE_FEED_URL="${MUESLI_SPARKLE_FEED_URL-https://muesli-hq.github.io/muesli/appcast.xml}"
SPARKLE_EDKEY="${MUESLI_SPARKLE_EDKEY-ok9CQBJ3f0MJ2GXuGBubc6VyeWyb5exmqP2b9DceqH4=}"
STAGED_APP_DIR="$DIST_DIR/$APP_BUNDLE_NAME"
APP_DIR="$INSTALL_DIR/$APP_BUNDLE_NAME"
DEFAULT_SIGN_IDENTITY="Developer ID Application: Pranav Hari Guruvayurappan (58W55QJ567)"
SIGN_IDENTITY="${MUESLI_SIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}"
SKIP_SIGN="${MUESLI_SKIP_SIGN:-0}"
PROVISIONING_PROFILE="${MUESLI_PROVISIONING_PROFILE:-}"
CODESIGN_TIMESTAMP="${MUESLI_CODESIGN_TIMESTAMP:---timestamp}"
if [[ "$CODESIGN_TIMESTAMP" == "none" ]]; then
  CODESIGN_TIMESTAMP="--timestamp=none"
fi

SWIFT_BUILD_ARGS=(--package-path "$PACKAGE_DIR" -c "$BUILD_CONFIG")
if ! muesli_spm_scratch_disabled; then
  DEFAULT_SCRATCH_CHANNEL="release"
  if [[ "$BUILD_CONFIG" == "debug" ]]; then
    DEFAULT_SCRATCH_CHANNEL="$(muesli_worktree_spm_scratch_channel dev "$ROOT")"
  fi
  SWIFTPM_SCRATCH_PATH="$(muesli_resolve_spm_scratch_path "$DEFAULT_SCRATCH_CHANNEL")"
  mkdir -p "$SWIFTPM_SCRATCH_PATH"
  SWIFT_BUILD_ARGS+=(--scratch-path "$SWIFTPM_SCRATCH_PATH")
  echo "Using SwiftPM scratch path: $SWIFTPM_SCRATCH_PATH"
fi

mkdir -p "$DIST_DIR"

set +e
swift build "${SWIFT_BUILD_ARGS[@]}" --product "$APP_BINARY"
status=$?
set -e

if [[ $status -ne 0 ]]; then
  echo "Swift build failed." >&2
  exit $status
fi

set +e
swift build "${SWIFT_BUILD_ARGS[@]}" --product "$CLI_BINARY"
status=$?
set -e

if [[ $status -ne 0 ]]; then
  echo "Swift CLI build failed." >&2
  exit $status
fi

BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
APP_BIN="$BIN_DIR/$APP_BINARY"
CLI_BIN="$BIN_DIR/$CLI_BINARY"

rm -rf "$STAGED_APP_DIR"
mkdir -p "$STAGED_APP_DIR/Contents/MacOS" "$STAGED_APP_DIR/Contents/Resources"

cp "$APP_BIN" "$STAGED_APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
chmod +x "$STAGED_APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
cp "$CLI_BIN" "$STAGED_APP_DIR/Contents/MacOS/$CLI_BINARY"
chmod +x "$STAGED_APP_DIR/Contents/MacOS/$CLI_BINARY"

# Bundle SwiftPM-linked frameworks (rpath is @loader_path, so they go next to the binary)
for framework in "$BIN_DIR"/*.framework; do
  [[ -d "$framework" ]] || continue
  ditto "$framework" "$STAGED_APP_DIR/Contents/MacOS/$(basename "$framework")"
done

# Bundle SPM resource bundles (CoreML models, privacy manifests, etc.)
for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  ditto "$bundle" "$STAGED_APP_DIR/Contents/Resources/$(basename "$bundle")"
done

# Bundle optional LocalVQE runtime if it has been built for local AEC testing.
LOCALVQE_LIB_DIR="${MUESLI_LOCALVQE_LIB_DIR:-$ROOT/native/MuesliNative/LocalVQE/lib}"
if [[ -d "$LOCALVQE_LIB_DIR" ]]; then
  find "$LOCALVQE_LIB_DIR" -maxdepth 1 \( -name "liblocalvqe*.dylib" -o -name "libggml*.dylib" -o -name "libggml*.so" \) \( -type f -o -type l \) | while read -r dylib; do
    cp -P "$dylib" "$STAGED_APP_DIR/Contents/MacOS/$(basename "$dylib")"
  done
fi
LOCALVQE_MODEL_PATH="${MUESLI_LOCALVQE_MODEL_PATH:-$ROOT/native/MuesliNative/LocalVQE/models/localvqe-v1.2-1.3M-f32.gguf}"
if [[ -f "$LOCALVQE_MODEL_PATH" ]]; then
  mkdir -p "$STAGED_APP_DIR/Contents/Resources/Models/localvqe"
  cp "$LOCALVQE_MODEL_PATH" "$STAGED_APP_DIR/Contents/Resources/Models/localvqe/localvqe-v1.2-1.3M-f32.gguf"
fi

# Bundle assets
cp "$ROOT/assets/menu_m_template.png" "$STAGED_APP_DIR/Contents/Resources/menu_m_template.png"
cp "$ROOT/assets/muesli.icns" "$STAGED_APP_DIR/Contents/Resources/muesli.icns"
cp "$ROOT/assets/zoom-app.png" "$STAGED_APP_DIR/Contents/Resources/zoom-app.png"
cp "$ROOT/assets/Google_Meet_icon_(2020).svg.png" "$STAGED_APP_DIR/Contents/Resources/google-meet.png"
cp "$ROOT/assets/Microsoft_Office_Teams_(2025–present).svg.png" "$STAGED_APP_DIR/Contents/Resources/teams.png"
cp "$ROOT/assets/Slack_icon_2019.svg.png" "$STAGED_APP_DIR/Contents/Resources/slack.png"
cp "$ROOT/assets/Nvidia_logo.svg.png" "$STAGED_APP_DIR/Contents/Resources/nvidia-logo.png"
cp "$ROOT/assets/OpenAI_Logo.svg.png" "$STAGED_APP_DIR/Contents/Resources/openai-logo.png"
cp "$ROOT/assets/cohere.png" "$STAGED_APP_DIR/Contents/Resources/cohere-logo.png"
cp "$ROOT/assets/Qwen_logo.svg.png" "$STAGED_APP_DIR/Contents/Resources/qwen-logo.png"
if [[ -d "$ROOT/assets/fonts" ]]; then
  ditto "$ROOT/assets/fonts" "$STAGED_APP_DIR/Contents/Resources/fonts"
fi
if [[ -d "$ROOT/assets/audio" ]]; then
  ditto "$ROOT/assets/audio" "$STAGED_APP_DIR/Contents/Resources/audio"
fi

cat > "$STAGED_APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUNDLE_VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_SHORT_VERSION</string>
  <key>CFBundleExecutable</key>
  <string>$APP_EXECUTABLE_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>muesli.icns</string>
  <key>MuesliSupportDirectoryName</key>
  <string>$APP_SUPPORT_DIR_NAME</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>14.2</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>$APP_DISPLAY_NAME records microphone audio for dictation.</string>
  <key>NSInputMonitoringUsageDescription</key>
  <string>$APP_DISPLAY_NAME monitors keyboard events to trigger push-to-talk dictation.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>$APP_DISPLAY_NAME captures system audio from other applications during meeting recordings.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>$APP_DISPLAY_NAME captures screen content for meeting context.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>$APP_DISPLAY_NAME reads calendar events to help with meeting recordings.</string>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_EDKEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
</dict>
</plist>
PLIST

# Replace existing app (no prompt — that's what this script is for)
if [[ -d "$APP_DIR" ]]; then
  echo "Replacing $APP_DIR"
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$APP_DIR"
ditto "$STAGED_APP_DIR" "$APP_DIR"

if [[ "$SKIP_SIGN" != "1" ]]; then
  if ! security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    echo "Signing identity not found: $SIGN_IDENTITY" >&2
    echo "For local contributor builds without this certificate, run: MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh" >&2
    exit 1
  fi

  if [[ -n "$PROVISIONING_PROFILE" ]]; then
    if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
      echo "Provisioning profile not found: $PROVISIONING_PROFILE" >&2
      exit 1
    fi
    cp "$PROVISIONING_PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
  fi

  # Sign all bundled frameworks, including nested Sparkle executables.
  find "$APP_DIR/Contents/MacOS" -maxdepth 1 -name "*.framework" -type d | while read -r framework; do
    if [[ "$(basename "$framework")" == "Sparkle.framework" ]]; then
      find "$framework" -type f -perm +111 | while read -r binary; do
        if file "$binary" | grep -q "Mach-O"; then
          codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
            --sign "$SIGN_IDENTITY" "$binary"
        fi
      done
      find "$framework" -name "*.xpc" -type d | while read -r xpc; do
        codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
          --sign "$SIGN_IDENTITY" "$xpc"
      done
      find "$framework" -name "*.app" -type d | while read -r app; do
        codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
          --sign "$SIGN_IDENTITY" "$app"
      done
    fi

    codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
      --sign "$SIGN_IDENTITY" \
      "$framework"
  done

  # Sign loose native runtime libraries loaded via dlopen. Hardened runtime
  # library validation requires these to have the same Team ID as the app.
  find "$APP_DIR/Contents/MacOS" -maxdepth 1 \( -name "liblocalvqe*.dylib" -o -name "libggml*.dylib" -o -name "libggml*.so" \) -type f | while read -r library; do
    if file "$library" | grep -q "Mach-O"; then
      codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
        --sign "$SIGN_IDENTITY" \
        "$library"
    fi
  done

  codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR/Contents/MacOS/muesli-cli"

  # Sign the app bundle with hardened runtime, secure timestamp, and entitlements
  ENTITLEMENTS="${MUESLI_ENTITLEMENTS:-$ROOT/scripts/Muesli.entitlements}"
  CODESIGN_ENTITLEMENTS="$ENTITLEMENTS"
  TEMP_ENTITLEMENTS=""
  APS_ENVIRONMENT="${MUESLI_APS_ENVIRONMENT:-}"
  ICLOUD_CONTAINER_ENVIRONMENT="${MUESLI_ICLOUD_CONTAINER_ENVIRONMENT:-}"
  PROFILE_PLIST=""
  SIGN_TEMP_FILES=()
  cleanup_sign_temp_files() {
    local temp_file
    for temp_file in "${SIGN_TEMP_FILES[@]:-}"; do
      [[ -n "$temp_file" ]] && rm -f "$temp_file"
    done
  }
  trap cleanup_sign_temp_files EXIT
  if [[ -n "$PROVISIONING_PROFILE" ]]; then
    PROFILE_PLIST="$(mktemp "${TMPDIR:-/tmp}/muesli-profile.XXXXXX")"
    SIGN_TEMP_FILES+=("$PROFILE_PLIST")
    if ! security cms -D -i "$PROVISIONING_PROFILE" > "$PROFILE_PLIST" 2>/dev/null; then
      echo "ERROR: could not decode provisioning profile: $PROVISIONING_PROFILE" >&2
      exit 1
    fi

    PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    if [[ -z "$PROFILE_APP_IDENTIFIER" ]]; then
      PROFILE_APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
    fi
    if [[ -n "$PROFILE_APP_IDENTIFIER" ]]; then
      PROFILE_BUNDLE_ID="${PROFILE_APP_IDENTIFIER#*.}"
      # shellcheck disable=SC2053 # Intentionally glob-match wildcard App IDs such as com.muesli.*.
      if [[ "$BUNDLE_ID" != $PROFILE_BUNDLE_ID ]]; then
        echo "ERROR: provisioning profile app identifier '$PROFILE_APP_IDENTIFIER' does not match bundle ID '$BUNDLE_ID'." >&2
        exit 1
      fi
      echo "Using provisioning profile app identifier: $PROFILE_APP_IDENTIFIER"
    fi

    if [[ -z "$APS_ENVIRONMENT" ]]; then
      APS_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.aps-environment' "$PROFILE_PLIST" 2>/dev/null || true)"
      if [[ -z "$APS_ENVIRONMENT" ]]; then
        APS_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:aps-environment' "$PROFILE_PLIST" 2>/dev/null || true)"
      fi
    fi
  fi

  if [[ -n "$APS_ENVIRONMENT" || -n "$PROFILE_PLIST" ]]; then
    TEMP_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/muesli-entitlements.XXXXXX")"
    SIGN_TEMP_FILES+=("$TEMP_ENTITLEMENTS")
    cp "$ENTITLEMENTS" "$TEMP_ENTITLEMENTS"
    copy_profile_string_entitlement() {
      local key="$1"
      local value
      [[ -n "$PROFILE_PLIST" ]] || return 0
      value="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$PROFILE_PLIST" 2>/dev/null || true)"
      [[ -n "$value" ]] || return 0
      if ! /usr/libexec/PlistBuddy -c "Set :$key $value" "$TEMP_ENTITLEMENTS" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$TEMP_ENTITLEMENTS"
      fi
    }
    copy_explicit_icloud_container_environment_entitlement() {
      local key="$1"
      local value
      [[ -n "$PROFILE_PLIST" ]] || return 0
      [[ -n "$ICLOUD_CONTAINER_ENVIRONMENT" ]] || return 0
      /usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$PROFILE_PLIST" >/dev/null 2>&1 || return 0
      value="$(printf '%s' "$ICLOUD_CONTAINER_ENVIRONMENT" | tr '[:upper:]' '[:lower:]')"
      if [[ "$value" != "development" && "$value" != "production" ]]; then
        echo "ERROR: unsupported iCloud container environment '$value'. Expected development or production." >&2
        exit 1
      fi
      /usr/libexec/PlistBuddy -c "Delete :$key" "$TEMP_ENTITLEMENTS" >/dev/null 2>&1 || true
      /usr/libexec/PlistBuddy -c "Add :$key string $value" "$TEMP_ENTITLEMENTS"
      echo "Using iCloud entitlement: $key=$value"
    }
    copy_profile_string_entitlement "com.apple.application-identifier"
    copy_profile_string_entitlement "application-identifier"
    copy_profile_string_entitlement "com.apple.developer.team-identifier"
    # Do not copy this profile entitlement by default: Apple profiles may store
    # it as an array, while CloudKit expects a single lowercase runtime value.
    copy_explicit_icloud_container_environment_entitlement "com.apple.developer.icloud-container-environment"
    if [[ -n "$APS_ENVIRONMENT" ]]; then
      if ! /usr/libexec/PlistBuddy -c "Set :com.apple.developer.aps-environment $APS_ENVIRONMENT" "$TEMP_ENTITLEMENTS" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :com.apple.developer.aps-environment string $APS_ENVIRONMENT" "$TEMP_ENTITLEMENTS"
      fi
    fi
    CODESIGN_ENTITLEMENTS="$TEMP_ENTITLEMENTS"
    if [[ -n "$APS_ENVIRONMENT" ]]; then
      echo "Using APNs entitlement: com.apple.developer.aps-environment=$APS_ENVIRONMENT"
    fi
  fi
  codesign --force --options runtime "$CODESIGN_TIMESTAMP" \
    --entitlements "$CODESIGN_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR"
  if [[ -n "$PROFILE_PLIST" ]]; then
    rm -f "$PROFILE_PLIST"
  fi
  if [[ -n "$TEMP_ENTITLEMENTS" ]]; then
    rm -f "$TEMP_ENTITLEMENTS"
  fi
  trap - EXIT

  # Deep-verify entire bundle — fail fast if any component has an invalid signature
  echo "Verifying deep signature..."
  if ! codesign --verify --deep --strict "$APP_DIR" 2>&1; then
    echo "ERROR: Deep signature verification failed" >&2
    exit 1
  fi
  echo "  Deep signature valid."
else
  echo "Skipping codesign because MUESLI_SKIP_SIGN=1"
fi

rm -rf "$STAGED_APP_DIR"

echo "Installed $APP_DIR ($(du -sh "$APP_DIR" | cut -f1))"
