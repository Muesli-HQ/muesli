#!/usr/bin/env bash
set -euo pipefail

# Builds and launches an isolated "MuesliCanary" app for Canary CoreML testing.
#
# - Separate bundle ID (com.muesli.canary)
# - Separate support directory (~/Library/Application Support/MuesliCanary/)
# - Optional onboarding reset / clean wipe
# - Optional local model seeding from the sibling stt-quantize-coreml repo
#
# Usage:
#   ./scripts/canary-test.sh
#   ./scripts/canary-test.sh --clean
#   ./scripts/canary-test.sh --reset
#   ./scripts/canary-test.sh --no-seed

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/muesli_telemetry_channels.sh"
CANARY_SUPPORT_DIR="${MUESLI_CANARY_SUPPORT_DIR:-$HOME/Library/Application Support/MuesliCanary}"
CANARY_APP="${MUESLI_CANARY_APP_PATH:-/Applications/MuesliCanary.app}"
CANARY_MODEL_CACHE="${MUESLI_CANARY_CACHE_DIR:-$HOME/.cache/muesli/models/canary-qwen-2.5b-coreml-int8}"
STT_ROOT_DEFAULT="$(cd "$ROOT/.." && pwd)/stt-quantize-coreml"
STT_ROOT="${MUESLI_CANARY_STT_ROOT:-$STT_ROOT_DEFAULT}"
POSTPROC_ROOT="${MUESLI_CANARY_POSTPROC_ROOT:-}"

CLEAN=0
RESET=0
SEED=1

usage() {
  cat <<'EOF'
Build and launch an isolated MuesliCanary app.

Options:
  --clean     Wipe Canary support data before launch.
  --reset     Reset onboarding only (keep data).
  --no-seed   Do not seed/symlink local Canary model assets.
  --help      Show this help text.
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)
      CLEAN=1
      shift
      ;;
    --reset)
      RESET=1
      shift
      ;;
    --no-seed)
      SEED=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

seed_local_models() {
  local source_root="$STT_ROOT"
  local model_root="$source_root/coreml_models"
  local asset_root="$source_root/canary-qwen-coreml/swift_assets"

  [[ -d "$model_root" ]] || die "Missing local coreml_models at $model_root"
  [[ -d "$asset_root" ]] || die "Missing Swift assets at $asset_root"

  mkdir -p "$CANARY_MODEL_CACHE"

  link_if_exists() {
    local source="$1"
    local destination="$2"
    if [[ -e "$source" ]]; then
      ln -sfn "$source" "$destination"
    fi
  }

  link_if_exists "$model_root/encoder_int8.mlpackage" "$CANARY_MODEL_CACHE/encoder_int8.mlpackage"
  link_if_exists "$model_root/projection.mlpackage" "$CANARY_MODEL_CACHE/projection.mlpackage"
  link_if_exists "$model_root/canary_prefill_static.mlpackage" "$CANARY_MODEL_CACHE/canary_prefill_static.mlpackage"
  link_if_exists "$model_root/canary_decode_static.mlpackage" "$CANARY_MODEL_CACHE/canary_decode_static.mlpackage"
  link_if_exists "$model_root/canary_lm_head_int8.mlpackage" "$CANARY_MODEL_CACHE/canary_lm_head_int8.mlpackage"
  ln -sfn "$asset_root/canary_embeddings.bin" "$CANARY_MODEL_CACHE/canary_embeddings.bin"
  ln -sfn "$asset_root/vocab.json" "$CANARY_MODEL_CACHE/vocab.json"
  ln -sfn "$asset_root/canary_mel_filter_bank.bin" "$CANARY_MODEL_CACHE/canary_mel_filter_bank.bin"
  ln -sfn "$asset_root/canary_mel_window.bin" "$CANARY_MODEL_CACHE/canary_mel_window.bin"

  log "Seeded Canary model cache at: $CANARY_MODEL_CACHE"
}

configure_postproc_override() {
  local resolved="$POSTPROC_ROOT"
  if [[ -z "$resolved" ]]; then
    launchctl unsetenv MUESLI_QWEN3_POSTPROC_GGUF 2>/dev/null || true
    launchctl unsetenv MUESLI_QWEN3_POSTPROC_DIR 2>/dev/null || true
    log "Skipping Qwen3 GGUF post-processor override; set MUESLI_CANARY_POSTPROC_ROOT to a local .gguf file or directory"
    return
  fi

  if [[ -d "$resolved" ]]; then
    local first_gguf
    first_gguf="$(find "$resolved" -maxdepth 3 -type f -name '*.gguf' | head -n 1 || true)"
    if [[ -n "$first_gguf" ]]; then
      resolved="$first_gguf"
    fi
  fi

  if [[ -f "$resolved" && "$resolved" == *.gguf ]]; then
    launchctl setenv MUESLI_QWEN3_POSTPROC_GGUF "$resolved"
    launchctl unsetenv MUESLI_QWEN3_POSTPROC_DIR 2>/dev/null || true
    log "Set Qwen3 GGUF post-processor override: $resolved"
  else
    launchctl unsetenv MUESLI_QWEN3_POSTPROC_GGUF 2>/dev/null || true
    launchctl unsetenv MUESLI_QWEN3_POSTPROC_DIR 2>/dev/null || true
    log "Qwen3 GGUF post-processor asset not found at: $resolved"
  fi
}

pkill -f "MuesliCanary.app" 2>/dev/null || true
sleep 0.5

if [[ "$CLEAN" -eq 1 ]]; then
  log "Wiping Canary support data at: $CANARY_SUPPORT_DIR"
  rm -rf "$CANARY_SUPPORT_DIR"
fi

if [[ "$RESET" -eq 1 ]] && [[ -f "$CANARY_SUPPORT_DIR/config.json" ]]; then
  log "Resetting onboarding flag..."
  python3 - <<PY
import json, pathlib
p = pathlib.Path(r"$CANARY_SUPPORT_DIR/config.json")
c = json.loads(p.read_text())
c["has_completed_onboarding"] = False
p.write_text(json.dumps(c, indent=2))
print("  Onboarding reset (data preserved)")
PY
fi

if [[ "$SEED" -eq 1 ]]; then
  seed_local_models
fi

configure_postproc_override

log "Building MuesliCanary (debug, signed)..."
MUESLI_APP_NAME=MuesliCanary \
MUESLI_BUNDLE_ID=com.muesli.canary \
MUESLI_SUPPORT_DIR_NAME=MuesliCanary \
MUESLI_DISPLAY_NAME="MuesliCanary" \
MUESLI_SPARKLE_FEED_URL="" \
MUESLI_TELEMETRYDECK_APP_ID="$MUESLI_TELEMETRYDECK_DEV_APP_ID" \
MUESLI_TELEMETRY_CHANNEL="canary" \
"$ROOT/scripts/build_native_app.sh" debug

log ""
log "Launching MuesliCanary..."
open "$CANARY_APP"

log ""
log "=== Canary Test Ready ==="
log "  App: $CANARY_APP"
log "  Data: $CANARY_SUPPORT_DIR"
log "  Model cache: $CANARY_MODEL_CACHE"
log ""
log "Tips:"
log "  ./scripts/canary-test.sh --clean    # Fresh install / onboarding"
log "  ./scripts/canary-test.sh --reset    # Re-run onboarding only"
log "  ./scripts/canary-test.sh --no-seed  # Test HF download path instead of local assets"
