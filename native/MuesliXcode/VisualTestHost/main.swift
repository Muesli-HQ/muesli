import MuesliNativeApp

/// A deliberately separate application entry point for XCUITest visual runs.
///
/// Fixture mode is validated inside `MuesliAppEntry` before ordinary startup.
/// This shell contains no production-only identity, signing, or launch logic.
@main
@MainActor
enum MuesliVisualTestHostMain {
    static func main() {
        MuesliAppEntry.run()
    }
}
