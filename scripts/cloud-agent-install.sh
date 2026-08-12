#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required_commands=(bash git curl python3 perl diff)
missing=()
for cmd in "${required_commands[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

if ((${#missing[@]} > 0)); then
  echo "Missing required commands: ${missing[*]}" >&2
  exit 1
fi

chmod +x \
  "$ROOT/scripts/classify_changed_files.sh" \
  "$ROOT/scripts/test_classify_changed_files.sh" \
  "$ROOT/scripts/test_ci_test_shards.sh" \
  "$ROOT/scripts/run_ci_test_shard.sh" \
  "$ROOT/scripts/verify_update_flow.sh" \
  "$ROOT/scripts/cloud-agent-install.sh"

echo "Cloud Agent install complete (Linux CI tooling ready)."
