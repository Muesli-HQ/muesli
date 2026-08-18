#!/usr/bin/env bash

# Keep the public GitHub transition behind both release-metadata gates. This is
# deliberately a small sourceable function so CI can prove a failed appcast
# validation never reaches publication without exercising signing/notarization.
muesli_require_release_publication_ready() {
  local metadata_validated="${1:-0}"
  local metadata_pr_url="${2:-}"

  if [[ "$metadata_validated" != "1" ]]; then
    echo "ERROR: Release metadata validation did not complete; keeping the GitHub Release as a draft." >&2
    return 1
  fi
  if [[ -z "$metadata_pr_url" ]]; then
    echo "ERROR: Release metadata PR was not created; keeping the GitHub Release as a draft." >&2
    return 1
  fi
}
