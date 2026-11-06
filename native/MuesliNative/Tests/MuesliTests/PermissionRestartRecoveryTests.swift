import AppKit
import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Permission restart recovery")
struct PermissionRestartRecoveryTests {
    @Test("permission setup destination survives a new store and is consumed once")
    @MainActor
    func restoresOriginWithoutRepeatingOrAssumingAccess() throws {
        let suite = "permission-restart-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PermissionRestartResumeStore(defaults: defaults)
        #expect(store.consume(fallbackToPermissions: false) == nil)
        store.save(.timeTurnerPermissions)
        let reopened = PermissionRestartResumeStore(defaults: defaults)
        // macOS Quit & Reopen supplies no muesli-specific launch argument.
        #expect(reopened.consume(fallbackToPermissions: false) == .timeTurnerPermissions)
        #expect(reopened.consume(fallbackToPermissions: false) == nil)
        store.save(.timeTurnerPermissions)
        #expect(reopened.consume(fallbackToPermissions: true) == .timeTurnerPermissions)
        #expect(reopened.consume(fallbackToPermissions: true) == .permissions)
        store.save(.timeTurnerPermissions)
        store.clear() // Explicitly leaving or finishing setup cancels restoration.
        #expect(reopened.consume(fallbackToPermissions: false) == nil)
        defaults.set("future-destination", forKey: "permissionRestart.destination")
        #expect(reopened.consume(fallbackToPermissions: true) == .permissions)
        #expect(defaults.object(forKey: "permissionRestart.destination") == nil)
        #expect(defaults.object(forKey: "permissionRestart.requestedAt") == nil)
    }

    @Test("abandoned setup expires while an immediate macOS reopen restores its origin")
    @MainActor
    func expiresSavedDestination() throws {
        let suite = "permission-restart-expiry-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var date = Date(timeIntervalSince1970: 1_000_000)
        let store = PermissionRestartResumeStore(defaults: defaults, now: { date })
        store.save(.timeTurnerPermissions)
        date.addTimeInterval(120) // Includes the existing relaunch helper's bounded wait.
        let reopened = PermissionRestartResumeStore(defaults: defaults, now: { date })
        #expect(reopened.consume(fallbackToPermissions: false) == .timeTurnerPermissions)
        store.save(.timeTurnerPermissions)
        date.addTimeInterval(PermissionRecoveryIntentLifetime.maximumAge)
        #expect(reopened.consume(fallbackToPermissions: false) == nil)
        #expect(defaults.object(forKey: "permissionRestart.destination") == nil)
        #expect(defaults.object(forKey: "permissionRestart.requestedAt") == nil)
        store.save(.timeTurnerPermissions)
        date.addTimeInterval(PermissionRecoveryIntentLifetime.maximumAge + 1)
        #expect(reopened.consume(fallbackToPermissions: true) == .permissions)
        // Explicitly starting setup again creates a fresh intent after expiration.
        store.save(.timeTurnerPermissions)
        #expect(reopened.consume(fallbackToPermissions: false) == .timeTurnerPermissions)
    }

    @Test("legacy, invalid and future setup timestamps never restore stale navigation")
    @MainActor
    func rejectsInvalidDestinationTimestamps() throws {
        let suite = "permission-restart-invalid-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_000_000)
        let store = PermissionRestartResumeStore(defaults: defaults, now: { date })
        let timestamps: [Any?] = [nil, "not-a-date", date.addingTimeInterval(1)]
        for timestamp in timestamps {
            defaults.set("timeTurnerPermissions", forKey: "permissionRestart.destination")
            defaults.set(timestamp, forKey: "permissionRestart.requestedAt")
            #expect(store.consume(fallbackToPermissions: false) == nil)
            #expect(defaults.object(forKey: "permissionRestart.destination") == nil)
            #expect(defaults.object(forKey: "permissionRestart.requestedAt") == nil)
        }
    }

    @Test("restart notice is hosted above an open feature setup sheet")
    @MainActor
    func noticeUsesVisibleSetupSheet() {
        _ = NSApplication.shared
        let dashboard = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 500),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        let setup = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                             styleMask: [.titled], backing: .buffered, defer: false)
        dashboard.isReleasedWhenClosed = false
        setup.isReleasedWhenClosed = false
        defer { dashboard.endSheet(setup); setup.orderOut(nil); dashboard.close() }
        #expect(PermissionRestartPresentation.host(in: dashboard) === dashboard)
        dashboard.beginSheet(setup)
        #expect(dashboard.attachedSheet === setup)
        #expect(PermissionRestartPresentation.host(in: dashboard) === setup)
        let unrelated = NSWindow()
        unrelated.preventsApplicationTerminationWhenModal = true
        dashboard.preventsApplicationTerminationWhenModal = true
        setup.preventsApplicationTerminationWhenModal = true
        PermissionRestartPresentation.allowTermination(from: dashboard)
        #expect(!setup.preventsApplicationTerminationWhenModal)
        #expect(!dashboard.preventsApplicationTerminationWhenModal)
        #expect(unrelated.preventsApplicationTerminationWhenModal)
    }

    @Test("only new requests for restart-sensitive permissions queue a notice")
    @MainActor
    func requestsCoalesceWithoutClaimingAccess() {
        let recovery = PermissionRestartRecovery()
        recovery.requested(.microphone, wasGranted: false)
        recovery.requested(.screenRecording, wasGranted: true)
        #expect(recovery.takeNotice().isEmpty)
        recovery.requested(.screenRecording, wasGranted: false)
        recovery.requested(.screenRecording, wasGranted: false)
        recovery.requested(.inputMonitoring, wasGranted: false)
        recovery.requested(.accessibility, wasGranted: false)
        recovery.applicationActivated(bundleID: AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID)
        #expect(recovery.takeNotice() == [.accessibility, .inputMonitoring, .screenRecording])
        #expect(recovery.takeNotice().isEmpty)
        // Choosing Later consumes the notice; a new process does not inherit it.
        #expect(PermissionRestartRecovery().takeNotice().isEmpty)
    }

    @Test("denied prompts and unrelated app activations do not produce restart notices")
    @MainActor
    func requiresSettingsVisitAfterRequest() {
        let recovery = PermissionRestartRecovery()
        let settings = AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID
        recovery.applicationActivated(bundleID: settings) // A visit before the request is unrelated.
        recovery.requested(.screenRecording, wasGranted: false)
        recovery.applicationActivated(bundleID: "com.apple.finder")
        #expect(recovery.takeNotice().isEmpty)
        recovery.applicationActivated(bundleID: settings)
        #expect(recovery.takeNotice().isEmpty) // The abandoned request was consumed.
        recovery.requested(.screenRecording, wasGranted: false)
        recovery.applicationActivated(bundleID: settings)
        #expect(recovery.takeNotice() == [.screenRecording])
    }

    @Test("each permission notice expires independently and a new request can retry")
    @MainActor
    func expiresPendingNotices() {
        var date = Date(timeIntervalSince1970: 1_000_000)
        let recovery = PermissionRestartRecovery(now: { date })
        let settings = AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID
        recovery.requested(.screenRecording, wasGranted: false)
        recovery.applicationActivated(bundleID: settings)
        date.addTimeInterval(PermissionRecoveryIntentLifetime.maximumAge)
        recovery.requested(.accessibility, wasGranted: false)
        recovery.applicationActivated(bundleID: settings)
        #expect(recovery.takeNotice() == [.accessibility])
        recovery.requested(.screenRecording, wasGranted: false)
        recovery.applicationActivated(bundleID: settings)
        #expect(recovery.takeNotice() == [.screenRecording])
        recovery.requested(.screenRecording, wasGranted: false)
        recovery.applicationActivated(bundleID: settings)
        date.addTimeInterval(-1) // Clock rollback must not prolong an intent.
        #expect(recovery.takeNotice().isEmpty)
    }

    @Test("restart refuses active work and becomes available when it finishes", arguments: [
        PermissionRestartActivity(recording: true),
        PermissionRestartActivity(processing: true),
        PermissionRestartActivity(assistant: true),
        PermissionRestartActivity(unsentChat: true),
    ])
    func protectsWork(activity: PermissionRestartActivity) {
        #expect(activity.blockingMessage != nil)
        #expect(PermissionRestartActivity().blockingMessage == nil)
    }

    @Test("restart checks never initialize chat, including after a privacy reset", arguments: [false, true])
    @MainActor
    func restartCheckDoesNotInitializeChat(afterPrivacyReset: Bool) throws {
        let directory = summaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try summaryController(directory: directory)
        if afterPrivacyReset {
            _ = controller.meetingChatCoordinator
            #expect(controller.storedMeetingChatCoordinator != nil)
            controller.resetChatForPrivacyTransition()
        }
        #expect(controller.storedMeetingChatCoordinator == nil)
        // Both the initial restart request and termination admission recheck activity.
        for _ in 0..<2 {
            let activity = controller.permissionRestartActivity
            #expect(!activity.assistant && !activity.unsentChat)
            #expect(activity.blockingMessage == nil)
            #expect(controller.storedMeetingChatCoordinator == nil)
        }
    }

    @Test("re-summary blocks restart before task startup and through saving")
    @MainActor
    func protectsSummaryGenerationAndSave() async throws {
        let directory = summaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try summaryController(directory: directory)
        let generation = AsyncStream<Void>.makeStream()
        let saveStarted = AsyncStream<Void>.makeStream()
        let save = AsyncStream<Void>.makeStream()
        var started = false
        var saved = false
        var completions = 0
        let task = controller.runMeetingResummary(operation: {
            started = true
            for await _ in generation.stream { break }
            saveStarted.continuation.yield(())
            for await _ in save.stream { break }
            saved = true
        }, completion: { result in
            #expect((try? result.get()) != nil)
            #expect(saved)
            completions += 1
        })
        // No suspension: the restart check can run before the task's first instruction.
        #expect(!started)
        #expect(controller.permissionRestartActivity.assistant)
        #expect(controller.permissionRestartActivity.blockingMessage != nil)
        generation.continuation.yield(())
        for await _ in saveStarted.stream { break }
        #expect(!saved)
        #expect(controller.permissionRestartActivity.blockingMessage != nil)
        save.continuation.yield(())
        await task.value
        #expect(saved && completions == 1)
        #expect(controller.permissionRestartActivity.blockingMessage == nil)
    }

    @Test("generation and persistence failures release restart protection", arguments: [false, true])
    @MainActor
    func releasesFailedSummary(saveFailure: Bool) async throws {
        let directory = summaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try summaryController(directory: directory)
        var completions = 0
        let task = controller.runMeetingResummary(operation: {
            #expect(controller.permissionRestartActivity.blockingMessage != nil)
            let error = NSError(domain: "synthetic-summary", code: 1)
            if saveFailure { throw MeetingSummaryPersistenceError.failedToSaveSummary(underlying: error) }
            throw error
        }, completion: { result in
            guard case .failure(let error) = result else {
                Issue.record("Failed summary unexpectedly succeeded")
                return
            }
            #expect((error is MeetingSummaryPersistenceError) == saveFailure)
            completions += 1
        })
        #expect(controller.permissionRestartActivity.assistant)
        await task.value
        #expect(completions == 1)
        #expect(controller.permissionRestartActivity.blockingMessage == nil)
    }

    @Test("cancellation releases protection before startup or during generation", arguments: [false, true])
    @MainActor
    func releasesCancelledSummary(afterStartup: Bool) async throws {
        let directory = summaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try summaryController(directory: directory)
        let started = AsyncStream<Void>.makeStream()
        let generation = AsyncStream<Void>.makeStream()
        var completions = 0
        var operationStarted = false
        let task = controller.runMeetingResummary(operation: {
            operationStarted = true
            started.continuation.yield(())
            for await _ in generation.stream { break }
            try Task.checkCancellation()
        }, completion: { result in
            guard case .failure(let error) = result else {
                Issue.record("Cancelled summary unexpectedly succeeded")
                return
            }
            #expect(error is CancellationError)
            completions += 1
        })
        #expect(controller.permissionRestartActivity.assistant)
        if afterStartup {
            for await _ in started.stream { break }
        }
        task.cancel()
        await task.value
        #expect(operationStarted == afterStartup)
        #expect(completions == 1)
        #expect(controller.permissionRestartActivity.blockingMessage == nil)
    }

    @Test("overlapping re-summaries remain protected when one finishes out of order")
    @MainActor
    func protectsOverlappingSummaries() async throws {
        let directory = summaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try summaryController(directory: directory)
        let firstGate = AsyncStream<Void>.makeStream()
        let secondGate = AsyncStream<Void>.makeStream()
        let first = controller.runMeetingResummary(operation: {
            for await _ in firstGate.stream { break }
        }, completion: { _ in })
        let second = controller.runMeetingResummary(operation: {
            for await _ in secondGate.stream { break }
        }, completion: { _ in })
        #expect(controller.permissionRestartActivity.assistant)
        secondGate.continuation.yield(())
        await second.value
        #expect(controller.permissionRestartActivity.blockingMessage != nil)
        firstGate.continuation.yield(())
        await first.value
        #expect(controller.permissionRestartActivity.blockingMessage == nil)
    }

    private func summaryTestDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("summary-restart-\(UUID())")
    }

    @MainActor
    private func summaryController(directory: URL) throws -> MuesliController {
        let store = DictationStore(databaseURL: directory.appendingPathComponent("test.db"))
        try store.migrateIfNeeded()
        return MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store,
            configStore: makeTestConfigStore(supportDirectory: directory)
        )
    }

    @Test("relauncher waits for old process and passes the bundle path literally", arguments: [false, true])
    func waitsForProcessExit(restorePermissions: Bool) throws {
        let oldProcess = Process()
        oldProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldProcess.arguments = ["30"]
        try oldProcess.run()
        defer { if oldProcess.isRunning { oldProcess.terminate(); oldProcess.waitUntilExit() } }

        let path = "/tmp/muesli '$literal' $(no-command) `no-command`.app"
        var arguments = ApplicationRelaunch.arguments(processID: oldProcess.processIdentifier,
                                                     bundlePath: path, restorePermissions: restorePermissions)
        // Exercise the actual wait/argument script without launching any application.
        arguments[1] = arguments[1].replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/printf '%s\\n'")
        let helper = Process()
        let output = Pipe()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = arguments
        helper.standardOutput = output
        try helper.run()
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        #expect(oldProcess.isRunning)
        #expect(helper.isRunning)
        oldProcess.terminate()
        oldProcess.waitUntilExit()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        helper.waitUntilExit()
        #expect(helper.terminationStatus == 0)
        let expected = ["-n", "-a", path] + (restorePermissions ? ["--args", ApplicationRelaunch.permissionsArgument] : [])
        #expect(result.split(separator: "\n").map(String.init) == expected)
    }
}
