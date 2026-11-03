#!/usr/bin/env bash
# Sign docs/models/cleanup-models.json with the Sparkle EdDSA key (the same key
# that signs app updates) and verify the result against the app's public key.
# The app ignores the catalog unless cleanup-models.json.sig verifies.
#
# Usage: scripts/sign_cleanup_model_catalog.sh
#   MUESLI_SPARKLE_SIGN_UPDATE  path to Sparkle's sign_update (auto-detected from SwiftPM artifacts)
#   MUESLI_SPARKLE_EDKEY        public key to verify against (defaults to the production key)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG="$ROOT/docs/models/cleanup-models.json"
SIGNATURE="$CATALOG.sig"
PUBLIC_KEY="${MUESLI_SPARKLE_EDKEY:-ok9CQBJ3f0MJ2GXuGBubc6VyeWyb5exmqP2b9DceqH4=}"

python3 -I "$ROOT/scripts/cleanup_model_catalog.py" check

SIGN_UPDATE="${MUESLI_SPARKLE_SIGN_UPDATE:-}"
if [[ -z "$SIGN_UPDATE" ]]; then
  for candidate in \
    "$ROOT/native/MuesliNative/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
    /Volumes/MuesliBuildCache/muesli-spm/*/artifacts/sparkle/Sparkle/bin/sign_update \
    "$HOME"/Library/Caches/muesli-spm/*/artifacts/sparkle/Sparkle/bin/sign_update \
    "$HOME"/Library/Caches/muesli-spm/worktrees/*/*/artifacts/sparkle/Sparkle/bin/sign_update; do
    if [[ -x "$candidate" ]]; then SIGN_UPDATE="$candidate"; break; fi
  done
fi
if [[ -z "$SIGN_UPDATE" || ! -x "$SIGN_UPDATE" ]]; then
  echo "ERROR: Sparkle sign_update not found. Build the app once or set MUESLI_SPARKLE_SIGN_UPDATE." >&2
  exit 1
fi

# -p prints only the base64 Ed25519 signature of the file's exact bytes.
"$SIGN_UPDATE" -p --disable-signing-warning "$CATALOG" | tr -d '[:space:]' > "$SIGNATURE"
printf '\n' >> "$SIGNATURE"

VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
cat > "$VERIFY_DIR/verify.swift" <<'SWIFT'
import CryptoKit
import Foundation
let args = CommandLine.arguments
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let signature = Data(base64Encoded: try String(contentsOfFile: args[2], encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines))!
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[3])!)
guard key.isValidSignature(signature, for: data) else {
    FileHandle.standardError.write("ERROR: signature does not verify against the app public key\n".data(using: .utf8)!)
    exit(1)
}
print("Signature verifies against \(args[3])")
SWIFT
xcrun swift "$VERIFY_DIR/verify.swift" "$CATALOG" "$SIGNATURE" "$PUBLIC_KEY"
echo "Signed ${CATALOG#$ROOT/}. Commit both files; GitHub Pages publishes them on merge to main."
