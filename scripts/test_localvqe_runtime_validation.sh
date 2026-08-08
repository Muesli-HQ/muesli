#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/localvqe_runtime.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
RUNTIME_DIR="$TEST_ROOT/runtime"
FAKE_BIN="$TEST_ROOT/bin"
NO_OTOOL_BIN="$TEST_ROOT/no-otool-bin"
mkdir -p "$RUNTIME_DIR" "$FAKE_BIN" "$NO_OTOOL_BIN"

cat > "$FAKE_BIN/otool" <<'FAKE_OTOOL'
#!/usr/bin/env bash
set -euo pipefail

[[ "${1:-}" == "-L" && -n "${2:-}" ]] || exit 2
library="$2"
name="$(basename "$library")"
if [[ "$name" == "${FAKE_OTOOL_FAIL_BASENAME:-}" ]]; then
  exit 1
fi
if [[ "$name" == "${FAKE_OTOOL_EMPTY_BASENAME:-}" ]]; then
  exit 0
fi

printf '%s:\n' "$library"
case "$name" in
  liblocalvqe*)
    printf '\t@rpath/libggml.dylib (compatibility version 0.0.0, current version 0.0.0)\n'
    ;;
  libggml.dylib)
    printf '\t@rpath/libggml-base.dylib (compatibility version 0.0.0, current version 0.0.0)\n'
    ;;
esac
if [[ -n "${FAKE_OTOOL_MISSING_DEP:-}" ]]; then
  printf '\t@rpath/%s (compatibility version 0.0.0, current version 0.0.0)\n' "$FAKE_OTOOL_MISSING_DEP"
fi
printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)\n'
FAKE_OTOOL
chmod +x "$FAKE_BIN/otool"
export PATH="$FAKE_BIN:$PATH"
for tool in basename find grep sort; do
  ln -s "$(command -v "$tool")" "$NO_OTOOL_BIN/$tool"
done

touch \
  "$RUNTIME_DIR/liblocalvqe.dylib" \
  "$RUNTIME_DIR/libggml.dylib" \
  "$RUNTIME_DIR/libggml-base.dylib" \
  "$RUNTIME_DIR/libggml-cpu-apple_m4.so"

expect_complete() {
  local name="$1"
  if ! muesli_localvqe_runtime_is_complete "$RUNTIME_DIR"; then
    echo "FAIL: $name should accept the runtime" >&2
    exit 1
  fi
}

expect_incomplete() {
  local name="$1"
  if muesli_localvqe_runtime_is_complete "$RUNTIME_DIR" >/dev/null 2>&1; then
    echo "FAIL: $name should reject the runtime" >&2
    exit 1
  fi
}

expect_complete "complete dependency closure"

rm "$RUNTIME_DIR/libggml.dylib"
PATH="$NO_OTOOL_BIN" expect_incomplete "missing libggml umbrella without otool"
touch "$RUNTIME_DIR/libggml.dylib"

export FAKE_OTOOL_FAIL_BASENAME="libggml.dylib"
expect_incomplete "unreadable dylib"
unset FAKE_OTOOL_FAIL_BASENAME

export FAKE_OTOOL_EMPTY_BASENAME="libggml.dylib"
expect_incomplete "empty otool metadata"
unset FAKE_OTOOL_EMPTY_BASENAME

export FAKE_OTOOL_FAIL_BASENAME="libggml-cpu-apple_m4.so"
expect_incomplete "unreadable backend module"
unset FAKE_OTOOL_FAIL_BASENAME

rm "$RUNTIME_DIR/libggml-base.dylib"
expect_incomplete "missing required libggml-base"
touch "$RUNTIME_DIR/libggml-base.dylib"

export FAKE_OTOOL_MISSING_DEP="libggml-missing.dylib"
expect_incomplete "missing inspected dependency"
unset FAKE_OTOOL_MISSING_DEP

echo "LocalVQE runtime validation tests passed."
