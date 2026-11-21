#!/usr/bin/env bash
# Deterministic cache key for the disposable native-build cache benchmark.
# Shared by debug-cache-benchmark-seed.yml (producer) and ci.yml (consumer) so
# both sides compute byte-identical keys for compatible changes.
#
# usage: ci_debug_cache_benchmark_key.sh <base-sha> [manifest-rev]
#   manifest-rev omitted: hash Package.swift/Package.resolved from the workspace.
#   manifest-rev given:   hash them as committed at that git revision.
# Writes key, manifest_hash, toolchain_hash, path to $GITHUB_OUTPUT (if set).
set -euo pipefail

base_sha="${1:?base sha required}"
manifest_rev="${2:-}"
[[ "$base_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid base sha: $base_sha" >&2; exit 2; }

cache_path=native/MuesliNative/.build
manifests=(native/MuesliNative/Package.swift native/MuesliNative/Package.resolved native/AIElementsSwift/Package.swift)

sha() { shasum -a 256 | cut -c1-"$1"; }

manifest_hash="$(
  for file in "${manifests[@]}"; do
    printf '%s\0' "$file"
    if [[ -n "$manifest_rev" ]]; then
      git show "${manifest_rev}:${file}" 2>/dev/null || printf '<missing>'
    else
      cat "$file" 2>/dev/null || printf '<missing>'
    fi
    printf '\0'
  done | sha 16
)"

# Rolling ImageVersion is intentionally excluded; ImageOS (e.g. macos26) is stable.
toolchain_hash="$(
  {
    printf 'developer_dir=%s\n' "${DEVELOPER_DIR:-}"
    sw_vers -productVersion
    xcrun --sdk macosx --show-sdk-path
    xcrun --sdk macosx --show-sdk-version
    xcodebuild -version
    swift --version 2>&1
  } | sha 16
)"
path_hash="$(printf '%s' "$PWD/$cache_path" | sha 8)"

key="debug-native-build-v1-${RUNNER_OS:?}-${RUNNER_ARCH:?}-${ImageOS:-unknown}-tc${toolchain_hash}-p${path_hash}-m${manifest_hash}-${base_sha}"

echo "key=${key}"
echo "manifest_hash=${manifest_hash}"
echo "toolchain_hash=${toolchain_hash}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "key=${key}"
    echo "manifest_hash=${manifest_hash}"
    echo "toolchain_hash=${toolchain_hash}"
    echo "path=${cache_path}"
  } >> "$GITHUB_OUTPUT"
fi
