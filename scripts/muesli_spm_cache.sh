#!/usr/bin/env bash

# Shared SwiftPM scratch-path resolution for local Muesli builds.
#
# Precedence:
#   1. MUESLI_SWIFTPM_SCRATCH_PATH, when explicitly set
#   2. MUESLI_EXTERNAL_SPM_CACHE_ROOT/<channel>, when that root exists
#   3. ~/Library/Caches/muesli-spm/<channel>
#
# Set MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1 to let SwiftPM use the package-local
# .build directory.

muesli_default_spm_cache_root() {
  local external_root="${MUESLI_EXTERNAL_SPM_CACHE_ROOT:-/Volumes/MuesliBuildCache/muesli-spm}"
  if [[ -d "$external_root" ]]; then
    printf '%s\n' "$external_root"
  else
    printf '%s\n' "$HOME/Library/Caches/muesli-spm"
  fi
}

muesli_resolve_spm_scratch_path() {
  local channel="${1:-dev}"
  if [[ -n "${MUESLI_SWIFTPM_SCRATCH_PATH:-}" ]]; then
    printf '%s\n' "$MUESLI_SWIFTPM_SCRATCH_PATH"
    return 0
  fi
  if [[ -n "${MUESLI_SWIFTPM_SCRATCH_CHANNEL:-}" ]]; then
    channel="$MUESLI_SWIFTPM_SCRATCH_CHANNEL"
  fi
  printf '%s/%s\n' "$(muesli_default_spm_cache_root)" "$channel"
}
