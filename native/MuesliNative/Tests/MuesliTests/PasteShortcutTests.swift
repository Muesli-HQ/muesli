import AppKit
import Carbon
import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("Paste shortcut", .serialized)
@MainActor
struct PasteShortcutTests {
    @Test("settings dropdowns keep the model width regardless of label or enabled state",
          arguments: ["Romanized", "Automatic", "Automatic (⌘V)", "Bodhan Flex INT8"], [true, false])
    func dropdownWidth(label: String, enabled: Bool) throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView:
            FixedWidthPopUp(selection: label, options: [label], onChange: { _ in })
                .frame(height: 24)
                .disabled(!enabled)
                .frame(width: 275)
        )
        host.frame = NSRect(x: 0, y: 0, width: 275, height: 24)
        host.layoutSubtreeIfNeeded()
        func popup(in view: NSView) -> NSPopUpButton? {
            if let button = view as? NSPopUpButton { return button }
            return view.subviews.lazy.compactMap { popup(in: $0) }.first
        }
        let button = try #require(popup(in: host))
        #expect(button.frame.width == 275)
        #expect(button.isEnabled == enabled)
        #expect(button.titleOfSelectedItem == label)
    }

    @Test("automatic resolves Command's mapping, not the unmodified/US key")
    func commandMapping() {
        for expectedKey in [UInt16(9), 47, 8] {
            let chord = PasteKeyboardLayout.commandChord(for: "v") { key, flags in
                #expect(flags == .maskCommand)
                return key == expectedKey ? "V" : "k"
            }
            #expect(chord?.keyCode == expectedKey)
            #expect(chord?.flags == .maskCommand)
        }
    }

    @Test("missing, dead-key, or multicharacter mappings never guess US V")
    func missingMapping() {
        for value: String? in [nil, "", "vv", "´", "\u{16}"] {
            #expect(PasteKeyboardLayout.commandChord(for: "v", translate: { _, _ in value }) == nil)
        }
    }

    @Test("system layouts resolve without changing the user's selected input source",
          arguments: ["com.apple.keylayout.US", "com.apple.keylayout.Dvorak", "com.apple.keylayout.DVORAK-QWERTYCMD", "com.apple.keylayout.Colemak"])
    func installedLayout(identifier: String) throws {
        _ = NSApplication.shared // TIS requires AppKit initialization in a CLI test host.
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        let sources = try #require(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])
        let source = try #require(sources.first, "macOS built-in layout \(identifier) must be available")
        let chord = try #require(PasteKeyboardLayout.commandChord(for: "v") {
            PasteKeyboardLayout.character(keyCode: $0, flags: $1, source: source)
        })
        #expect(chord.flags == .maskCommand)
        #expect(chord.keyCode == (identifier == "com.apple.keylayout.Dvorak" ? 47 : 9))
    }

    @Test("custom records arbitrary physical key and exact normalized modifiers")
    func customChord() throws {
        let chord = try #require(PasteKeyChord(keyCode: 47, modifiers: [.maskCommand, .maskShift]))
        #expect(PasteKeyboardLayout.resolve(.custom(chord)) == chord)
        let control = try #require(PasteKeyChord(keyCode: 9, modifiers: .maskControl))
        #expect(PasteKeyboardLayout.resolve(.custom(control))?.flags == .maskControl)
        #expect(PasteKeyChord(keyCode: 9, modifiers: []) == nil)
        #expect(PasteKeyChord(keyCode: 55, modifiers: .maskCommand) == nil)
        #expect(PasteKeyChord(keyCode: 128, modifiers: .maskCommand) == nil)
        #expect(PasteKeyChord(keyCode: 9, modifiers: [.maskCommand, .maskAlphaShift]) == nil)
    }

    @Test("config defaults and malformed/future values fail safely to automatic")
    func defaults() throws {
        let payloads = ["{}", #"{"paste_shortcut":null}"#, #"{"paste_shortcut":"future"}"#,
            #"{"paste_shortcut":{"mode":"future"}}"#,
            #"{"paste_shortcut":{"mode":"custom","chord":{"key_code":9,"modifiers":0}}}"#,
            #"{"paste_shortcut":{"mode":"custom","chord":{"key_code":65535,"modifiers":1048576}}}"#,
            #"{"paste_shortcut":{"mode":"custom"}}"#]
        for payload in payloads {
            #expect(try JSONDecoder().decode(AppConfig.self, from: Data(payload.utf8)).pasteShortcut == .automatic)
        }
    }

    @Test("config uses snake case and round-trips both modes")
    func roundTrip() throws {
        let chord = try #require(PasteKeyChord(keyCode: 47, modifiers: [.maskCommand, .maskShift]))
        for shortcut in [PasteShortcut.automatic, .custom(chord)] {
            var config = AppConfig()
            config.pasteShortcut = shortcut
            let data = try JSONEncoder().encode(config)
            #expect(try JSONDecoder().decode(AppConfig.self, from: data).pasteShortcut == shortcut)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(json["paste_shortcut"] != nil)
            #expect(json["pasteShortcut"] == nil)
        }
    }

    @Test("experimental PR206 settings migrate")
    func contributorMigration() throws {
        for (value, expected) in [("command_v", PasteShortcut.automatic),
            ("command_shift_v", .custom(PasteKeyChord(keyCode: 9, modifiers: [.maskCommand, .maskShift])!))] {
            let data = Data("{\"paste_shortcut\":\"\(value)\"}".utf8)
            #expect(try JSONDecoder().decode(AppConfig.self, from: data).pasteShortcut == expected)
        }
    }

    @Test("capture ignores repeats/plain keys and waits for all chord keys to be released")
    func capture() throws {
        var capture = PasteShortcutCaptureState()
        capture.keyDown(keyCode: 9, flags: .maskCommand, isRepeat: true)
        #expect(capture.pending == nil)
        capture.keyDown(keyCode: 9, flags: [], isRepeat: false)
        #expect(capture.pending == nil)
        capture.keyDown(keyCode: 47, flags: [.maskCommand, .maskAlphaShift, .maskSecondaryFn], isRepeat: false)
        #expect(capture.pending?.flags == .maskCommand)
        #expect(capture.completedChord(flags: []) == nil)
        capture.keyUp(keyCode: 9)
        #expect(capture.completedChord(flags: []) == nil)
        capture.keyUp(keyCode: 47)
        #expect(capture.completedChord(flags: .maskCommand) == nil)
        #expect(capture.completedChord(flags: .maskAlphaShift)?.keyCode == 47)
    }

    @Test("pause restores only previously running listeners and respects explicit stops")
    func suspension() {
        for wasRunning in [false, true] {
            var suspension = HotkeyCaptureSuspension()
            suspension.begin(wasRunning: wasRunning)
            suspension.begin(wasRunning: !wasRunning) // nested refresh cannot change ownership
            #expect(suspension.isSuspended)
            let resumed = suspension.end()
            #expect(resumed == wasRunning)
            #expect(!suspension.isSuspended)
            let resumedAgain = suspension.end()
            #expect(!resumedAgain)
            suspension.begin(wasRunning: wasRunning)
            suspension.stopped()
            let resumedAfterStop = suspension.end()
            #expect(!resumedAfterStop)
        }
    }

    @Test("recorder cancellation/teardown is idempotent and restores the pause")
    func recorderCancellation() throws {
        var handler: ((NSEvent) -> NSEvent?)?
        var removed = 0
        var released = 0
        var committed = 0
        let recorder = PasteShortcutRecorder(addMonitor: { handler = $0; return NSObject() }, removeMonitor: { _ in removed += 1 })
        recorder.start(acquire: { true }, release: { released += 1 }, conflicts: { _ in false }, commit: { _ in committed += 1 })
        #expect(recorder.isRecording)
        _ = handler?(try keyEvent(.keyDown, key: 53))
        #expect(!recorder.isRecording)
        recorder.cancel() // same path as onDisappear/app deactivation
        #expect(removed == 1)
        #expect(released == 1)
        #expect(committed == 0)
    }

    @Test("recorder rejects busy state, installation failure, and conflicting chords")
    func recorderFailures() throws {
        var released = 0
        var installed = false
        let failed = PasteShortcutRecorder(addMonitor: { _ in installed = true; return nil })
        failed.start(acquire: { false }, release: { released += 1 }, conflicts: { _ in false }, commit: { _ in Issue.record("unexpected commit") })
        #expect(!installed)
        #expect(released == 0)
        failed.start(acquire: { true }, release: { released += 1 }, conflicts: { _ in false }, commit: { _ in Issue.record("unexpected commit") })
        #expect(!failed.isRecording)
        #expect(released == 1)

        var handler: ((NSEvent) -> NSEvent?)?
        let conflicting = PasteShortcutRecorder(addMonitor: { handler = $0; return NSObject() }, removeMonitor: { _ in })
        conflicting.start(acquire: { true }, release: { released += 1 }, conflicts: { _ in true }, commit: { _ in Issue.record("unexpected commit") })
        _ = handler?(try keyEvent(.keyDown, key: 9, flags: .command))
        _ = handler?(try keyEvent(.keyUp, key: 9))
        #expect(!conflicting.isRecording)
        #expect(conflicting.message?.contains("another Muesli feature") == true)
        #expect(released == 2)
    }

    @Test("recorder resumes listeners before saving exactly one custom chord")
    func recorderCommit() throws {
        var handler: ((NSEvent) -> NSEvent?)?
        var events: [String] = []
        var saved: PasteKeyChord?
        let recorder = PasteShortcutRecorder(addMonitor: { handler = $0; return NSObject() }, removeMonitor: { _ in events.append("removed") })
        recorder.start(acquire: { true }, release: { events.append("resumed") }, conflicts: { _ in false }, commit: { saved = $0; events.append("saved") })
        _ = handler?(try keyEvent(.keyDown, key: 47, flags: [.command, .shift]))
        #expect(saved == nil)
        _ = handler?(try keyEvent(.keyUp, key: 47))
        #expect(saved?.keyCode == 47)
        #expect(saved?.flags == [.maskCommand, .maskShift])
        #expect(events == ["removed", "resumed", "saved"])
        recorder.cancel()
        #expect(events.count == 3)
    }

    private func keyEvent(_ type: NSEvent.EventType, key: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
    }
}
