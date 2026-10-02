import AppKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Modifier toggle gesture")
struct ModifierToggleGestureTests {
    @Test func releaseRequiresAnUnchordedPress() {
        var gesture = ModifierToggleGesture()
        let noPress = gesture.release()
        #expect(!noPress)
        gesture.press()
        gesture.press()
        let standalone = gesture.release()
        #expect(standalone)
        let duplicateUp = gesture.release()
        #expect(!duplicateUp)
        gesture.press()
        gesture.chord()
        let chord = gesture.release()
        #expect(!chord)
        gesture.press()
        gesture.reset()
        let cancelled = gesture.release()
        #expect(!cancelled)
    }

    @Test @MainActor func tapsToggleOnReleaseWithoutTimers() {
        var scheduled = 0
        let monitor = HotkeyMonitor(scheduleAfter: { _, _ in scheduled += 1 })
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var actions: [String] = []
        monitor.onToggleStart = { actions.append("start") }
        monitor.onToggleStop = { actions.append("stop") }
        for cycle in 0..<4 {
            monitor.handleFlagsChanged(keyCode: 54, flags: .command)
            monitor.handleFlagsChanged(keyCode: 54, flags: .command) // Duplicate down.
            #expect(actions.count == cycle)
            monitor.handleFlagsChanged(keyCode: 54, flags: [])
            monitor.handleFlagsChanged(keyCode: 54, flags: []) // Duplicate up.
        }
        #expect(actions == ["start", "stop", "start", "stop"])
        #expect(scheduled == 0)
    }

    @Test(arguments: [UInt16(8), 9, 48]) @MainActor
    func commandChordsNeverStartOrStop(key: UInt16) {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        var stops = 0
        monitor.onToggleStart = { starts += 1 }
        monitor.onToggleStop = { stops += 1 }
        for recording in [false, true] {
            if recording {
                monitor.handleFlagsChanged(keyCode: 54, flags: .command)
                monitor.handleFlagsChanged(keyCode: 54, flags: [])
            }
            monitor.handleFlagsChanged(keyCode: 54, flags: .command)
            monitor.handleKeyDown(keyCode: key)
            monitor.handleKeyDown(keyCode: key) // Repeat.
            monitor.handleKeyUp(keyCode: key)
            monitor.handleFlagsChanged(keyCode: 54, flags: [])
            #expect(monitor.isToggleRecording == recording)
        }
        #expect(starts == 1)
        #expect(stops == 0)
    }

    @Test @MainActor func bothCommandSidesDoNotCommitATap() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        monitor.onToggleStart = { starts += 1 }
        // Right release still carries aggregate command because left is held.
        monitor.handleFlagsChanged(keyCode: 54, flags: .command, physicalKeyDown: true)
        monitor.handleFlagsChanged(keyCode: 55, flags: .command, physicalKeyDown: true)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command, physicalKeyDown: false)
        monitor.handleFlagsChanged(keyCode: 55, flags: [], physicalKeyDown: false)
        #expect(starts == 0)
        // Other side was already down when the selected key joined it.
        monitor.handleFlagsChanged(keyCode: 55, flags: .command, physicalKeyDown: true)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command, physicalKeyDown: true)
        monitor.handleFlagsChanged(keyCode: 55, flags: .command, physicalKeyDown: false)
        monitor.handleFlagsChanged(keyCode: 54, flags: [], physicalKeyDown: false)
        #expect(starts == 0)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command, physicalKeyDown: true)
        monitor.handleFlagsChanged(keyCode: 54, flags: [], physicalKeyDown: false)
        #expect(starts == 1)
    }

    @Test @MainActor func otherModifiersSuppressPendingGesture() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        monitor.onToggleStart = { starts += 1 }
        monitor.handleFlagsChanged(keyCode: 54, flags: [.command, .shift])
        monitor.handleFlagsChanged(keyCode: 54, flags: .shift)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 56, flags: [.command, .shift])
        monitor.handleFlagsChanged(keyCode: 56, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 0)
    }

    @Test @MainActor func longStandaloneHoldTogglesOnlyAtRelease() {
        let scheduler = HotkeyMonitorTests.ManualHotkeyScheduler()
        let monitor = scheduler.makeMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var actions: [String] = []
        monitor.onPrepare = { actions.append("prepare") }
        monitor.onStart = { actions.append("hold") }
        monitor.onToggleStart = { actions.append("toggle") }
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        scheduler.advance(by: 10)
        #expect(actions.isEmpty)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(actions == ["toggle"])
    }

    @Test @MainActor func escapeAndReconfigurationCleanUpOnce() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        var cancels = 0
        var stops = 0
        monitor.onToggleStart = { starts += 1 }
        monitor.onCancel = { cancels += 1 }
        monitor.onToggleStop = { stops += 1 }
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleKeyDown(keyCode: 53)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 0)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        monitor.handleKeyDown(keyCode: 53)
        monitor.handleKeyDown(keyCode: 53)
        #expect(cancels == 1)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        monitor.configureModifierActivation(.hold)
        monitor.configureModifierActivation(.hold)
        monitor.configure(keyCode: 55)
        #expect(stops == 1)
        #expect(!monitor.isToggleRecording)
    }

    @Test @MainActor func externalStopClearsPendingRelease() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        var stops = 0
        monitor.onToggleStart = { starts += 1 }
        monitor.onToggleStop = { stops += 1 }
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.stopToggleMode()
        monitor.stopToggleMode()
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 1)
        #expect(stops == 1)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.cancelCurrentSession()
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 1)
    }
    @Test @MainActor func deviceFlagsDistinguishBothSidesAndDuplicateEdges() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        monitor.onToggleStart = { starts += 1 }
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
        let left = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x08)
        let both = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x18)
        monitor.handleFlagsChanged(keyCode: 54, flags: right)
        monitor.handleFlagsChanged(keyCode: 54, flags: right)
        monitor.handleFlagsChanged(keyCode: 55, flags: both)
        monitor.handleFlagsChanged(keyCode: 54, flags: left)
        monitor.handleFlagsChanged(keyCode: 54, flags: left)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        #expect(starts == 0)
        // A chord already held before the selected key arrives is suppressed.
        monitor.handleFlagsChanged(keyCode: 54, flags: both)
        monitor.handleFlagsChanged(keyCode: 54, flags: left)
        #expect(starts == 0)
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        monitor.handleFlagsChanged(keyCode: 54, flags: right)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 1)
    }

    @Test @MainActor func heldTypingKeySuppressesGestureUntilKeyUp() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        monitor.onToggleStart = { starts += 1 }
        monitor.handleKeyDown(keyCode: 8)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 0)
        monitor.handleKeyUp(keyCode: 8)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 1)
    }

    @Test @MainActor func syntheticPasteDoesNotJoinPhysicalGesture() throws {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        monitor.onToggleStart = { starts += 1 }
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        let source = try #require(CGEventSource(stateID: .combinedSessionState))
        let paste = try #require(CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true))
        MuesliSyntheticKeyboardEvent.mark(paste)
        let event = try #require(NSEvent(cgEvent: paste))
        monitor.handleEventForTests(event)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 1)
    }

    @Test @MainActor func unchangedModeDoesNotStopActiveRecording() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var stops = 0
        monitor.onToggleStop = { stops += 1 }
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        monitor.configureModifierActivation(.toggle)
        #expect(monitor.isToggleRecording)
        #expect(stops == 0)
        monitor.stop()
        monitor.stop()
        #expect(stops == 1)
    }

    @Test @MainActor func callbackCanCancelWithoutLeavingPendingGesture() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        var stops = 0
        monitor.onToggleStart = { starts += 1; monitor.cancelCurrentSession() }
        monitor.onToggleStop = { stops += 1 }
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 1)
        #expect(stops == 0)
        #expect(!monitor.isToggleRecording)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.configure(keyCode: 61)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 1)
        monitor.handleFlagsChanged(keyCode: 61, flags: .option)
        monitor.handleFlagsChanged(keyCode: 61, flags: [])
        #expect(starts == 2)
    }

    @Test @MainActor func capturedAggregateEventsToggleWithoutLiveHardwareState() throws {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var actions: [String] = []
        monitor.onToggleStart = { actions.append("start") }
        monitor.onToggleStop = { actions.append("stop") }
        // Replay captured edges. Their meaning cannot depend on the hardware
        // state at delivery time (e.g. a later press while the main thread slept).
        for _ in 0..<2 {
            for flags: CGEventFlags in [.maskCommand, []] {
                let edge = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true))
                edge.type = .flagsChanged
                edge.flags = flags
                let event = try #require(NSEvent(cgEvent: edge))
                #expect(event.type == .flagsChanged)
                monitor.handleEventForTests(event)
            }
        }
        #expect(actions == ["start", "stop"])
    }

    @Test @MainActor func textEditingKeepsPhysicalKeyBookkeeping() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        let editor = NSTextView()
        monitor.handleKeyDown(keyCode: 8) // Observed in another application.
        #expect(monitor.shouldHandleLocalEventForTests(type: .keyUp, keyCode: 8, firstResponder: editor))
        #expect(monitor.shouldHandleLocalEventForTests(type: .keyDown, keyCode: 9, firstResponder: editor))
        #expect(monitor.shouldHandleLocalEventForTests(type: .flagsChanged, keyCode: 55, firstResponder: editor))
        #expect(!monitor.shouldHandleLocalEventForTests(type: .flagsChanged, keyCode: 54, firstResponder: editor))
    }

    @Test @MainActor func externalCancellationRetainsHeldPhysicalKeys() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        monitor.onToggleStart = { starts += 1 }
        monitor.handleKeyDown(keyCode: 8)
        monitor.cancelCurrentSession()
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 0)
        monitor.handleKeyUp(keyCode: 8)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 1)
    }

    @Test @MainActor func ambiguousBothSideGestureDoesNotSwallowNextTap() {
        let monitor = HotkeyMonitor()
        monitor.configure(keyCode: 54)
        monitor.configureModifierActivation(.toggle)
        var starts = 0
        monitor.onToggleStart = { starts += 1 }
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 55, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command) // Ambiguous selected release.
        monitor.handleFlagsChanged(keyCode: 55, flags: [])
        #expect(starts == 0)
        monitor.handleFlagsChanged(keyCode: 54, flags: .command)
        monitor.handleFlagsChanged(keyCode: 54, flags: [])
        #expect(starts == 1)
    }

}
