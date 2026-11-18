#!/usr/bin/env bash
set -euo pipefail

# Repository-only runner. Keep the selected executable and its data together.
lane=""
if [[ "${1:-}" == --lane ]]; then
  if [[ ! "${2:-}" =~ ^[ABC]$ ]]; then
    echo "Expected --lane A, B, or C." >&2
    exit 2
  fi
  lane="$2"
  shift 2
fi
if [[ "${1:-}" != -- || $# -lt 2 ]]; then
  echo "Usage: $0 [--lane A|B|C] -- <CLI command> [arguments...]" >&2
  exit 2
fi
shift

# CLI flags override environment defaults, so a lane invocation must not accept
# an override that could redirect reads or writes to another app's data.
for arg in "$@"; do
  case "$arg" in
    --db-path|--db-path=*|--support-dir|--support-dir=*)
      echo "The development runner selects its own database and support directory." >&2
      exit 2
      ;;
  esac
done

support_dir="$HOME/Library/Application Support/MuesliDev$lane"
run_cli() {
  local cli="$1"
  shift
  [[ -x "$cli" ]] || { echo "Missing development CLI: $cli" >&2; exit 1; }
  exec env MUESLI_DB_PATH="$support_dir/muesli.db" MUESLI_SUPPORT_DIR="$support_dir" "$cli" "$@"
}

if [[ -n "$lane" ]]; then
  run_cli "/Applications/MuesliDev$lane.app/Contents/MacOS/muesli-cli" "$@"
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
      run_cli "$dir/$config/muesli-cli" "$@"
    fi
  done
done

run_cli /Applications/MuesliDev.app/Contents/MacOS/muesli-cli "$@"
