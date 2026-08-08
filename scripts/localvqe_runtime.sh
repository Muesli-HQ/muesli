#!/usr/bin/env bash

# Shared LocalVQE runtime discovery and completeness validation.
# This file is sourced by packaging and smoke-test scripts.

[[ -n "${_MUESLI_LOCALVQE_RUNTIME_LOADED:-}" ]] && return 0
_MUESLI_LOCALVQE_RUNTIME_LOADED=1

muesli_collect_localvqe_runtime() {
  local dir="$1"
  local listing=""
  local -a found=()
  if [[ -d "$dir" ]]; then
    if ! listing="$(find "$dir" -maxdepth 1 \( -name "liblocalvqe*.dylib" -o -name "libggml*.dylib" -o -name "libggml*.so" \) \( -type f -o -type l \))"; then
      echo "Could not enumerate LocalVQE runtime in $dir" >&2
      return 1
    fi
    while IFS= read -r library; do
      [[ -n "$library" ]] || continue
      found+=("$library")
    done <<< "$listing"
  fi
  printf '%s\n' "${found[@]+"${found[@]}"}" | sort
}

muesli_localvqe_runtime_is_complete() {
  local dir="$1"
  local ggml_umbrella=""
  local primary=""
  local name
  local runtime_listing=""
  local -a runtime_files=()

  if ! runtime_listing="$(muesli_collect_localvqe_runtime "$dir")"; then
    return 1
  fi
  while IFS= read -r library; do
    [[ -n "$library" ]] || continue
    runtime_files+=("$library")
  done <<< "$runtime_listing"

  if [[ ${#runtime_files[@]} -eq 0 ]]; then
    echo "LocalVQE runtime files missing in $dir" >&2
    return 1
  fi

  for name in liblocalvqe.dylib liblocalvqe.0.1.0.dylib liblocalvqe.0.dylib liblocalvqe_shared.dylib; do
    if [[ -e "$dir/$name" ]]; then
      primary="$dir/$name"
      break
    fi
  done
  if [[ -z "$primary" ]]; then
    echo "LocalVQE primary library missing in $dir" >&2
    return 1
  fi

  for library in "${runtime_files[@]}"; do
    name="$(basename "$library")"
    case "$name" in
      libggml.dylib|libggml.[0-9]*.dylib)
        ggml_umbrella="$library"
        break
        ;;
    esac
  done
  if [[ -z "$ggml_umbrella" ]]; then
    echo "LocalVQE runtime incomplete: libggml umbrella dylib missing in $dir" >&2
    return 1
  fi

  # libggml-base is a transitive dependency of the libggml umbrella shared
  # library. Require it unconditionally so a one-level dependency walk of only
  # liblocalvqe cannot accept liblocalvqe+libggml without libggml-base.
  if ! find "$dir" -maxdepth 1 -name 'libggml-base*.dylib' \( -type f -o -type l \) 2>/dev/null | grep -q .; then
    echo "LocalVQE runtime incomplete: libggml-base*.dylib missing in $dir" >&2
    return 1
  fi

  if command -v otool >/dev/null 2>&1; then
    local library inspection line dependency base
    # Inspect every collected runtime library, including dynamically loaded
    # ggml backend modules. A library that otool cannot read must fail closed;
    # treating its dependencies as an empty list would permit a broken bundle.
    for library in "${runtime_files[@]}"; do
      if ! inspection="$(otool -L "$library" 2>/dev/null)"; then
        echo "LocalVQE runtime incomplete: otool could not inspect $(basename "$library")" >&2
        return 1
      fi
      if [[ -z "$inspection" ]]; then
        echo "LocalVQE runtime incomplete: otool returned no metadata for $(basename "$library")" >&2
        return 1
      fi

      while IFS= read -r line; do
        [[ "$line" == [[:space:]]* ]] || continue
        dependency="${line#"${line%%[![:space:]]*}"}"
        dependency="${dependency%% *}"
        [[ -n "$dependency" ]] || continue
        base="$(basename "$dependency")"
        case "$base" in
          liblocalvqe*|libggml*)
            if [[ ! -e "$dir/$base" ]]; then
              echo "LocalVQE runtime incomplete: $base missing (required by $(basename "$library"))" >&2
              return 1
            fi
            ;;
        esac
      done <<< "$inspection"
    done
  fi
  return 0
}
