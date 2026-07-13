# Tradeoffs

## Apple Shortcuts integration

App Intents discovery metadata is emitted only for a genuine Xcode Application target, while Muesli's existing distribution pipeline builds a SwiftPM executable and assembles the app bundle manually. The implementation therefore keeps the established app code in the existing `MuesliNativeApp` module, adds a minimal `MuesliNativeAppShell` containing the entry point and intents, and generates a small Xcode project from `native/MuesliXcode/project.yml` for local Shortcuts-enabled builds.

The production, preproduction, and alpha release scripts explicitly keep the legacy SwiftPM build path until the Xcode path is separately validated for signed and notarized releases. This preserves release safety at the cost of requiring `xcodegen` for local Shortcuts testing and maintaining a thin Xcode-project specification alongside `Package.swift`.
