#!/usr/bin/env bash
set -euo pipefail

# Local-only Production CloudKit smoke/soak harness for the maintainer's
# MuesliDev lane. This script is not bundled into Muesli.app.

APP_PATH="/Applications/MuesliDev.app"
SUPPORT_DIR="$HOME/Library/Application Support/MuesliDev"
DATABASE_PATH="$SUPPORT_DIR/muesli.db"
RESULTS_PATH="$SUPPORT_DIR/sync-soak-results.jsonl"
DIRECTION="both"
COUNT=1
INTERVAL_SECONDS=30
TIMEOUT_SECONDS=120
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Run a privacy-preserving Production CloudKit sync soak from MuesliDev.

Usage:
  ./scripts/dev-production-sync-soak.sh [options]

Options:
  --direction mac-to-ios|ios-to-mac|both
                                  Test the selected direction (default: both).
  --count N                       Mac probes to emit, from 1 to 20 (default: 1).
  --interval SECONDS              Delay between Mac probes (default: 30).
  --timeout SECONDS               Per-probe / iPhone wait timeout (default: 120).
  --check                         Validate the dev lane without writing records.
  --help                          Show this help.

The mac-to-ios leg inserts a timestamped synthetic dictation into MuesliDev and
waits until CKSyncEngine records a successful Production save. Confirm the
printed marker appears in the TestFlight app.

The ios-to-mac leg records an aggregate baseline and waits for any new iOS-origin
dictation. Create one TestFlight voice note after the prompt; its contents are
never printed or written to the soak results.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --direction)
      [[ $# -ge 2 ]] || fail "--direction requires a value."
      DIRECTION="$2"
      shift 2
      ;;
    --count)
      [[ $# -ge 2 ]] || fail "--count requires a value."
      COUNT="$2"
      shift 2
      ;;
    --interval)
      [[ $# -ge 2 ]] || fail "--interval requires a value."
      INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || fail "--timeout requires a value."
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument '$1'. Run with --help for usage."
      ;;
  esac
done

case "$DIRECTION" in
  mac-to-ios|ios-to-mac|both) ;;
  *) fail "unsupported direction '$DIRECTION'." ;;
esac
is_positive_integer "$COUNT" || fail "--count must be a positive integer."
(( COUNT <= 20 )) || fail "--count is capped at 20 to prevent accidental CloudKit spam."
is_positive_integer "$INTERVAL_SECONDS" || fail "--interval must be a positive integer."
is_positive_integer "$TIMEOUT_SECONDS" || fail "--timeout must be a positive integer."

[[ "$APP_PATH" == "/Applications/MuesliDev.app" ]] || fail "unexpected app path."
[[ "$SUPPORT_DIR" == "$HOME/Library/Application Support/MuesliDev" ]] || fail "unexpected support directory."
[[ -d "$APP_PATH" ]] || fail "MuesliDev is not installed at $APP_PATH."
[[ -f "$DATABASE_PATH" ]] || fail "MuesliDev database is missing at $DATABASE_PATH."
command -v sqlite3 >/dev/null || fail "sqlite3 is required."
command -v codesign >/dev/null || fail "codesign is required."

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
[[ "$BUNDLE_ID" == "com.muesli.dev" ]] || fail "refusing to run for bundle ID '$BUNDLE_ID'."

ENTITLEMENTS_PLIST="$(mktemp "${TMPDIR:-/tmp}/muesli-sync-soak-entitlements.XXXXXX")"
cleanup() {
  rm -f "$ENTITLEMENTS_PLIST"
}
trap cleanup EXIT
codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PLIST" 2>/dev/null \
  || fail "could not read MuesliDev entitlements."
ICLOUD_ENVIRONMENT="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$ENTITLEMENTS_PLIST" 2>/dev/null || true)"
[[ "$ICLOUD_ENVIRONMENT" == "Production" ]] \
  || fail "refusing to run without the exact Production CloudKit entitlement."

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  printf 'PASS preflight | bundle=%s | CloudKit=%s | data=MuesliDev\n' "$BUNDLE_ID" "$ICLOUD_ENVIRONMENT"
  exit 0
fi

mkdir -p "$SUPPORT_DIR"

json_result() {
  local status="$1"
  local direction="$2"
  local started_at="$3"
  local finished_at="$4"
  local latency_ms="$5"
  printf '{"status":"%s","direction":"%s","startedAt":"%s","finishedAt":"%s","latencyMs":%s}\n' \
    "$status" "$direction" "$started_at" "$finished_at" "$latency_ms" >> "$RESULTS_PATH"
}

reactivate_muesli_dev() {
  open -a "$APP_PATH" >/dev/null
}

wait_for_mac_probe_upload() {
  local row_id="$1"
  local started_epoch="$2"
  local deadline=$(( started_epoch + TIMEOUT_SECONDS ))
  while (( $(date +%s) <= deadline )); do
    local saved
    saved="$(sqlite3 -readonly "$DATABASE_PATH" "SELECT COUNT(*) FROM dictations WHERE id=$row_id AND sync_dirty=0 AND cloud_system_fields IS NOT NULL AND deleted_at IS NULL;")"
    if [[ "$saved" == "1" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

run_mac_to_ios() {
  local index
  for (( index=1; index<=COUNT; index++ )); do
    local started_epoch started_iso marker escaped_marker row_id finished_epoch finished_iso latency_ms
    started_epoch="$(date +%s)"
    started_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    marker="MUESLI_SYNC_TEST_MAC_${started_epoch}_${index}"
    escaped_marker="${marker//\'/\'\'}"

    sqlite3 "$DATABASE_PATH" "BEGIN IMMEDIATE; INSERT INTO dictations (timestamp, duration_seconds, raw_text, app_context, word_count, source, started_at, ended_at, updated_at, sync_dirty) VALUES ('$started_iso', 0, '$escaped_marker', 'muesli_sync_probe', 1, 'sync_probe', '$started_iso', '$started_iso', $started_epoch, 1); SELECT last_insert_rowid(); COMMIT;" > "${ENTITLEMENTS_PLIST}.row"
    row_id="$(sed -n '1p' "${ENTITLEMENTS_PLIST}.row")"
    rm -f "${ENTITLEMENTS_PLIST}.row"
    [[ "$row_id" =~ ^[0-9]+$ ]] || fail "failed to create the local synthetic probe."

    reactivate_muesli_dev
    if wait_for_mac_probe_upload "$row_id" "$started_epoch"; then
      finished_epoch="$(date +%s)"
      finished_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      latency_ms=$(( (finished_epoch - started_epoch) * 1000 ))
      json_result "pass" "mac-to-production" "$started_iso" "$finished_iso" "$latency_ms"
      printf 'PASS macOS -> Production | %s | %ss | marker=%s\n' "$finished_iso" "$(( latency_ms / 1000 ))" "$marker"
      printf '     Confirm this marker appears in the TestFlight app.\n'
    else
      finished_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      json_result "timeout" "mac-to-production" "$started_iso" "$finished_iso" "$(( TIMEOUT_SECONDS * 1000 ))"
      printf 'TIMEOUT macOS -> Production | %s | marker=%s\n' "$finished_iso" "$marker" >&2
      return 1
    fi

    if (( index < COUNT )); then
      sleep "$INTERVAL_SECONDS"
    fi
  done
}

run_ios_to_mac() {
  local baseline started_epoch started_iso deadline count finished_epoch finished_iso latency_ms
  baseline="$(sqlite3 -readonly "$DATABASE_PATH" "SELECT COALESCE(MAX(id), 0) FROM dictations WHERE lower(trim(COALESCE(source, '')))='ios';")"
  [[ "$baseline" =~ ^[0-9]+$ ]] || fail "could not establish the iOS-origin baseline."
  started_epoch="$(date +%s)"
  started_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  deadline=$(( started_epoch + TIMEOUT_SECONDS ))
  printf 'WAIT iOS -> macOS | create one new TestFlight voice note within %ss.\n' "$TIMEOUT_SECONDS"

  reactivate_muesli_dev
  while (( $(date +%s) <= deadline )); do
    count="$(sqlite3 -readonly "$DATABASE_PATH" "SELECT COUNT(*) FROM dictations WHERE id>$baseline AND lower(trim(COALESCE(source, '')))='ios' AND deleted_at IS NULL;")"
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
      finished_epoch="$(date +%s)"
      finished_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      latency_ms=$(( (finished_epoch - started_epoch) * 1000 ))
      json_result "pass" "ios-to-mac" "$started_iso" "$finished_iso" "$latency_ms"
      printf 'PASS iOS -> macOS | %s | %ss | received=%s\n' "$finished_iso" "$(( latency_ms / 1000 ))" "$count"
      return 0
    fi
    sleep 3
  done

  finished_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  json_result "timeout" "ios-to-mac" "$started_iso" "$finished_iso" "$(( TIMEOUT_SECONDS * 1000 ))"
  printf 'TIMEOUT iOS -> macOS | %s\n' "$finished_iso" >&2
  return 1
}

case "$DIRECTION" in
  mac-to-ios)
    run_mac_to_ios
    ;;
  ios-to-mac)
    run_ios_to_mac
    ;;
  both)
    run_mac_to_ios
    run_ios_to_mac
    ;;
esac

printf 'Results: %s\n' "$RESULTS_PATH"
