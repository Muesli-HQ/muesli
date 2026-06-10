#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCALVQE_REPO="${LOCALVQE_REPO:-/tmp/LocalVQE}"
LOCALVQE_REF="${LOCALVQE_REF:-134aa7fd73d6a61dcab24c4f0c70bc49a38c0494}"
BUILD_DIR="${LOCALVQE_BUILD_DIR:-$LOCALVQE_REPO/ggml/build-muesli}"
OUT_DIR="${MUESLI_LOCALVQE_LIB_DIR:-$ROOT/native/MuesliNative/LocalVQE/lib}"

if [[ ! -d "$LOCALVQE_REPO/.git" ]]; then
  git clone https://github.com/localai-org/LocalVQE.git "$LOCALVQE_REPO"
fi
git -C "$LOCALVQE_REPO" remote set-url origin https://github.com/localai-org/LocalVQE.git
git -C "$LOCALVQE_REPO" fetch --depth 1 origin "$LOCALVQE_REF"
git -C "$LOCALVQE_REPO" checkout --detach FETCH_HEAD

git -C "$LOCALVQE_REPO" submodule update --init --depth 1 ggml/vendor/ggml

cmake -S "$LOCALVQE_REPO/ggml" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLOCALVQE_BUILD_SHARED=ON \
  -DLOCALVQE_VULKAN=OFF \
  -DLOCALVQE_CUDA=OFF \
  -DGGML_METAL=OFF

cmake --build "$BUILD_DIR" --target localvqe_shared -j"$(sysctl -n hw.ncpu)"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/liblocalvqe*.dylib "$OUT_DIR"/libggml*.dylib "$OUT_DIR"/libggml*.so
find "$BUILD_DIR" -maxdepth 4 \( -name "liblocalvqe*.dylib" -o -name "libggml*.dylib" -o -name "libggml*.so" \) -type f | while read -r dylib; do
  cp "$dylib" "$OUT_DIR/$(basename "$dylib")"
done

if [[ -f "$OUT_DIR/liblocalvqe.0.1.0.dylib" && ! -f "$OUT_DIR/liblocalvqe.dylib" ]]; then
  ln -s "liblocalvqe.0.1.0.dylib" "$OUT_DIR/liblocalvqe.dylib"
fi
if [[ -f "$OUT_DIR/liblocalvqe.0.1.0.dylib" && ! -f "$OUT_DIR/liblocalvqe.0.dylib" ]]; then
  ln -s "liblocalvqe.0.1.0.dylib" "$OUT_DIR/liblocalvqe.0.dylib"
fi
if [[ -f "$OUT_DIR/libggml.0.9.8.dylib" && ! -f "$OUT_DIR/libggml.0.dylib" ]]; then
  ln -s "libggml.0.9.8.dylib" "$OUT_DIR/libggml.0.dylib"
fi
if [[ -f "$OUT_DIR/libggml.0.9.8.dylib" && ! -f "$OUT_DIR/libggml.dylib" ]]; then
  ln -s "libggml.0.9.8.dylib" "$OUT_DIR/libggml.dylib"
fi
if [[ -f "$OUT_DIR/libggml-base.0.9.8.dylib" && ! -f "$OUT_DIR/libggml-base.0.dylib" ]]; then
  ln -s "libggml-base.0.9.8.dylib" "$OUT_DIR/libggml-base.0.dylib"
fi
if [[ -f "$OUT_DIR/libggml-base.0.9.8.dylib" && ! -f "$OUT_DIR/libggml-base.dylib" ]]; then
  ln -s "libggml-base.0.9.8.dylib" "$OUT_DIR/libggml-base.dylib"
fi

for dylib in "$OUT_DIR"/liblocalvqe*.dylib "$OUT_DIR"/libggml*.dylib; do
  [[ -f "$dylib" ]] || continue
  if otool -l "$dylib" | grep -Fq "$BUILD_DIR/bin"; then
    install_name_tool -delete_rpath "$BUILD_DIR/bin" "$dylib" 2>/dev/null || true
  fi
  if ! otool -l "$dylib" | grep -Fq "@loader_path"; then
    install_name_tool -add_rpath "@loader_path" "$dylib" 2>/dev/null || true
  fi
done

echo "LocalVQE dylibs copied to $OUT_DIR"
