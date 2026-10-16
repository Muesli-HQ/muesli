#!/usr/bin/env bash
set -euo pipefail

# Exercises scripts/dev-sign-cloud.sh without signing anything. `security`, `codesign` and
# `pkill` are replaced by stubs that record what the script asked of them, and the "provisioning
# profile" is a plain plist the `security` stub passes through. Needs macOS (PlistBuddy, plutil).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/dev-sign-cloud.sh"
PLISTBUDDY=/usr/libexec/PlistBuddy

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
FAKE_BIN="$TEST_ROOT/bin"
OUT="$TEST_ROOT/out"
APP="$TEST_ROOT/MuesliDevT.app"
mkdir -p "$FAKE_BIN" "$OUT" "$APP/Contents"

BUNDLE_ID="com.example.muesli.dev"
TEAM="TEAM123456"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$APP/Contents/Info.plist"
"$PLISTBUDDY" -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$APP/Contents/Info.plist"

cat > "$FAKE_BIN/security" <<'STUB'
#!/usr/bin/env bash
# security cms -D -i <profile>: the test profile is already a plain plist.
[[ "$1 $2" == "cms -D" && "$3" == "-i" ]] || exit 2
cat "$4"
STUB
cat > "$FAKE_BIN/codesign" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_OUT/codesign.log"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == "--entitlements" && "${args[$((i + 1))]}" != "-" ]] \
    && cp "${args[$((i + 1))]}" "$FAKE_OUT/signed-entitlements.plist"
done
if [[ "$1" == "-d" ]]; then
  cat "$FAKE_OUT/signed-entitlements.plist"
fi
exit 0
STUB
cat > "$FAKE_BIN/pkill" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_OUT/pkill.log"
exit 1
STUB
chmod +x "$FAKE_BIN/security" "$FAKE_BIN/codesign" "$FAKE_BIN/pkill"
export FAKE_OUT="$OUT"

fail() {
  echo "FAIL: $*" >&2
  [[ -f "$OUT/stderr" ]] && sed 's/^/  stderr: /' "$OUT/stderr" >&2
  exit 1
}

# make_profile <path> <container...>: a profile for $BUNDLE_ID. Optional knobs via env:
# PROFILE_ENVIRONMENT (default "Development Production" as an array, "none" omits the key,
# "string:X" stores a plain string), PROFILE_APS (default development, "none" omits).
make_profile() {
  local path="$1"
  shift
  local key="Entitlements" env_spec="${PROFILE_ENVIRONMENT-Development Production}" aps="${PROFILE_APS-development}"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$path"
  "$PLISTBUDDY" -c "Add :$key dict" "$path"
  "$PLISTBUDDY" -c "Add :$key:com.apple.application-identifier string $TEAM.$BUNDLE_ID" "$path"
  if [[ "${PROFILE_TEAM-$TEAM}" != "none" ]]; then
    "$PLISTBUDDY" -c "Add :$key:com.apple.developer.team-identifier string ${PROFILE_TEAM-$TEAM}" "$path"
  fi
  "$PLISTBUDDY" -c "Add :$key:com.apple.developer.icloud-container-identifiers array" "$path"
  local i=0 container
  for container in "$@"; do
    "$PLISTBUDDY" -c "Add :$key:com.apple.developer.icloud-container-identifiers:$i string $container" "$path"
    i=$((i + 1))
  done
  case "$env_spec" in
    none) ;;
    string:*)
      "$PLISTBUDDY" -c "Add :$key:com.apple.developer.icloud-container-environment string ${env_spec#string:}" "$path"
      ;;
    *)
      "$PLISTBUDDY" -c "Add :$key:com.apple.developer.icloud-container-environment array" "$path"
      i=0
      for value in $env_spec; do
        "$PLISTBUDDY" -c "Add :$key:com.apple.developer.icloud-container-environment:$i string $value" "$path"
        i=$((i + 1))
      done
      ;;
  esac
  if [[ "$aps" != "none" ]]; then
    "$PLISTBUDDY" -c "Add :$key:com.apple.developer.aps-environment string $aps" "$path"
  fi
}

# run_sign <base-entitlements> <profile> <container> <environment>: sets RC.
run_sign() {
  rm -f "$OUT/codesign.log" "$OUT/pkill.log" "$OUT/signed-entitlements.plist" "$OUT/stdout" "$OUT/stderr"
  set +e
  PATH="$FAKE_BIN:$PATH" \
    MUESLI_SIGN_IDENTITY="Apple Development: Test (TEAM123456)" \
    MUESLI_PROVISIONING_PROFILE="$2" \
    MUESLI_ICLOUD_CONTAINER_ID="$3" \
    MUESLI_ICLOUD_CONTAINER_ENVIRONMENT="$4" \
    MUESLI_ENTITLEMENTS="$1" \
    bash "$SCRIPT" "$APP" > "$OUT/stdout" 2> "$OUT/stderr"
  RC=$?
  set -e
}

# array_values <plist> <key>: one element per line.
array_values() {
  local i=0 value
  while value="$("$PLISTBUDDY" -c "Print :$2:$i" "$1" 2>/dev/null)"; do
    printf '%s\n' "$value"
    i=$((i + 1))
  done
}

expect_signed() {
  local name="$1"
  [[ "$RC" -eq 0 ]] || fail "$name: expected the script to succeed, exit $RC"
  [[ -f "$OUT/signed-entitlements.plist" ]] || fail "$name: nothing was signed with entitlements"
}

expect_refused() {
  local name="$1" message="$2"
  [[ "$RC" -ne 0 ]] || fail "$name: expected the script to refuse"
  grep -Fq -- "$message" "$OUT/stderr" || fail "$name: expected stderr to contain '$message'"
  [[ ! -f "$OUT/codesign.log" ]] || fail "$name: codesign ran although the script refused"
}

signed() { "$PLISTBUDDY" -c "Print :$1" "$OUT/signed-entitlements.plist" 2>/dev/null || true; }

MINE="iCloud.com.example.muesli"
PROFILE="$TEST_ROOT/ok.plist"

# 1. The local-only base entitlements get the container, service, environment and identity added.
make_profile "$PROFILE" "$MINE"
run_sign "$ROOT/scripts/MuesliLocalOnly.entitlements" "$PROFILE" "$MINE" Development
expect_signed "local-only base"
[[ "$(array_values "$OUT/signed-entitlements.plist" com.apple.developer.icloud-container-identifiers)" == "$MINE" ]] \
  || fail "local-only base: container list is not exactly $MINE"
[[ "$(array_values "$OUT/signed-entitlements.plist" com.apple.developer.icloud-services)" == "CloudKit" ]] \
  || fail "local-only base: services list is not exactly CloudKit"
[[ "$(signed com.apple.developer.icloud-container-environment)" == "Development" ]] || fail "local-only base: environment"
[[ "$(signed com.apple.application-identifier)" == "$TEAM.$BUNDLE_ID" ]] || fail "local-only base: application identifier"
[[ "$(signed com.apple.developer.team-identifier)" == "$TEAM" ]] || fail "local-only base: team identifier"
[[ "$(signed com.apple.developer.aps-environment)" == "development" ]] || fail "local-only base: aps environment"
echo "ok: local-only base entitlements are extended"

# 2. A base that already carries the iCloud keys (scripts/Muesli.entitlements) is overridden, not
#    appended to, and does not make PlistBuddy fail on duplicate keys.
run_sign "$ROOT/scripts/Muesli.entitlements" "$PROFILE" "$MINE" Development
expect_signed "cloud base"
[[ "$(array_values "$OUT/signed-entitlements.plist" com.apple.developer.icloud-container-identifiers)" == "$MINE" ]] \
  || fail "cloud base: container list is not exactly $MINE (upstream's container must be replaced)"
[[ "$(array_values "$OUT/signed-entitlements.plist" com.apple.developer.icloud-services)" == "CloudKit" ]] \
  || fail "cloud base: services list is not exactly CloudKit"
[[ "$(signed com.apple.security.device.audio-input)" == "true" ]] || fail "cloud base: unrelated entitlements must survive"
echo "ok: a base that already has iCloud keys is overridden"

# 3. The profile must list the container as a whole element, not as a substring of one.
make_profile "$PROFILE" "$MINE.dev"
run_sign "$ROOT/scripts/MuesliLocalOnly.entitlements" "$PROFILE" "$MINE" Development
expect_refused "container prefix of a listed one" "profile does not list container $MINE."
make_profile "$PROFILE" "$MINE"
run_sign "$ROOT/scripts/MuesliLocalOnly.entitlements" "$PROFILE" "$MINE.dev" Development
expect_refused "listed container prefix of the wanted one" "profile does not list container $MINE.dev."
make_profile "$PROFILE" "iCloud.com.other.app" "$MINE" "iCloud.com.third.app"
run_sign "$ROOT/scripts/MuesliLocalOnly.entitlements" "$PROFILE" "$MINE" Development
expect_signed "container among several"
echo "ok: container match is exact"

# 4. The CloudKit environment must be authorized by the profile (array or plain string).
PROFILE_ENVIRONMENT="Production" make_profile "$PROFILE" "$MINE"
run_sign "$ROOT/scripts/MuesliLocalOnly.entitlements" "$PROFILE" "$MINE" Development
expect_refused "production-only profile" "profile does not permit CloudKit environment Development."
PROFILE_ENVIRONMENT="Production" make_profile "$PROFILE" "$MINE"
run_sign "$ROOT/scripts/MuesliLocalOnly.entitlements" "$PROFILE" "$MINE" production
expect_signed "production-only profile, production requested"
[[ "$(signed com.apple.developer.icloud-container-environment)" == "Production" ]] || fail "environment is normalised to Production"
PROFILE_ENVIRONMENT="string:Development" make_profile "$PROFILE" "$MINE"
run_sign "$ROOT/scripts/MuesliLocalOnly.entitlements" "$PROFILE" "$MINE" Development
expect_signed "string environment"
PROFILE_ENVIRONMENT="none" make_profile "$PROFILE" "$MINE"
run_sign "$ROOT/scripts/MuesliLocalOnly.entitlements" "$PROFILE" "$MINE" Development
expect_refused "profile without an environment entitlement" "profile does not permit CloudKit environment Development."
echo "ok: the environment is checked against the profile"

# 5. A profile without APNs must not leave a stale aps entitlement from the base file.
PROFILE_APS="none" make_profile "$PROFILE" "$MINE"
base_with_aps="$TEST_ROOT/base-with-aps.plist"
cp "$ROOT/scripts/MuesliLocalOnly.entitlements" "$base_with_aps"
"$PLISTBUDDY" -c "Add :com.apple.developer.aps-environment string production" "$base_with_aps"
run_sign "$base_with_aps" "$PROFILE" "$MINE" Development
expect_signed "profile without aps"
[[ -z "$(signed com.apple.developer.aps-environment)" ]] || fail "aps entitlement must not be signed when the profile lacks it"
echo "ok: no aps entitlement without profile support"

# 6. A profile without a team identifier is refused instead of signing a blank one.
PROFILE_TEAM="none" make_profile "$PROFILE" "$MINE"
run_sign "$ROOT/scripts/MuesliLocalOnly.entitlements" "$PROFILE" "$MINE" Development
expect_refused "profile without a team identifier" "no team identifier"
echo "ok: missing team identifier is refused"

# 7. The running copy is stopped by an anchored, regex-escaped pattern so it cannot hit other apps.
make_profile "$PROFILE" "$MINE"
run_sign "$ROOT/scripts/MuesliLocalOnly.entitlements" "$PROFILE" "$MINE" Development
expect_signed "pkill pattern"
pattern="$(sed -n 's/^-f //p' "$OUT/pkill.log" | head -n 1)"
[[ "$pattern" == ^* ]] || fail "pkill pattern is not anchored: '$pattern'"
[[ "$pattern" == *'MuesliDevT\.app'* ]] || fail "pkill pattern does not escape the app name's dot: '$pattern'"
echo "ok: the process match is anchored and escaped"

echo "dev-sign-cloud.sh tests passed"
