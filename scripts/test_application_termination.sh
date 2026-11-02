#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
xcrun swiftc -parse-as-library \
  "$root/native/MuesliNative/Sources/MuesliNativeApp/ApplicationTermination.swift" \
  "$root/native/MuesliNative/Sources/MuesliNativeApp/ShutdownDeadline.swift" \
  "$root/scripts/fixtures/application_termination_probe.swift" \
  -o "$tmp_dir/probe"
if [[ "${1:-}" == "--direct" ]]; then
  "$tmp_dir/probe" --direct
else
  "$tmp_dir/probe"
  "$tmp_dir/probe" --stuck
fi
