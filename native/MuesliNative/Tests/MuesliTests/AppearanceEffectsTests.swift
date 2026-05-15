import Testing
import AppKit
@testable import MuesliNativeApp

@Suite("SoundController")
@MainActor
struct SoundControllerTests {

    @Test("playDictationStart with enabled=false does not throw")
    func playStartDisabled() {
        // NSSound.play() is a no-op in the test runner (no audio device required)
        SoundController.playDictationStart(enabled: false)
    }

    @Test("playDictationInsert with enabled=false does not throw")
    func playInsertDisabled() {
        SoundController.playDictationInsert(enabled: false)
    }

    @Test("playDictationStart with enabled=true does not throw")
    func playStartEnabled() {
        SoundController.playDictationStart(enabled: true)
    }

    @Test("playDictationInsert with enabled=true does not throw")
    func playInsertEnabled() {
        SoundController.playDictationInsert(enabled: true)
    }
}

@Suite("MenuBarIconRenderer")
struct MenuBarIconRendererTests {

    @Test("make(choice:) returns a non-nil image for SF Symbol")
    func makeReturnsImage() {
        let image = MenuBarIconRenderer.make(choice: "mic.fill")
        #expect(image != nil)
    }

    @Test("make(choice:) returns a template image for menu bar adaptation")
    func makeIsTemplate() {
        let image = MenuBarIconRenderer.make(choice: "mic.fill")
        #expect(image?.isTemplate == true)
    }

    @Test("make(choice:) returns a non-zero size image")
    func makeHasSize() {
        let image = MenuBarIconRenderer.make(choice: "mic.fill")
        #expect((image?.size.width ?? 0) > 0)
        #expect((image?.size.height ?? 0) > 0)
    }

    @Test("custom logo only replaces the logo icon choice")
    func customLogoOnlyReplacesLogoChoice() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-menu-logo-\(UUID().uuidString).png")
        try writeTestImage(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let logo = MenuBarIconRenderer.make(choice: "muesli", customLogoPath: url.path)
        let symbol = MenuBarIconRenderer.make(choice: "mic.fill", customLogoPath: url.path)

        #expect(logo?.isTemplate == false)
        #expect(symbol?.isTemplate == true)
    }

    private func writeTestImage(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 18, height: 18).fill()
        image.unlockFocus()

        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

@Suite("AppBrandingAssets")
struct AppBrandingAssetsTests {

    @Test("accented default app icon renders from accent color")
    func accentedDefaultAppIconRenders() throws {
        let image = try #require(AppBrandingAssets.accentedDefaultAppIcon(
            accentHex: "fb6100",
            fallbackURL: nil
        ))
        #expect(image.isTemplate == false)
        #expect(image.size.width == 1024)
        #expect(image.size.height == 1024)
    }
}

@Suite("AppIdentity")
struct AppIdentityTests {

    @Test("custom display name does not change support directory identity")
    func customDisplayNameDoesNotChangeSupportDirectoryIdentity() {
        AppIdentity.configureDisplayNameOverride(nil)
        let originalSupportDirectoryName = AppIdentity.supportDirectoryName
        AppIdentity.configureDisplayNameOverride("Runpoint Partners")
        defer { AppIdentity.configureDisplayNameOverride(nil) }

        #expect(AppIdentity.displayName == "Runpoint Partners")
        #expect(AppIdentity.supportDirectoryName == originalSupportDirectoryName)
    }
}
