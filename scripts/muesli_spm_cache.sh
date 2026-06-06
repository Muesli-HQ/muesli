#!/usr/bin/env bash

# Shared SwiftPM scratch-path resolution for local Muesli builds.
#
# Resolution precedence, unless disabled:
#   1. MUESLI_SWIFTPM_SCRATCH_PATH, when explicitly set
#   2. MUESLI_EXTERNAL_SPM_CACHE_ROOT/<channel>, when that root exists
#   3. ~/Library/Caches/muesli-spm/<channel>
#
# MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1 takes precedence over all other path
# settings and lets SwiftPM use the package-local .build directory.

[[ -n "${_MUESLI_SPM_CACHE_LOADED:-}" ]] && return 0
_MUESLI_SPM_CACHE_LOADED=1

muesli_spm_scratch_disabled() {
  [[ "${MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH:-0}" == "1" ]]
}

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

muesli_worktree_spm_scratch_channel() {
  local channel="${1:-dev}"
  local root="${2:-$PWD}"
  local root_name
  local root_hash
  root_name="$(basename "$root")"
  root_hash="$(printf '%s' "$root" | cksum | awk '{print $1}')"
  printf 'worktrees/%s-%s/%s\n' "$root_name" "$root_hash" "$channel"
}

muesli_spm_artifacts_dir() {
  local package_dir="$1"
  local scratch_path="${2:-}"
  if [[ -n "$scratch_path" ]]; then
    printf '%s/artifacts\n' "$scratch_path"
  else
    printf '%s/.build/artifacts\n' "$package_dir"
  fi
}
