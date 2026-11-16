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

    @Test("menu bar icon is tinted only for builds with a badge")
    func menuBarIconTint() throws {
        let template = try #require(MenuBarIconRenderer.make(choice: "muesli"))
        #expect(template.isTemplate)
        #expect(MenuBarIconRenderer.tinted(template, with: nil) === template)
        let tinted = try #require(MenuBarIconRenderer.tinted(template, with: BuildBadge.nsColor))
        #expect(!tinted.isTemplate)
        #expect(tinted.size == template.size)
        #expect(tinted.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
    }
}
