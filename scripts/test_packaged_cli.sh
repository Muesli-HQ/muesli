#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/localvqe_runtime.sh"
BUILD_CONFIG="${1:-debug}"
INSTALL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/muesli-packaging-test.XXXXXX")"
APP_BUNDLE_NAME="MuesliPackagingTest.app"
APP_PATH="$INSTALL_ROOT/$APP_BUNDLE_NAME"
APP_BIN="$APP_PATH/Contents/MacOS/Muesli"
CLI_BIN="$APP_PATH/Contents/MacOS/muesli-cli"
SPEC_OUTPUT="$INSTALL_ROOT/muesli-cli-spec.json"
TRANSCRIBE_HELP_OUTPUT="$INSTALL_ROOT/muesli-cli-transcribe-help.txt"

cleanup() {
  rm -rf "$INSTALL_ROOT"
}
trap cleanup EXIT

LOCALVQE_LIB_DIR="${MUESLI_LOCALVQE_LIB_DIR:-$ROOT/native/MuesliNative/LocalVQE/lib}"
if ! muesli_localvqe_runtime_is_complete "$LOCALVQE_LIB_DIR"; then
  echo "Building LocalVQE runtime for packaging smoke test..."
  "$ROOT/scripts/build_localvqe.sh"
fi

echo "Building isolated app bundle in $INSTALL_ROOT"
MUESLI_INSTALL_DIR="$INSTALL_ROOT" \
MUESLI_APP_BUNDLE_NAME="$APP_BUNDLE_NAME" \
MUESLI_SKIP_SIGN=1 \
MUESLI_REQUIRE_LOCALVQE=1 \
"$ROOT/scripts/build_native_app.sh" "$BUILD_CONFIG"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected packaged app at $APP_PATH" >&2
  exit 1
fi

if [[ ! -x "$APP_BIN" ]]; then
  echo "Missing app executable at $APP_BIN" >&2
  exit 1
fi

if [[ ! -x "$CLI_BIN" ]]; then
  echo "Missing CLI executable at $CLI_BIN" >&2
  exit 1
fi

MACOS_DIR="$APP_PATH/Contents/MacOS"
if ! muesli_localvqe_runtime_is_complete "$MACOS_DIR"; then
  echo "Packaged app is missing a complete LocalVQE runtime under Contents/MacOS." >&2
  echo "Expected liblocalvqe*.dylib and libggml-base*.dylib." >&2
  ls -la "$MACOS_DIR" >&2 || true
  exit 1
fi

if [[ ! -f "$APP_PATH/Contents/Resources/Models/localvqe/localvqe-v1.2-1.3M-f32.gguf" ]]; then
  echo "Packaged app is missing the LocalVQE model under Contents/Resources/Models/localvqe/." >&2
  exit 1
fi

"$CLI_BIN" spec > "$SPEC_OUTPUT"
"$CLI_BIN" transcribe --help > "$TRANSCRIBE_HELP_OUTPUT"

if ! grep -q '"command" : "muesli-cli spec"' "$SPEC_OUTPUT"; then
  echo "Packaged CLI did not return the expected spec payload." >&2
  cat "$SPEC_OUTPUT" >&2
  exit 1
fi

if ! grep -q 'USAGE: muesli-cli transcribe' "$TRANSCRIBE_HELP_OUTPUT"; then
  echo "Packaged CLI did not return transcribe help." >&2
  cat "$TRANSCRIBE_HELP_OUTPUT" >&2
  exit 1
fi

echo "Packaged CLI smoke test passed."
echo "Verified:"
echo "  - $APP_BIN"
echo "  - $CLI_BIN"
echo "  - LocalVQE runtime + model bundled"
