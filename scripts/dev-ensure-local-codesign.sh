#!/usr/bin/env bash
set -euo pipefail

# Creates a stable local code-signing identity for MuesliDev builds.
#
# macOS privacy permissions are tied to the app's code requirement. Unsigned or
# ad-hoc signed dev builds get a new code hash whenever the binary changes, so
# TCC may treat each rebuild like a different app. A persistent local certificate
# gives MuesliDev a stable identity across rebuilds on this Mac.

IDENTITY_NAME="${MUESLI_LOCAL_SIGN_IDENTITY:-Muesli Dev Local Code Signing}"
KEYCHAIN_PATH="${MUESLI_LOCAL_SIGN_KEYCHAIN:-$HOME/Library/Keychains/muesli-dev.keychain-db}"
KEYCHAIN_PASSWORD="${MUESLI_LOCAL_SIGN_KEYCHAIN_PASSWORD:-muesli-dev-local}"
CERT_DAYS="${MUESLI_LOCAL_SIGN_CERT_DAYS:-3650}"

identity_exists() {
  local probe
  probe="$(mktemp)"
  printf '#!/bin/sh\nexit 0\n' > "$probe"
  chmod +x "$probe"
  if codesign --force --keychain "$KEYCHAIN_PATH" --sign "$IDENTITY_NAME" "$probe" >/dev/null 2>&1; then
    rm -f "$probe"
    return 0
  fi
  rm -f "$probe"
  return 1
}

ensure_keychain_in_search_list() {
  local existing
  existing="$(security list-keychains -d user | tr -d '\"')"
  if ! printf '%s\n' "$existing" | grep -Fxq "$KEYCHAIN_PATH"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$KEYCHAIN_PATH" $existing
  fi
}

mkdir -p "$(dirname "$KEYCHAIN_PATH")"

if [[ ! -f "$KEYCHAIN_PATH" ]]; then
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
fi

security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >/dev/null
ensure_keychain_in_search_list

if ! identity_exists; then
  rm -f "$KEYCHAIN_PATH"
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
  security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH" >/dev/null
  ensure_keychain_in_search_list

  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  cat > "$tmpdir/openssl.cnf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[ req_distinguished_name ]
CN = $IDENTITY_NAME

[ v3_req ]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
EOF

  openssl genrsa -out "$tmpdir/key.pem" 2048 >/dev/null 2>&1
  openssl req \
    -new \
    -x509 \
    -days "$CERT_DAYS" \
    -config "$tmpdir/openssl.cnf" \
    -key "$tmpdir/key.pem" \
    -out "$tmpdir/cert.pem" >/dev/null 2>&1

  security import "$tmpdir/key.pem" \
    -t priv \
    -f openssl \
    -k "$KEYCHAIN_PATH" \
    -A \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

  security import "$tmpdir/cert.pem" \
    -t cert \
    -f openssl \
    -k "$KEYCHAIN_PATH" \
    -A \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null

  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
fi

if ! identity_exists; then
  echo "Failed to create local code-signing identity: $IDENTITY_NAME" >&2
  exit 1
fi

echo "$IDENTITY_NAME"
