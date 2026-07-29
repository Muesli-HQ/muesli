#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$repo_root/native/MuesliNative/Tests/MuesliTests"
baseline="$repo_root/scripts/ci_unsharded_test_suites.txt"
runner="$repo_root/scripts/run_ci_test_shard.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export LC_ALL=C

perl -ne '
  if (/^\s*\@Suite(?:\s|\()/) {
    $awaiting_suite_type = 1;
    next;
  }
  if ($awaiting_suite_type &&
      /^\s*(?:(?:private|internal|package|public|open|final)\s+)*(?:class|struct|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*)/) {
    print "$1\n";
    $awaiting_suite_type = 0;
  }
' "$test_root"/*.swift \
  | sort -u > "$tmp_dir/discovered"

for shard in core dictation-transcription meetings; do
  bash "$runner" --list-filters "$shard"
done | sort -u > "$tmp_dir/assigned"

sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$baseline" \
  | sort -u > "$tmp_dir/baseline"

comm -23 "$tmp_dir/assigned" "$tmp_dir/discovered" > "$tmp_dir/unknown-filters"
comm -23 "$tmp_dir/discovered" "$tmp_dir/assigned" > "$tmp_dir/unassigned"
comm -23 "$tmp_dir/unassigned" "$tmp_dir/baseline" > "$tmp_dir/new-unassigned"
comm -23 "$tmp_dir/baseline" "$tmp_dir/unassigned" > "$tmp_dir/stale-baseline"

failed=false
if [[ -s "$tmp_dir/unknown-filters" ]]; then
  echo "CI shard filters that do not match a test suite:" >&2
  sed 's/^/  - /' "$tmp_dir/unknown-filters" >&2
  failed=true
fi
if [[ -s "$tmp_dir/new-unassigned" ]]; then
  echo "New test suites missing from every required CI shard:" >&2
  sed 's/^/  - /' "$tmp_dir/new-unassigned" >&2
  echo "Assign each suite in scripts/run_ci_test_shard.sh." >&2
  failed=true
fi
if [[ -s "$tmp_dir/stale-baseline" ]]; then
  echo "Stale legacy-unsharded entries:" >&2
  sed 's/^/  - /' "$tmp_dir/stale-baseline" >&2
  echo "Remove entries that were deleted or assigned to a shard." >&2
  failed=true
fi

if [[ "$failed" == true ]]; then
  exit 1
fi

echo "CI test shard assignments verified ($(wc -l < "$tmp_dir/assigned" | tr -d ' ') assigned, $(wc -l < "$tmp_dir/baseline" | tr -d ' ') legacy-unsharded)."
