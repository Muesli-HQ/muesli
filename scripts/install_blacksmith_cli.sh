#!/usr/bin/env bash
# Pinned CLI for the Linux cache-maintenance job. Never run a mutable installer.
set -euo pipefail
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo 'Blacksmith cache maintenance requires Linux x86_64.' >&2
  exit 1
fi
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"
version=v0.5.3
checksum=089a301ea5cc93a7560c7f1106911547fdfd46fc5c0cef7079e2a62a22e971ce
install_dir="$(mktemp -d "${RUNNER_TEMP}/blacksmith-cli.XXXXXX")"
curl --fail --silent --show-error --location --retry 3 \
  "https://clireleases.blacksmith.sh/cli/${version}/linux/amd64/blacksmith" \
  --output "${install_dir}/blacksmith"
printf '%s  %s\n' "$checksum" "${install_dir}/blacksmith" | sha256sum --check --status
chmod 700 "${install_dir}/blacksmith"
printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
BLACKSMITH_DISABLE_AUTO_UPDATE=1 "${install_dir}/blacksmith" --version
