#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="$ROOT/native/MuesliNative"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"

if [[ -z "${DEVELOPER_DIR}" ]]; then
  echo "error: no active Apple developer directory. Install Xcode 16+ first." >&2
  exit 1
fi

if [[ "${DEVELOPER_DIR}" == *"CommandLineTools"* ]]; then
  cat >&2 <<EOF
error: swift test requires the Swift Testing module, which is not included in
Command Line Tools alone.

Install Xcode 16+ from the App Store, then point xcode-select at it:

  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept

Then rerun:

  swift test --package-path native/MuesliNative
EOF
  exit 1
fi

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/muesli-testing-probe.XXXXXX")"
trap 'rm -rf "$probe_dir"' EXIT

cat > "$probe_dir/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TestingProbe",
    targets: [
        .testTarget(
            name: "TestingProbeTests",
            path: "Tests"
        ),
    ]
)
EOF

mkdir -p "$probe_dir/Tests"
cat > "$probe_dir/Tests/ProbeTests.swift" <<'EOF'
import Testing

@Test func probe() {
    #expect(true)
}
EOF

if ! (cd "$probe_dir" && swift test >/dev/null 2>&1); then
  cat >&2 <<EOF
error: the active Xcode toolchain at:
  ${DEVELOPER_DIR}
does not provide a working Swift Testing module.

Install Xcode 16 or newer, then run:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
EOF
  exit 1
fi

echo "Swift Testing toolchain OK (${DEVELOPER_DIR})"
