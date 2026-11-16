#!/usr/bin/env bash
set -euo pipefail

# Repository test helper. Select one installed dev lane explicitly to avoid
# accidentally using another lane's CLI and data during local testing.
if [[ $# != 0 ]]; then
  if [[ $# != 2 || $1 != --lane || ! $2 =~ ^[ABC]$ ]]; then
    echo "Usage: $0 [--lane A|B|C]" >&2
    exit 2
  fi
  cli="/Applications/MuesliDev$2.app/Contents/MacOS/muesli-cli"
  [[ -x "$cli" ]] || { echo "Missing development CLI: $cli" >&2; exit 1; }
  printf '%s\n' "$cli"
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
source "$repo_root/scripts/muesli_spm_cache.sh"
build_dirs=()
if ! muesli_spm_scratch_disabled; then
  channel="$(muesli_worktree_spm_scratch_channel dev "$repo_root")"
  build_dirs+=("$(muesli_resolve_spm_scratch_path "$channel")")
fi
build_dirs+=("$repo_root/native/MuesliNative/.build")
for dir in "${build_dirs[@]}"; do
  for config in debug release; do
    if [[ -x "$dir/$config/muesli-cli" ]]; then
      printf '%s\n' "$dir/$config/muesli-cli"
      exit 0
    fi
  done
done

if [[ -x /Applications/MuesliDev.app/Contents/MacOS/muesli-cli ]]; then
  printf '%s\n' /Applications/MuesliDev.app/Contents/MacOS/muesli-cli
  exit 0
fi
if command -v muesli-cli; then exit 0; fi
cli=/Applications/Muesli.app/Contents/MacOS/muesli-cli
[[ -x "$cli" ]] || exit 1
printf '%s\n' "$cli"
