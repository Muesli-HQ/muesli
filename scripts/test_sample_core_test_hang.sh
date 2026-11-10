#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/pgrep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$MUESLI_TEST_PID"
EOF
cat > "$tmp_dir/sample" <<'EOF'
#!/usr/bin/env bash
printf 'sampled %s for %s seconds\n' "$1" "$2"
EOF
chmod +x "$tmp_dir/pgrep" "$tmp_dir/sample"
export PATH="$tmp_dir:$PATH" MUESLI_CORE_SAMPLE_DELAY_SECONDS=0

export MUESLI_TEST_PID="$$"
output="$(bash "$repo_root/scripts/sample_core_test_hang.sh")"
[[ "$output" == *"sampled $$ for 5 seconds"* ]]

export MUESLI_TEST_PID=99999999
output="$(bash "$repo_root/scripts/sample_core_test_hang.sh")"
[[ "$output" != *"sampled"* ]]
echo 'Core test hang sampling verified.'
