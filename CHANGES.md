# Changes

2026-08-18 : Production enablement : Release, preprod, and alpha builds now pin the xcodebuild path so shipped bundles carry App Intents metadata; verify_update_flow.sh accepts the Contents/Frameworks layout; project.yml identity documented as a throwaway intermediate.
2026-08-03 01:30 : Feature : Added six Apple Shortcuts actions through App Intents and an opt-in Xcode application build path that emits discovery metadata.
2026-08-03 01:30 : Simplification : Preserved the existing MuesliNativeApp module and tests, reducing the pull request from 249 changed files to 22 functional files before documentation.
2026-08-08 02:20 : Review fixes : Migrated the standalone Shortcuts database before reads, gated Shortcut audio starts behind onboarding and permissions, and aligned Xcode bundle handling with existing architecture thinning.
