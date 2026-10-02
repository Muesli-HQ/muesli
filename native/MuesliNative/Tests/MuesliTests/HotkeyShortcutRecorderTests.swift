import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Hotkey shortcut recorder", .serialized)
@MainActor
struct HotkeyShortcutRecorderTests {
    @Test("bare modifier commits on release only when pressed alone")
    func bareModifier() {
        var capture = HotkeyShortcutCaptureState(target: .dictation)
        capture.flagsChanged(keyCode: 54, flags: .command)
        #expect(capture.completed == nil)
        capture.flagsChanged(keyCode: 54, flags: [])
        #expect(capture.completed == HotkeyConfig(keyCode: 54, label: "Right Cmd"))

        var withOtherModifier = HotkeyShortcutCaptureState(target: .dictation)
        withOtherModifier.flagsChanged(keyCode: 55, flags: .command)
        withOtherModifier.flagsChanged(keyCode: 56, flags: [.command, .shift])
        withOtherModifier.flagsChanged(keyCode: 56, flags: .command)
        withOtherModifier.flagsChanged(keyCode: 55, flags: [])
        #expect(withOtherModifier.completed == nil)

        // A rejected chord must not fall back to recording its modifier.
        var computerUse = HotkeyShortcutCaptureState(target: .computerUse)
        computerUse.flagsChanged(keyCode: 55, flags: .command)
        computerUse.keyDown(keyCode: 0, flags: .command, isRepeat: false)
        computerUse.keyUp(keyCode: 0, flags: .command)
        computerUse.flagsChanged(keyCode: 55, flags: [])
        #expect(computerUse.completed == nil)
        #expect(computerUse.rejectedChord)
    }

    @Test("chord waits for every key, ignores repeats, and normalizes device flags")
    func chordCompletion() {
        var capture = HotkeyShortcutCaptureState(target: .meetingRecording)
        capture.flagsChanged(keyCode: 55, flags: .command)
        capture.flagsChanged(keyCode: 56, flags: [.command, .shift])
        capture.keyDown(keyCode: 15, flags: [.command, .shift, .capsLock, .function], isRepeat: false)
        capture.keyDown(keyCode: 0, flags: [.command, .shift], isRepeat: true)
        capture.keyUp(keyCode: 15, flags: [.command, .shift])
        #expect(capture.completed == nil)
        capture.flagsChanged(keyCode: 55, flags: .shift)
        #expect(capture.completed == nil)
        capture.flagsChanged(keyCode: 56, flags: .capsLock)
        #expect(capture.completed == .meetingRecordingDefault)

        var modifiersFirst = HotkeyShortcutCaptureState(target: .quil)
        modifiersFirst.keyDown(keyCode: 12, flags: .control, isRepeat: false)
        modifiersFirst.flagsChanged(keyCode: 59, flags: [])
        #expect(modifiersFirst.completed == nil)
        modifiersFirst.keyUp(keyCode: 12, flags: [])
        #expect(modifiersFirst.completed?.label == "⌃Q")
    }

    struct ChordRule: Sendable, CustomTestStringConvertible {
        let target: HotkeyShortcutTarget
        let modifiers: NSEvent.ModifierFlags
        let keyCode: UInt16
        let accepted: Bool

        var testDescription: String { "\(target) \(modifiers.rawValue)+\(keyCode) accepted=\(accepted)" }
    }

    @Test("each target keeps its own chord rules", arguments: [
        ChordRule(target: .dictation, modifiers: .shift, keyCode: 0, accepted: false),
        ChordRule(target: .dictation, modifiers: [.control, .option], keyCode: 49, accepted: false),
        ChordRule(target: .quil, modifiers: .control, keyCode: 12, accepted: true),
        ChordRule(target: .quil, modifiers: [.control, .option], keyCode: 12, accepted: false),
        ChordRule(target: .meetingRecording, modifiers: [.command, .shift], keyCode: 15, accepted: true),
        ChordRule(target: .meetingRecording, modifiers: .command, keyCode: 49, accepted: false),
        ChordRule(target: .computerUse, modifiers: .command, keyCode: 0, accepted: false),
    ])
    func targetRules(rule: ChordRule) {
        var capture = HotkeyShortcutCaptureState(target: rule.target)
        capture.keyDown(keyCode: rule.keyCode, flags: rule.modifiers, isRepeat: false)
        capture.keyUp(keyCode: rule.keyCode, flags: [])
        #expect((capture.completed != nil) == rule.accepted)
        #expect(capture.rejectedChord == !rule.accepted)
    }

    @Test("switching a chord back to a bare modifier saves once after resuming monitors")
    func chordBackToBareModifier() throws {
        var handler: ((NSEvent) -> NSEvent?)?
        var events: [String] = []
        var saved: HotkeyConfig?
        let recorder = HotkeyShortcutRecorder(
            addMonitor: { handler = $0; return NSObject() },
            removeMonitor: { _ in events.append("removed") }
        )
        let failure = recorder.start(
            .dictation,
            acquire: { events.append("suspended"); return true },
            release: { events.append("resumed") },
            commit: { saved = $0; events.append("saved") }
        )
        #expect(failure == nil)
        #expect(recorder.target == .dictation)

        let down = try event(.flagsChanged, key: 61, flags: .option)
        #expect(handler?(down) === down)
        _ = handler?(try event(.flagsChanged, key: 61))

        #expect(saved == HotkeyConfig(keyCode: 61, label: "Right Option"))
        #expect(events == ["suspended", "removed", "resumed", "saved"])
        #expect(recorder.target == nil)
    }

    @Test("Escape, teardown, and failures restore monitors without saving")
    func cancellationAndFailures() throws {
        var handler: ((NSEvent) -> NSEvent?)?
        var removed = 0
        var released = 0
        let recorder = HotkeyShortcutRecorder(addMonitor: { handler = $0; return NSObject() }, removeMonitor: { _ in removed += 1 })
        _ = recorder.start(.quil, acquire: { true }, release: { released += 1 }, commit: { _ in Issue.record("unexpected save") })
        #expect(handler?(try event(.keyDown, key: 12, flags: .control)) == nil)
        #expect(handler?(try event(.keyDown, key: 53, flags: .control)) == nil)
        #expect(recorder.target == nil)
        recorder.cancel() // onDisappear / app deactivation after Escape
        #expect(removed == 1)
        #expect(released == 1)

        _ = recorder.start(.dictation, acquire: { true }, release: { released += 1 }, commit: { _ in Issue.record("unexpected save") })
        recorder.cancel()
        recorder.cancel()
        #expect(released == 2)

        var installed = false
        let busy = HotkeyShortcutRecorder(addMonitor: { _ in installed = true; return NSObject() })
        let busyMessage = busy.start(.dictation, acquire: { false }, release: { released += 1 }, commit: { _ in })
        #expect(busyMessage == HotkeyShortcutRecorder.busyMessage)
        #expect(!installed)
        #expect(released == 2)

        let broken = HotkeyShortcutRecorder(addMonitor: { _ in nil })
        let brokenMessage = broken.start(.dictation, acquire: { true }, release: { released += 1 }, commit: { _ in })
        #expect(brokenMessage == HotkeyShortcutRecorder.installFailedMessage)
        #expect(broken.target == nil)
        #expect(released == 3)
    }

    @Test("only the capturing window resigning key ends capture")
    func windowResignation() {
        let captureWindow = NSWindow()
        let otherWindow = NSWindow()
        var released = 0
        let recorder = HotkeyShortcutRecorder(
            addMonitor: { _ in NSObject() },
            removeMonitor: { _ in },
            keyWindow: { captureWindow }
        )
        _ = recorder.start(.dictation, acquire: { true }, release: { released += 1 }, commit: { _ in })

        recorder.windowDidResignKey(otherWindow)
        recorder.windowDidResignKey(nil)
        #expect(recorder.target == .dictation)

        recorder.windowDidResignKey(captureWindow)
        #expect(recorder.target == nil)
        #expect(released == 1)
    }

    @Test("rejected chords keep recording")
    func rejectedChordKeepsRecording() throws {
        var handler: ((NSEvent) -> NSEvent?)?
        let recorder = HotkeyShortcutRecorder(addMonitor: { handler = $0; return NSObject() }, removeMonitor: { _ in })
        _ = recorder.start(.dictation, acquire: { true }, release: {}, commit: { _ in Issue.record("unexpected save") })
        #expect(handler?(try event(.keyDown, key: 0, flags: .shift)) == nil)
        #expect(recorder.rejectedChord)
        #expect(recorder.target == .dictation)
        recorder.cancel()
    }

    private func event(_ type: NSEvent.EventType, key: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
    }
}
