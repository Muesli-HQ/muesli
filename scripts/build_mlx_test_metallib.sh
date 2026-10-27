#!/usr/bin/env bash
# Compile only the pinned MLX package's prepared Metal sources for SwiftPM tests.
# The legacy SwiftPM engine copies shaders but does not compile them; Swift 6.3's
# preview engine cannot build this package's app/test target graph reliably.
set -euo pipefail
checkout="${1:?usage: build_mlx_test_metallib.sh <mlx-swift-checkout> <output.metallib>}"
output="${2:?missing output.metallib path}"
shaders="$checkout/Source/Cmlx/mlx-generated/metal"
[[ -d "$shaders" ]] || { echo "Missing pinned MLX shaders: $shaders" >&2; exit 1; }
mkdir -p "$(dirname "$output")"
work="$(mktemp -d "$(dirname "$output")/mlx-metal.XXXXXX")"
trap 'rm -rf "$work"' EXIT
objects=()
while IFS= read -r -d '' source; do
  object="$work/${#objects[@]}.air"
  # Match MLX's upstream Metal kernel flags; include its prepared header tree.
  xcrun -sdk macosx metal -c "$source" -I "$shaders" -fno-fast-math \
    -Wno-c++17-extensions -Wno-c++20-extensions -o "$object"
  objects+=("$object")
done < <(find "$shaders" -type f -name '*.metal' -print0)
[[ ${#objects[@]} -gt 0 ]] || { echo "No prepared MLX Metal sources" >&2; exit 1; }
xcrun -sdk macosx metallib "${objects[@]}" -o "$work/default.metallib"
mv "$work/default.metallib" "$output"
echo "Compiled ${#objects[@]} pinned MLX Metal sources: $output"
