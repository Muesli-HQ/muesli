#!/usr/bin/env bash
set -euo pipefail

if command -v muesli-cli >/dev/null 2>&1; then
  command -v muesli-cli
  exit 0
fi

if [[ -x "/Applications/Muesli.app/Contents/MacOS/muesli-cli" ]]; then
  echo "/Applications/Muesli.app/Contents/MacOS/muesli-cli"
  exit 0
fi

if [[ -x "native/MuesliNative/.build/debug/muesli-cli" ]]; then
  echo "$(pwd)/native/MuesliNative/.build/debug/muesli-cli"
  exit 0
fi

if [[ -x "native/MuesliNative/.build/release/muesli-cli" ]]; then
  echo "$(pwd)/native/MuesliNative/.build/release/muesli-cli"
  exit 0
fi

exit 1
