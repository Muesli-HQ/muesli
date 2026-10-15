import AppKit
import Foundation
import IOKit.hidsystem
import Testing
@testable import MuesliNativeApp

@Suite("DictationHotkeyGroup")
@MainActor
struct DictationHotkeyGroupTests {
    final class Clock {
        var time: TimeInterval = 0
        var jobs: [(TimeInterval, DispatchWorkItem)] = []

        func makeMonitor() -> HotkeyMonitor {
            HotkeyMonitor(
                prepareDelay: 0.02,
                startDelay: 0.05,
                doubleTapWindow: 0.1,
                scheduleAfter: { [self] delay, item in jobs.append((time + delay, item)) },
                now: { [self] in Date(timeIntervalSinceReferenceDate: time) }
            )
        }

        func advance(_ interval: TimeInterval) {
            let deadline = time + interval
            while let index = jobs.indices.filter({ jobs[$0].0 <= deadline }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
                let (scheduled, item) = jobs.remove(at: index)
                time = scheduled
                if !item.isCancelled { item.perform() }
            }
            time = deadline
        }
    }

    let a = HotkeyConfig.combination(modifiers: [.command, .shift], keyCode: 2)
    let b = HotkeyConfig.combination(modifiers: [.control, .option], keyCode: 49)

    @Test("only the admitted chord owns preparation, Escape, and stop")
    func competingChords() {
        let clock = Clock()
        var monitors: [HotkeyMonitor] = []
        let group = DictationHotkeyGroup(monitorFactory: {
            let monitor = clock.makeMonitor(); monitors.append(monitor); return monitor
        })
        group.configureTriggerThreshold(milliseconds: 50)
        group.doubleTapEnabled = false
        group.combinationActivation = .pushToTalk
        group.configure([a, b])
        monitors.removeFirst()
        var events: [String] = []
        group.onPrepare = { events.append("prepare") }
        group.onStart = { events.append("start") }
        group.onStop = { events.append("stop") }
        group.onCancel = { events.append("cancel") }

        monitors[0].handleCombinationForTests(type: .keyDown, keyCode: 2, flags: [.command, .shift])
        monitors[1].handleCombinationForTests(type: .keyDown, keyCode: 49, flags: [.control, .option])
        #expect(!monitors[1].handleCombinationForTests(type: .keyDown, keyCode: 53, flags: []))
        clock.advance(0.06)
        #expect(events == ["prepare", "start"])
        #expect(monitors[0].handleCombinationForTests(type: .keyDown, keyCode: 53, flags: []))
        #expect(events == ["prepare", "start", "cancel"])
        monitors[0].handleCombinationForTests(type: .keyUp, keyCode: 2, flags: [])
        monitors[1].handleCombinationForTests(type: .keyUp, keyCode: 49, flags: [])
        monitors[1].handleCombinationForTests(type: .keyDown, keyCode: 49, flags: [.control, .option])
        clock.advance(0.06)
        monitors[1].handleCombinationForTests(type: .keyUp, keyCode: 49, flags: [])
        #expect(events == ["prepare", "start", "cancel", "prepare", "start", "stop"])
    }

    @Test("Escape cancels whichever shortcut currently owns recording")
    func escapeFromSecondShortcut() {
        let clock = Clock()
        var monitors: [HotkeyMonitor] = []
        let group = DictationHotkeyGroup(monitorFactory: {
            let monitor = clock.makeMonitor(); monitors.append(monitor); return monitor
        })
        group.configureTriggerThreshold(milliseconds: 50)
        group.combinationActivation = .pushToTalk
        group.configure([a, b])
        monitors.removeFirst()
        var events: [String] = []
        group.onStart = { events.append("start") }
        group.onCancel = { events.append("cancel") }
        monitors[1].handleCombinationForTests(type: .keyDown, keyCode: 49, flags: [.control, .option])
        clock.advance(0.06)
        #expect(!monitors[0].handleCombinationForTests(type: .keyDown, keyCode: 53, flags: []))
        #expect(monitors[1].handleCombinationForTests(type: .keyDown, keyCode: 53, flags: []))
        #expect(events == ["start", "cancel"])
    }

    @Test("reconfiguration preserves a nonremoved owner and finishes a removed owner")
    func reconfiguration() {
        let clock = Clock()
        var monitors: [HotkeyMonitor] = []
        let group = DictationHotkeyGroup(monitorFactory: {
            let monitor = clock.makeMonitor(); monitors.append(monitor); return monitor
        })
        group.configureTriggerThreshold(milliseconds: 50)
        group.doubleTapEnabled = false
        group.combinationActivation = .pushToTalk
        group.configure([a, b])
        monitors.removeFirst()
        var events: [String] = []
        group.onStart = { events.append("start") }
        group.onStop = { events.append("stop") }
        monitors[0].handleCombinationForTests(type: .keyDown, keyCode: 2, flags: [.command, .shift])
        clock.advance(0.06)
        group.configure([a])
        #expect(group.hasPendingOrActiveSession)
        #expect(events == ["start"])
        group.configure([a, b])
        monitors[0].handleCombinationForTests(type: .keyUp, keyCode: 2, flags: [])
        #expect(events == ["start", "stop"])
        monitors[2].handleCombinationForTests(type: .keyDown, keyCode: 49, flags: [.control, .option])
        clock.advance(0.06)
        group.configure([a])
        #expect(events == ["start", "stop", "start", "stop"])
    }

    @Test("a refused toggle and a cancelled held chord wait for physical release")
    func physicalLatch() {
        let clock = Clock()
        var monitors: [HotkeyMonitor] = []
        let group = DictationHotkeyGroup(monitorFactory: {
            let monitor = clock.makeMonitor(); monitors.append(monitor); return monitor
        })
        group.configureTriggerThreshold(milliseconds: 50)
        group.configure([a, b])
        monitors.removeFirst()
        group.combinationToggleRequiresHold = false
        var starts = 0
        group.onToggleStart = {
            starts += 1; group.cancelToggleMode()
        }
        monitors[0].handleRegisteredHotKeyPressForTests()
        monitors[0].handleRegisteredHotKeyPressForTests()
        #expect(starts == 1)
        monitors[0].handleRegisteredHotKeyReleaseForTests()
        monitors[0].handleRegisteredHotKeyPressForTests()
        #expect(starts == 2)
        monitors[0].handleCombinationForTests(type: .keyDown, keyCode: 53, flags: [])
        monitors[0].handleRegisteredHotKeyPressForTests()
        #expect(starts == 2)
        monitors[0].handleRegisteredHotKeyReleaseForTests()
    }

    @Test("a toggle can stop from the same shortcut or the floating control")
    func toggleStops() {
        let clock = Clock()
        var monitors: [HotkeyMonitor] = []
        let group = DictationHotkeyGroup(monitorFactory: {
            let monitor = clock.makeMonitor(); monitors.append(monitor); return monitor
        })
        group.configureTriggerThreshold(milliseconds: 50)
        group.configure([a, b])
        monitors.removeFirst()
        group.combinationToggleRequiresHold = false
        var events: [String] = []
        group.onToggleStart = { events.append("start") }
        group.onToggleStop = { events.append("stop") }
        monitors[1].handleRegisteredHotKeyPressForTests()
        monitors[1].handleRegisteredHotKeyReleaseForTests()
        monitors[0].handleRegisteredHotKeyPressForTests()
        monitors[0].handleRegisteredHotKeyReleaseForTests()
        #expect(events == ["start"])
        monitors[1].handleRegisteredHotKeyPressForTests()
        monitors[1].handleRegisteredHotKeyReleaseForTests()
        #expect(events == ["start", "stop"])
        monitors[1].handleRegisteredHotKeyPressForTests()
        monitors[1].handleRegisteredHotKeyReleaseForTests()
        group.stopToggleMode()
        #expect(events == ["start", "stop", "start", "stop"])
    }

    @Test("a short modifier tap keeps ownership through the double tap window")
    func doubleTapReservation() {
        let clock = Clock()
        var monitors: [HotkeyMonitor] = []
        let group = DictationHotkeyGroup(monitorFactory: {
            let monitor = clock.makeMonitor(); monitors.append(monitor); return monitor
        })
        group.configureTriggerThreshold(milliseconds: 50)
        group.configure([.default, b])
        group.combinationToggleRequiresHold = false
        var events: [String] = []
        group.onArm = { events.append("arm") }
        group.onCancel = { events.append("cancel") }
        group.onToggleStart = { events.append("toggle") }

        monitors[0].handleFlagsChanged(keyCode: HotkeyConfig.default.keyCode, flags: .option)
        monitors[0].handleFlagsChanged(keyCode: HotkeyConfig.default.keyCode, flags: [])
        monitors[1].handleCombinationForTests(type: .keyDown, keyCode: 49, flags: [.control, .option])
        clock.advance(0.05)
        #expect(events == ["arm"])
        monitors[1].handleCombinationForTests(type: .keyUp, keyCode: 49, flags: [])
        monitors[0].handleFlagsChanged(keyCode: HotkeyConfig.default.keyCode, flags: .option)
        #expect(events == ["arm", "toggle"])
        monitors[0].handleFlagsChanged(keyCode: HotkeyConfig.default.keyCode, flags: [])
        group.stopToggleMode()
        monitors[1].handleCombinationForTests(type: .keyDown, keyCode: 49, flags: [.control, .option])
        #expect(events == ["arm", "toggle", "toggle"])
    }

    @Test("removing a pending or toggle owner closes its lifecycle")
    func removeOwner() {
        let clock = Clock()
        var monitors: [HotkeyMonitor] = []
        let group = DictationHotkeyGroup(monitorFactory: {
            let monitor = clock.makeMonitor(); monitors.append(monitor); return monitor
        })
        group.configureTriggerThreshold(milliseconds: 50)
        group.configure([a, b])
        monitors.removeFirst()
        var events: [String] = []
        group.onCancel = { events.append("cancel") }
        group.onToggleStart = { events.append("toggle-start") }
        group.onToggleStop = { events.append("toggle-stop") }
        group.combinationToggleRequiresHold = true
        monitors[0].handleCombinationForTests(type: .keyDown, keyCode: 2, flags: [.command, .shift])
        group.configure([b])
        #expect(events.isEmpty)
        monitors[0].handleCombinationForTests(type: .keyUp, keyCode: 2, flags: [])

        group.configure([a, b])
        let replacement = monitors.last!
        replacement.handleCombinationForTests(type: .keyDown, keyCode: 2, flags: [.command, .shift])
        clock.advance(0.06)
        #expect(events == ["toggle-start"])
        group.configure([b])
        #expect(events == ["toggle-start", "toggle-stop"])
    }

    @Test("removing an armed modifier reports cancellation")
    func removeArmedModifier() {
        let clock = Clock()
        var monitors: [HotkeyMonitor] = []
        let group = DictationHotkeyGroup(monitorFactory: {
            let monitor = clock.makeMonitor(); monitors.append(monitor); return monitor
        })
        group.configureTriggerThreshold(milliseconds: 50)
        group.configure([.default, b])
        var events: [String] = []
        group.onArm = { events.append("arm") }
        group.onCancel = { events.append("cancel") }
        monitors[0].handleFlagsChanged(keyCode: HotkeyConfig.default.keyCode, flags: .option)
        group.configure([b])
        #expect(events == ["arm", "cancel"])
    }

    @Test("post-Escape release in a text field frees ownership", arguments: [false, true])
    func textFieldRelease(bare: Bool) {
        let clock = Clock()
        var monitors: [HotkeyMonitor] = []
        let group = DictationHotkeyGroup(monitorFactory: {
            let monitor = clock.makeMonitor(); monitors.append(monitor); return monitor
        })
        group.configureTriggerThreshold(milliseconds: 50)
        group.doubleTapEnabled = false
        group.combinationActivation = .pushToTalk
        group.configure([.quilDefault, a])
        monitors.removeFirst()
        let owner = monitors[bare ? 0 : 1]
        var events: [String] = []
        group.onStart = { events.append("start") }
        group.onCancel = { events.append("cancel") }
        if bare {
            owner.handleFlagsChanged(keyCode: 63, flags: .function)
        } else {
            owner.handleCombinationForTests(type: .keyDown, keyCode: 2, flags: [.command, .shift])
        }
        clock.advance(0.06)
        if bare {
            owner.handleKeyDown(keyCode: 53)
        } else {
            owner.handleCombinationForTests(type: .keyDown, keyCode: 53, flags: [])
        }
        let acceptsRelease = owner.shouldHandleLocalEventForTests(
            type: bare ? .flagsChanged : .keyUp, keyCode: bare ? 63 : 2, firstResponder: NSTextField())
        #expect(acceptsRelease)
        if acceptsRelease {
            if bare {
                owner.handleFlagsChanged(keyCode: 63, flags: [])
            } else {
                owner.handleCombinationForTests(type: .keyUp, keyCode: 2, flags: [])
            }
        }
        if bare {
            monitors[1].handleCombinationForTests(type: .keyDown, keyCode: 2, flags: [.command, .shift])
        } else {
            monitors[0].handleFlagsChanged(keyCode: 63, flags: .function)
        }
        clock.advance(0.06)
        #expect(events == ["start", "cancel", "start"])
    }

    @Test(
        "opposite-side modifier releases leave other shortcuts usable",
        arguments: [
            (59, 62, Int(NX_DEVICELCTLKEYMASK), Int(NX_DEVICERCTLKEYMASK), NSEvent.ModifierFlags.control),
            (58, 61, Int(NX_DEVICELALTKEYMASK), Int(NX_DEVICERALTKEYMASK), NSEvent.ModifierFlags.option),
            (55, 54, Int(NX_DEVICELCMDKEYMASK), Int(NX_DEVICERCMDKEYMASK), NSEvent.ModifierFlags.command),
            (56, 60, Int(NX_DEVICELSHIFTKEYMASK), Int(NX_DEVICERSHIFTKEYMASK), NSEvent.ModifierFlags.shift),
        ])
    func oppositeSideModifiers(leftKey: Int, rightKey: Int, leftMask: Int, rightMask: Int, family: NSEvent.ModifierFlags) {
        let left = HotkeyConfig(keyCode: UInt16(leftKey), label: "Left")
        let right = HotkeyConfig(keyCode: UInt16(rightKey), label: "Right")
        #expect(!ShortcutHotkeyPolicy.hotkeysConflict(left, right))
        let clock = Clock()
        var monitors: [HotkeyMonitor] = []
        let group = DictationHotkeyGroup(monitorFactory: {
            let monitor = clock.makeMonitor(); monitors.append(monitor); return monitor
        })
        group.configureTriggerThreshold(milliseconds: 50)
        group.doubleTapEnabled = false
        group.configure([left, right])
        monitors.removeFirst()
        var events: [String] = []
        group.onStart = { events.append("start") }
        group.onStop = { events.append("stop") }
        func deliver(_ key: Int, _ deviceFlags: Int, _ flags: NSEvent.ModifierFlags) {
            let eventFlags = flags.union(NSEvent.ModifierFlags(rawValue: UInt(deviceFlags)))
            monitors.forEach { $0.handleFlagsChanged(keyCode: UInt16(key), flags: eventFlags) }
        }
        deliver(leftKey, leftMask, family)
        clock.advance(0.06)
        deliver(rightKey, leftMask | rightMask, family)
        deliver(leftKey, rightMask, family)
        deliver(rightKey, 0, [])
        #expect(!group.hasPendingOrActiveSession)
        deliver(rightKey, rightMask, family)
        clock.advance(0.06)
        deliver(rightKey, 0, [])
        #expect(events == ["start", "stop", "start", "stop"])
    }

    @Test("capture stop revokes resume")
    func captureStop() {
        let group = DictationHotkeyGroup()
        group.suspendForShortcutCapture()
        group.stop()
        group.resumeAfterShortcutCapture()
        #expect(!group.isRunning)
    }
}
