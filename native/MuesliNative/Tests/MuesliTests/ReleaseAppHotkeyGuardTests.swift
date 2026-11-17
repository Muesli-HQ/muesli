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
        config.hasCompletedOnboarding = true
        config.enablePushToTalk = true
        config.enableQuilMode = false
        config.enableComputerUseHotkey = false
        config.enableMeetingRecordingHotkey = true
        config.enableFeedbackCapture = false
        #expect(ReleaseHotkeyYieldPolicy.handledHotkeys(in: config) == [config.dictationHotkey, config.meetingRecordingHotkey])

        config.enablePushToTalk = false
        #expect(ReleaseHotkeyYieldPolicy.handledHotkeys(in: config) == [config.meetingRecordingHotkey])

        config.hasCompletedOnboarding = false
        #expect(ReleaseHotkeyYieldPolicy.handledHotkeys(in: config).isEmpty, "Release starts no shortcut monitors during onboarding")
    }

    @Test("yields only when one press would trigger both apps")
    func samePressDetection() {
        let policy = ReleaseHotkeyYieldPolicy.self
        #expect(policy.samePressTriggersBoth(Self.rightOption, Self.rightOption))
        #expect(!policy.samePressTriggersBoth(Self.rightOption, Self.leftOption))
        #expect(policy.samePressTriggersBoth(Self.optionR, Self.optionR))
        #expect(!policy.samePressTriggersBoth(Self.optionR, .combination(modifiers: [.option, .shift], keyCode: 15)), "Chords need an exact modifier match")
        #expect(!policy.samePressTriggersBoth(Self.optionR, .combination(modifiers: .option, keyCode: 17)))
        #expect(!policy.samePressTriggersBoth(Self.rightOption, Self.optionR), "A bare key cancels once the chord's letter goes down")

        #expect(policy.shouldYield(Self.rightOption, releaseIsRunning: true, releaseHotkeys: [Self.rightOption]))
        #expect(!policy.shouldYield(Self.rightOption, releaseIsRunning: false, releaseHotkeys: [Self.rightOption]))
        #expect(!policy.shouldYield(Self.rightOption, releaseIsRunning: true, releaseHotkeys: [Self.leftOption]))
    }

    @Test("the collision notice fits the card on one line for every shortcut")
    @MainActor
    func collisionNoticeFitsCard() {
        let notice = ReleaseHotkeyYieldPolicy.collisionNotice(shortcut: "Right ⌥", duringSetup: false)
        #expect(notice.title == "Right ⌥ also starts muesli")
        #expect(notice.actionLabel == "Change Shortcut")
        #expect(ReleaseHotkeyYieldPolicy.collisionNotice(shortcut: "Right ⌥", duringSetup: true).actionLabel == "Show Setup")

        // Same fonts and widest text column as MeetingNotificationController's
        // single-button card with an icon.
        let textWidth = MeetingNotificationController.singleActionTextWidth(cardWidth: 420, textX: 14 + 26 + 9)
        let titleFont = AppFonts.font(size: 13, weight: .semibold)
        let subtitleFont = AppFonts.font(size: 11)
        let shortcuts = [55, 54, 63, 59, 62, 58, 61, 56, 60].map { HotkeyConfig(keyCode: UInt16($0)).displayLabel }
            + [HotkeyConfig.combination(modifiers: [.control, .option, .shift, .command], keyCode: 15).displayLabel]
        for shortcut in shortcuts {
            for duringSetup in [false, true] {
                let notice = ReleaseHotkeyYieldPolicy.collisionNotice(shortcut: shortcut, duringSetup: duringSetup)
                let title = (notice.title as NSString).size(withAttributes: [.font: titleFont]).width
                let subtitle = (notice.subtitle as NSString).size(withAttributes: [.font: subtitleFont]).width
                #expect(title <= textWidth, "\(notice.title): \(title) > \(textWidth)")
                #expect(subtitle <= textWidth, "\(notice.subtitle): \(subtitle) > \(textWidth)")
            }
        }
    }

    /// Collects the guard's snapshot updates so the test applies them on its own thread.
    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [() -> Void] = []
        func add(_ item: @escaping () -> Void) { lock.lock(); items.append(item); lock.unlock() }
        func drain() {
            lock.lock(); let pending = items; items = []; lock.unlock()
            pending.forEach { $0() }
        }
    }

    private static func makeReleaseFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-hotkey-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func write(_ config: AppConfig, to url: URL, modified: TimeInterval) throws {
        try JSONEncoder().encode(config).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
    }

    @Test("guard reads the release config in the background and notices when it changes")
    func guardReadsReleaseConfig() throws {
        let dir = try Self.makeReleaseFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        var config = AppConfig()
        config.hasCompletedOnboarding = true
        config.dictationHotkey = Self.leftOption
        try Self.write(config, to: url, modified: 1)

        var releaseRunning = false
        let inbox = Inbox()
        let guardUnderTest = ReleaseAppHotkeyGuard(
            releaseConfigURL: url,
            releaseIsRunning: { releaseRunning },
            deliver: { inbox.add($0) }
        )
        func settle() { guardUnderTest.refresh(); guardUnderTest.waitForRefreshForTests(); inbox.drain() }

        // Until the first background read lands, a press reads an empty snapshot.
        releaseRunning = true
        #expect(!guardUnderTest.shouldYield(Self.leftOption), "A press never reads the file itself")
        settle()
        #expect(guardUnderTest.shouldYield(Self.leftOption))
        #expect(!guardUnderTest.shouldYield(Self.rightOption))
        releaseRunning = false
        #expect(!guardUnderTest.shouldYield(Self.leftOption))
        releaseRunning = true

        config.dictationHotkey = Self.rightOption
        try Self.write(config, to: url, modified: 2)
        settle()
        #expect(guardUnderTest.shouldYield(Self.rightOption), "An edited release config is re-read")
        #expect(!guardUnderTest.shouldYield(Self.leftOption))

        // A read that fails mid-save keeps the last good settings and is retried.
        try Data("{".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3)], ofItemAtPath: url.path)
        settle()
        #expect(guardUnderTest.shouldYield(Self.rightOption))
        config.dictationHotkey = Self.leftOption
        try Self.write(config, to: url, modified: 3)
        settle()
        #expect(guardUnderTest.shouldYield(Self.leftOption), "The same file date is read again after a failed read")

        // No file: release has not finished onboarding, so it handles no shortcut.
        try FileManager.default.removeItem(at: url)
        settle()
        #expect(!guardUnderTest.shouldYield(Self.leftOption))
    }

    @Test("the shortcut still stops a meeting the dev build started from the menu bar")
    func menuStartedMeetingIsNotYielded() throws {
        let dir = try Self.makeReleaseFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        var config = AppConfig()
        config.hasCompletedOnboarding = true
        config.enableMeetingRecordingHotkey = true
        config.meetingRecordingHotkey = Self.optionR
        try Self.write(config, to: url, modified: 1)
        let inbox = Inbox()
        let releaseGuard = ReleaseAppHotkeyGuard(releaseConfigURL: url, releaseIsRunning: { true }, deliver: { inbox.add($0) })
        releaseGuard.waitForRefreshForTests(); inbox.drain()

        // Set up like MuesliController's meeting monitor.
        let monitor = HotkeyMonitor(scheduleAfter: { _, _ in })
        monitor.doubleTapEnabled = false
        monitor.combinationToggleRequiresHold = false
        monitor.configure(Self.optionR)
        var meetingRecording = false, yields = 0, toggles = 0
        monitor.shouldYieldNewPress = releaseGuard.yieldHandler(
            ownsRunningSession: { meetingRecording },
            onYield: { _ in yields += 1 }
        )
        monitor.onToggleStart = { toggles += 1 }

        monitor.handleRegisteredHotKeyPressForTests()
        monitor.handleRegisteredHotKeyReleaseForTests()
        #expect(yields == 1 && toggles == 0, "With no meeting running, release takes the press")

        // A meeting started from the menu bar leaves the monitor idle, so the stop
        // press looks new. It must reach the dev build, which then stops the meeting.
        meetingRecording = true
        monitor.handleRegisteredHotKeyPressForTests()
        #expect(yields == 1 && toggles == 1)
    }

    @Test("release presence follows launch and quit notifications")
    func presenceFollowsWorkspaceNotifications() {
        let center = NotificationCenter()
        let presence = ReleaseAppPresence(center: center)
        let release = NSRunningApplication.runningApplications(withBundleIdentifier: "com.muesli.app").first
        // Other apps never change the flag.
        let other = NSRunningApplication.current
        let before = presence.isRunning
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: other])
        #expect(presence.isRunning == before)
        // Without a running release app there is no NSRunningApplication to post.
        guard let release else { return }
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: release])
        #expect(!presence.isRunning)
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: release])
        #expect(presence.isRunning)
    }

    @Test("presses that start nothing in either app never ask to yield")
    func unmatchedPressesDoNotAskToYield() {
        var asked = 0
        let chord = HotkeyMonitor(scheduleAfter: { _, _ in })
        chord.combinationToggleRequiresHold = false
        chord.configure(Self.optionR)
        chord.shouldYieldNewPress = { _ in asked += 1; return true }
        chord.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [])
        chord.handleCombinationForTests(type: .keyUp, keyCode: 15, flags: [])
        chord.handleCombinationForTests(type: .keyDown, keyCode: 15, flags: [.option, .shift])
        chord.handleCombinationForTests(type: .keyUp, keyCode: 15, flags: [.option, .shift])
        #expect(asked == 0, "Typing r, or ⌥⇧R, is not the ⌥R shortcut")

        let bare = HotkeyMonitor(scheduleAfter: { _, _ in })
        bare.configure(keyCode: 61)
        bare.shouldYieldNewPress = { _ in asked += 1; return true }
        bare.handleFlagsChanged(keyCode: 61, flags: [.option, .command])
        bare.handleFlagsChanged(keyCode: 61, flags: .command)
        #expect(asked == 0, "Right Option with ⌘ held starts nothing")

        bare.handleFlagsChanged(keyCode: 61, flags: [])
        bare.handleFlagsChanged(keyCode: 61, flags: .option)
        #expect(asked == 1)
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
