import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Build badge")
struct BuildBadgeTests {
    @Test("test builds carry no badge, like the release app")
    func noBadgeWithoutInfoPlistKey() {
        // The label comes only from the build script's MuesliBuildBadge key
        // (covered by scripts/test_build_badge.sh); the test bundle has none.
        #expect(AppIdentity.buildBadge == nil)
    }

    @Test("menu bar title leads with the short build label")
    func menuBarBadge() {
        #expect(AppIdentity.buildBadgeShort == nil)

        let title = MenuBarIconRenderer.statusTitle(hotkey: .default, badge: "DA")
        #expect(title.string.hasPrefix("\u{2009}DA\u{2009}"))
        let font = title.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 10)

        let release = MenuBarIconRenderer.statusTitle(hotkey: .default, showsHotkey: false)
        #expect(release.string.isEmpty)
        let emptyBadge = MenuBarIconRenderer.statusTitle(hotkey: .default, showsHotkey: false, badge: "")
        #expect(emptyBadge.string.isEmpty)
    }
}
