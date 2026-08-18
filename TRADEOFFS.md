# Tradeoffs

## Apple Shortcuts integration

App Intents discovery metadata (`Contents/Resources/Metadata.appintents`) is emitted only for a genuine Xcode Application target, while Muesli's distribution pipeline historically built a SwiftPM executable and assembled the app bundle manually. The implementation therefore keeps the established app code in the existing `MuesliNativeApp` module, adds a minimal `MuesliNativeAppShell` containing the entry point and intents, and generates the Xcode project from `native/MuesliXcode/project.yml` (xcodegen) at build time.

All shipped builds — `scripts/release.sh`, `scripts/release-preprod.sh`, `scripts/release-alpha.sh` — pin `MUESLI_USE_XCODE_BUILD=1`, and `scripts/dev-test.sh` defaults to it, so every installed Muesli bundle carries Shortcuts/Siri discovery metadata. The xcodebuild product is a throwaway intermediate: `scripts/build_native_app.sh` restages its binary, frameworks, resource bundles, and `Metadata.appintents` into the canonical bundle it assembles and signs itself, so bundle identity, Info.plist, entitlements, provisioning-profile binding, and notarization stay in one place.

Costs accepted:

- Release and dev builds require `xcodegen` (and full Xcode, not just CLT) on the build host. CI is unaffected: `build_release` compiles the package directly with `swift build`.
- Frameworks land in `Contents/Frameworks` instead of the SwiftPM-style loose `Contents/MacOS` layout; signing, packaging, and `verify_update_flow.sh` accept both locations.
- `MUESLI_USE_XCODE_BUILD=0` remains as an emergency escape hatch for a SwiftPM-only build, at the cost of shipping without Shortcuts metadata. The release scripts must be edited deliberately to use it.
