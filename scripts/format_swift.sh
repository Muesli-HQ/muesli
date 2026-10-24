#!/usr/bin/env bash
set -euo pipefail

# Accept swift-format's --offsets when formatting existing files to avoid churn.
mode=(format --in-place)
if [[ "${1:-}" == "--check" ]]; then
  mode=(lint --strict)
  shift
fi
if [[ $# -eq 0 ]]; then
  echo "Usage: $0 [--check] [swift-format options] <changed Swift files...>" >&2
  exit 2
fi
swift format "${mode[@]}" \
  --configuration '{"indentation":{"spaces":4},"lineLength":140,"rules":{"UseForInLoops":false}}' "$@"
