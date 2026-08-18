import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("WindowAppearance")
struct WindowAppearanceTests {

    @Test("dark mode maps to the dark AppKit appearance")
    func darkModeMapsToDarkAqua() {
        #expect(RecentHistoryWindowController.appearanceName(for: true) == .darkAqua)
    }

    @Test("light mode maps to the light AppKit appearance")
    func lightModeMapsToAqua() {
        #expect(RecentHistoryWindowController.appearanceName(for: false) == .aqua)
    }
}
