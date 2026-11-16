import AppKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("ReleaseAppHotkeyGuard")
struct ReleaseAppHotkeyGuardTests {
    private static let rightOption = HotkeyConfig(keyCode: 61, label: "Right Option")
    private static let leftOption = HotkeyConfig(keyCode: 58, label: "Left Option")
    private static let optionR = HotkeyConfig.combination(modifiers: .option, keyCode: 15)

    @Test("only non-release muesli builds yield shortcuts")
    func appliesOnlyToNonReleaseBuilds() {
        #expect(!ReleaseHotkeyYieldPolicy.appliesTo(bundleIdentifier: "com.muesli.app"))
        #expect(!ReleaseHotkeyYieldPolicy.appliesTo(bundleIdentifier: nil))
        #expect(!ReleaseHotkeyYieldPolicy.appliesTo(bundleIdentifier: "com.apple.dt.xctest.tool"))
        for id in ["com.muesli.dev", "com.muesli.dev.a", "com.muesli.canary", "com.muesli.preprod"] {
            #expect(ReleaseHotkeyYieldPolicy.appliesTo(bundleIdentifier: id), "\(id)")
        }
        #expect(ReleaseAppHotkeyGuard.forCurrentBuild(bundleIdentifier: "com.muesli.app") == nil)
        #expect(ReleaseAppHotkeyGuard.forCurrentBuild(bundleIdentifier: "com.muesli.dev") != nil)
    }

    @Test("release shortcuts count only when their feature is enabled")
    func handledHotkeysFollowEnablement() {
        var config = AppConfig()
        config.enablePushToTalk = true
        config.enableQuilMode = false
        config.enableComputerUseHotkey = false
        config.enableMeetingRecordingHotkey = true
        config.enableFeedbackCapture = false
        #expect(ReleaseHotkeyYieldPolicy.handledHotkeys(in: config) == [config.dictationHotkey, config.meetingRecordingHotkey])

        config.enablePushToTalk = false
        #expect(ReleaseHotkeyYieldPolicy.handledHotkeys(in: config) == [config.meetingRecordingHotkey])
    }

    @Test("yields only when one press would trigger both apps")
    func samePressDetection() {
        let policy = ReleaseHotkeyYieldPolicy.self
        #expect(policy.samePressTriggersBoth(Self.rightOption, Self.rightOption))
        #expect(!policy.samePressTriggersBoth(Self.rightOption, Self.leftOption))
        #expect(policy.samePressTriggersBoth(Self.optionR, Self.optionR))
        #expect(policy.samePressTriggersBoth(Self.optionR, .combination(modifiers: [.option, .shift], keyCode: 15)))
        #expect(!policy.samePressTriggersBoth(Self.rightOption, Self.optionR), "A bare key cancels once the chord's letter goes down")

        #expect(policy.shouldYield(Self.rightOption, releaseIsRunning: true, releaseHotkeys: [Self.rightOption]))
        #expect(!policy.shouldYield(Self.rightOption, releaseIsRunning: false, releaseHotkeys: [Self.rightOption]))
        #expect(!policy.shouldYield(Self.rightOption, releaseIsRunning: true, releaseHotkeys: [Self.leftOption]))
    }

    @Test("guard reads the release config and notices when it changes")
    func guardReadsReleaseConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-hotkey-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        var releaseRunning = false
        let guardUnderTest = ReleaseAppHotkeyGuard(releaseConfigURL: url, releaseIsRunning: { releaseRunning })

        // Missing file: the release app uses defaults, which include Right Option dictation.
        #expect(!guardUnderTest.shouldYield(AppConfig().dictationHotkey))
        releaseRunning = true
        #expect(guardUnderTest.shouldYield(AppConfig().dictationHotkey))

        var config = AppConfig()
        config.dictationHotkey = Self.leftOption
        try JSONEncoder().encode(config).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
        #expect(!guardUnderTest.shouldYield(Self.rightOption))
        #expect(guardUnderTest.shouldYield(Self.leftOption))

        config.dictationHotkey = Self.rightOption
        try JSONEncoder().encode(config).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: url.path)
        #expect(guardUnderTest.shouldYield(Self.rightOption), "An edited release config is re-read")
    }

    @Test("a yielded modifier press starts nothing in the dev build")
    func yieldedModifierPressIsIgnored() {
        var pending: [DispatchWorkItem] = []
        let monitor = HotkeyMonitor(scheduleAfter: { _, item in pending.append(item) })
        monitor.configure(keyCode: 61)
        var yield = true
        monitor.shouldYieldNewPress = { _ in yield }
        var arms = 0, starts = 0, stops = 0, cancels = 0, toggles = 0
        monitor.onArm = { arms += 1 }
        monitor.onStart = { starts += 1 }
        monitor.onStop = { stops += 1 }
        monitor.onCancel = { cancels += 1 }
        monitor.onToggleStart = { toggles += 1 }

        // Hold, then a quick double tap: neither may start anything.
        monitor.handleFlagsChanged(keyCode: 61, flags: .option)
        pending.forEach { $0.perform() }; pending.removeAll()
        monitor.handleFlagsChanged(keyCode: 61, flags: [])
        monitor.handleFlagsChanged(keyCode: 61, flags: .option)
        monitor.handleFlagsChanged(keyCode: 61, flags: [])
        monitor.handleFlagsChanged(keyCode: 61, flags: .option)
        monitor.handleFlagsChanged(keyCode: 61, flags: [])
        #expect(arms == 0 && starts == 0 && stops == 0 && cancels == 0 && toggles == 0)
        #expect(!monitor.hasPendingOrActiveSession)

        // Once the release app quits, the same key works again.
        yield = false
        monitor.handleFlagsChanged(keyCode: 61, flags: .option)
        pending.forEach { $0.perform() }; pending.removeAll()
        #expect(arms == 1 && starts == 1)

        // A session already running in the dev build always finishes normally.
        yield = true
        monitor.handleFlagsChanged(keyCode: 61, flags: [])
        #expect(stops == 1)
    }

    @Test("a yielded chord passes through and is not latched")
    func yieldedCombinationIsIgnored() {
        let monitor = HotkeyMonitor(scheduleAfter: { _, _ in })
        monitor.combinationToggleRequiresHold = false
        monitor.configure(Self.optionR)
        var yield = true
        monitor.shouldYieldNewPress = { hotkey in
            #expect(hotkey == Self.optionR)
            return yield
        }
        var toggleStarts = 0, toggleStops = 0
        monitor.onToggleStart = { toggleStarts += 1 }
        monitor.onToggleStop = { toggleStops += 1 }

        #expect(!monitor.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: .option))
        monitor.handleCombinationForTests(type: .keyUp, keyCode: 15, flags: .option)
        monitor.handleRegisteredHotKeyPressForTests()
        monitor.handleRegisteredHotKeyReleaseForTests()
        #expect(toggleStarts == 0 && !monitor.hasPendingOrActiveSession)

        yield = false
        monitor.handleRegisteredHotKeyPressForTests()
        monitor.handleRegisteredHotKeyReleaseForTests()
        #expect(toggleStarts == 1)

        // Stopping a dev-owned toggle is never yielded.
        yield = true
        monitor.handleRegisteredHotKeyPressForTests()
        #expect(toggleStops == 1)
    }
}
