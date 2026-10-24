#!/usr/bin/env bash
set -euo pipefail
bundle="${1:?app bundle required}"
executable="${2:?main executable name required}"
# Fail closed if the principal executable cannot be inspected.
otool -L "$bundle/Contents/MacOS/$executable" >/dev/null
while IFS= read -r -d '' binary; do
  case "$(file -b "$binary")" in
    *Mach-O*)
      links="$(otool -L "$binary")"
      if [[ "$links" == *LiteRT* || "$links" == *litert* ]]; then
        echo "Unexpected LiteRT binary or load command in $binary" >&2
        exit 1
      fi
      ;;
  esac
done < <(find "$bundle/Contents" -type f -print0)
echo "Verified app bundle has no LiteRT Mach-O dependencies."
