#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d /tmp/muesli-shard-path.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/bin" "$tmp/native/MuesliNative" "$tmp/output"
cp "$repo/scripts/run_ci_test_shard.sh" "$tmp/scripts/"
cat > "$tmp/bin/swift" <<'MOCK'
#!/bin/bash
if [[ "$*" == *--show-bin-path* ]]; then echo "$PWD/output"; fi
if [[ "$1" == test ]]; then test -f "$MUESLI_MLX_EVAL_METALLIB"; fi
MOCK
cat > "$tmp/scripts/build_mlx_test_metallib.sh" <<'MOCK'
#!/bin/bash
set -eu
[[ "$1" == "$EXPECTED_CHECKOUT" ]]
touch "$2"
MOCK
chmod +x "$tmp/bin/swift"
cd "$tmp"
for mode in unset relative absolute; do
  case "$mode" in
    unset) unset MUESLI_SWIFTPM_SCRATCH_PATH; export EXPECTED_CHECKOUT="$tmp/native/MuesliNative/.build/checkouts/mlx-swift" ;;
    relative) export MUESLI_SWIFTPM_SCRATCH_PATH='cache with spaces'; export EXPECTED_CHECKOUT="$tmp/native/MuesliNative/cache with spaces/checkouts/mlx-swift" ;;
    absolute) export MUESLI_SWIFTPM_SCRATCH_PATH="$tmp/absolute cache"; export EXPECTED_CHECKOUT="$tmp/absolute cache/checkouts/mlx-swift" ;;
  esac
  PATH="$tmp/bin:$PATH" bash scripts/run_ci_test_shard.sh core >/dev/null
  echo "PASS: $mode scratch path"
done
