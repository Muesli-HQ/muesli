#!/usr/bin/env bash
# Builds other than the release app (MuesliDev, lanes A-C, MuesliCanary,
# MuesliPreprod) get a short label baked into their icon and Info.plist
# (MuesliBuildBadge), so they can't be mistaken for the installed muesli in the
# Dock, Finder, notifications or System Settings. The app also shows the label
# in its menu bar item and sidebar.
#
# MUESLI_BUILD_BADGE overrides the label; set it empty to build without one.

# Prints the label for an app name, or nothing for the release app.
muesli_build_badge_label() {
  local app_name="$1"
  local channel="${app_name#[Mm]uesli}"
  if [[ "$channel" == "$app_name" || -z "$channel" ]]; then
    return 0
  fi
  if [[ "$channel" =~ ^Dev([A-Z])$ ]]; then
    printf 'DEV %s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$channel" | tr '[:lower:]' '[:upper:]'
  fi
}

# Writes a copy of the source .icns with the label drawn on every size.
muesli_badge_icns() {
  local source_icns="$1" label="$2" dest_icns="$3"
  local script_dir work
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  work="$(mktemp -d)"
  iconutil -c iconset "$source_icns" -o "$work/icon.iconset"
  swift "$script_dir/badge_app_icon.swift" "$work/icon.iconset" "$label"
  iconutil -c icns "$work/icon.iconset" -o "$dest_icns"
  rm -rf "$work"
}
