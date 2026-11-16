#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/muesli_build_badge.sh"

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

expect_label() {
  local app_name="$1" expected="$2" actual
  actual="$(muesli_build_badge_label "$app_name")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $app_name -> '$actual', expected '$expected'" >&2
    exit 1
  fi
}

expect_label Muesli ""
expect_label muesli ""
expect_label MuesliDev "DEV"
expect_label MuesliDevA "DEV A"
expect_label MuesliDevC "DEV C"
expect_label MuesliCanary "CANARY"
expect_label MuesliPreprod "PREPROD"
expect_label OtherApp ""

expect_short() {
  local label="$1" expected="$2" actual
  actual="$(muesli_build_badge_short "$label")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: short '$label' -> '$actual', expected '$expected'" >&2
    exit 1
  fi
}

expect_short "" ""
expect_short "DEV" "D"
expect_short "DEV A" "DA"
expect_short "DEV C" "DC"
expect_short "PREPROD" "PP"
expect_short "CANARY" "C"

# The badged icon keeps every size of the source icon and differs from it.
muesli_badge_icns "$ROOT/assets/muesli.icns" "DEV A" "$TEST_ROOT/badged.icns"
iconutil -c iconset "$ROOT/assets/muesli.icns" -o "$TEST_ROOT/source.iconset"
iconutil -c iconset "$TEST_ROOT/badged.icns" -o "$TEST_ROOT/badged.iconset"
if [[ "$(ls "$TEST_ROOT/source.iconset")" != "$(ls "$TEST_ROOT/badged.iconset")" ]]; then
  echo "FAIL: badged icon sizes differ from the source icon" >&2
  exit 1
fi
if cmp -s "$ROOT/assets/muesli.icns" "$TEST_ROOT/badged.icns"; then
  echo "FAIL: badged icon is identical to the source icon" >&2
  exit 1
fi

echo "build badge tests passed"
