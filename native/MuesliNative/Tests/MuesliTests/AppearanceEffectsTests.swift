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

    @Test("Quill lifecycle sounds are distinct bundled assets")
    func quillLifecycleAssets() throws {
        let activationURL = try #require(
            SoundController.bundledLifecycleSoundURL(named: "quill-activate")
        )
        let releaseURL = try #require(
            SoundController.bundledLifecycleSoundURL(named: "quill-release")
        )
        let activationData = try Data(contentsOf: activationURL)
        let releaseData = try Data(contentsOf: releaseURL)

        #expect(!activationData.isEmpty)
        #expect(!releaseData.isEmpty)
        #expect(activationData != releaseData)
    }

    @Test("disabled Quill lifecycle sounds do not play")
    func quillLifecycleDisabled() {
        SoundController.playQuillStart(enabled: false)
        SoundController.playQuillRelease(enabled: false)
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

    @Test("official mark is a resolution-independent template")
    func officialMarkIsResolutionIndependent() {
        let image = MenuBarIconRenderer.make(choice: "muesli")
        #expect(image?.isTemplate == true)
        #expect(image?.size == NSSize(width: 18, height: 18))
        #expect(image?.representations.contains { $0 is NSCustomImageRep } == true)
    }

    @Test("official mark uses the canonical app artwork at source resolution")
    func officialMarkUsesCanonicalArtwork() {
        let sourceRect = MenuBarIconRenderer.canonicalMarkSourceRect
        let mask = MenuBarIconRenderer.canonicalMarkMask

        #expect(sourceRect == CGRect(x: 195, y: 256, width: 635, height: 513))
        #expect(MenuBarIconRenderer.canonicalMarkOpacityBoost == 1.08)
        #expect(mask?.width == 635)
        #expect(mask?.height == 513)
    }

    @Test("hotkey cues preserve modifier side and combinations")
    func hotkeyCueLabels() {
        #expect(MenuBarIconRenderer.hotkeyCueLabel(for: HotkeyConfig(keyCode: 61, label: "Right Option")) == "R⌥")
        #expect(MenuBarIconRenderer.hotkeyCueLabel(for: HotkeyConfig(keyCode: 59, label: "Left Ctrl")) == "L⌃")
        #expect(MenuBarIconRenderer.hotkeyCueLabel(for: .meetingRecordingDefault) == "⌘⇧R")
    }

    @Test("status shortcut cue is compact while detail keeps menu bar size")
    func statusShortcutCueTypography() {
        let title = MenuBarIconRenderer.statusTitle(hotkey: .default, detail: "Meeting in 5m")
        let cueFont = title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let detailIndex = (title.string as NSString).range(of: "Meeting").location
        let detailFont = title.attribute(.font, at: detailIndex, effectiveRange: nil) as? NSFont

        #expect(cueFont?.pointSize == 9)
        #expect((detailFont?.pointSize ?? 0) > (cueFont?.pointSize ?? 0))
    }

    @Test("status shortcut cue can be hidden independently of meeting detail")
    func statusShortcutCueCanBeHidden() {
        let withoutHotkey = MenuBarIconRenderer.statusTitle(
            hotkey: .default,
            showsHotkey: false,
            detail: "Meeting in 5m"
        )
        let withoutEither = MenuBarIconRenderer.statusTitle(
            hotkey: .default,
            showsHotkey: false
        )

        #expect(withoutHotkey.string == "Meeting in 5m")
        #expect(withoutEither.string.isEmpty)
    }
}
