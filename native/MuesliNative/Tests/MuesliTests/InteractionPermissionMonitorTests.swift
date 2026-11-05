import Foundation
import Testing
@testable import MuesliNativeApp

private final class PermissionReaderThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedOnMainThread = false

    func recordCaptureThread() {
        lock.lock()
        capturedOnMainThread = Thread.isMainThread
        lock.unlock()
    }

    var wasCapturedOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return capturedOnMainThread
    }
}

private final class OutOfOrderPermissionReader: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseFirstRead = DispatchSemaphore(value: 0)
    private let olderSnapshot: InteractionPermissionSnapshot
    private let newerSnapshot: InteractionPermissionSnapshot
    private var readCount = 0
    private var firstReadStarted = false

    init(
        olderSnapshot: InteractionPermissionSnapshot,
        newerSnapshot: InteractionPermissionSnapshot
    ) {
        self.olderSnapshot = olderSnapshot
        self.newerSnapshot = newerSnapshot
    }

    func read() -> InteractionPermissionSnapshot {
        lock.lock()
        let readIndex = readCount
        readCount += 1
        if readIndex == 0 {
            firstReadStarted = true
        }
        lock.unlock()

        if readIndex == 0 {
            releaseFirstRead.wait()
            return olderSnapshot
        }
        return newerSnapshot
    }

    var hasStartedFirstRead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstReadStarted
    }

    func releaseFirst() {
        releaseFirstRead.signal()
    }
}

@MainActor
private final class PermissionSnapshotDeliveryRecorder {
    var snapshots: [InteractionPermissionSnapshot] = []
    var deliveredOnMainThread = false

    func record(_ snapshot: InteractionPermissionSnapshot) {
        snapshots.append(snapshot)
        deliveredOnMainThread = Thread.isMainThread
    }
}

@Suite("Interaction permission monitor")
struct InteractionPermissionMonitorTests {
    private let snapshot = InteractionPermissionSnapshot(
        microphone: true,
        accessibility: false,
        inputMonitoring: true,
        screenRecording: false
    )

    @Test("captures off-main and delivers changes on the main actor")
    @MainActor
    func capturesOffMainAndDeliversOnMainActor() async {
        let probe = PermissionReaderThreadProbe()
        let recorder = PermissionSnapshotDeliveryRecorder()
        let expectedSnapshot = snapshot
        let monitor = InteractionPermissionMonitor(
            readSnapshot: {
                probe.recordCaptureThread()
                return expectedSnapshot
            },
            onChange: { snapshot in
                recorder.record(snapshot)
            }
        )

        await monitor.refresh()

        #expect(probe.wasCapturedOnMainThread == false)
        #expect(recorder.deliveredOnMainThread)
        #expect(recorder.snapshots == [expectedSnapshot])
    }

    @Test("does not republish an unchanged snapshot")
    @MainActor
    func suppressesUnchangedSnapshots() async {
        let recorder = PermissionSnapshotDeliveryRecorder()
        let expectedSnapshot = snapshot
        let monitor = InteractionPermissionMonitor(
            readSnapshot: { expectedSnapshot },
            onChange: { snapshot in
                recorder.record(snapshot)
            }
        )

        await monitor.refresh()
        await monitor.refresh()

        #expect(recorder.snapshots == [expectedSnapshot])
    }

    @Test("discards an older capture that completes after a newer capture")
    @MainActor
    func discardsOutOfOrderCapture() async {
        let olderSnapshot = InteractionPermissionSnapshot(
            microphone: false,
            accessibility: false,
            inputMonitoring: false,
            screenRecording: false
        )
        let newerSnapshot = snapshot
        let reader = OutOfOrderPermissionReader(
            olderSnapshot: olderSnapshot,
            newerSnapshot: newerSnapshot
        )
        let recorder = PermissionSnapshotDeliveryRecorder()
        let monitor = InteractionPermissionMonitor(
            readSnapshot: { reader.read() },
            onChange: { snapshot in
                recorder.record(snapshot)
            }
        )

        let firstRefresh = Task { await monitor.refresh() }
        let firstReadStarted = await waitUntil { reader.hasStartedFirstRead }
        #expect(firstReadStarted)
        guard firstReadStarted else {
            reader.releaseFirst()
            await firstRefresh.value
            return
        }

        let secondRefresh = Task { await monitor.refresh() }
        await secondRefresh.value
        reader.releaseFirst()
        await firstRefresh.value

        #expect(recorder.snapshots == [newerSnapshot])
    }

    @Test("maps interaction permissions into the shared onboarding snapshot")
    func mapsToOnboardingSnapshot() {
        #expect(snapshot.onboardingSnapshot == OnboardingPermissionSnapshot(
            microphone: true,
            accessibility: false,
            inputMonitoring: true,
            systemAudio: false,
            screenRecording: false
        ))
    }

    @Test("Recording permission checks are scoped to capture and pasting, not hotkeys or screen history")
    func recordingPermissions() {
        var permissions = OnboardingPermissionSnapshot(microphone: false, accessibility: false,
            inputMonitoring: false, systemAudio: false, screenRecording: false)
        #expect(FeaturePermission.missingForRecording(permissions, pastesText: false) == .microphone)
        permissions.microphone = true
        #expect(FeaturePermission.missingForRecording(permissions, pastesText: false) == nil)
        #expect(FeaturePermission.missingForRecording(permissions, pastesText: true) == .accessibility)
        permissions.accessibility = true
        #expect(FeaturePermission.missingForRecording(permissions, pastesText: true) == nil)
        #expect(FeaturePermission.missingForScreenHistory(screen: true, accessibility: false) == .accessibility)
        #expect(FeaturePermission.missingForScreenHistory(screen: false, accessibility: true) == .screenRecording)
        #expect(FeaturePermission.missingForScreenHistory(screen: true, accessibility: true) == nil)
    }

    @Test("A failed System Audio request can observe a later grant on return from Settings")
    @MainActor
    func systemAudioGrantAfterDenial() async {
        let check = SystemAudioPermissionCheck(read: { true }, requestAccess: { false })
        var results: [Bool] = []
        check.check(request: true) { results.append($0) }
        #expect(await waitUntil { !check.isChecking })
        #expect(results == [false])
        check.check { results.append($0) }
        #expect(await waitUntil { !check.isChecking })
        #expect(results == [false, true])
    }

    @Test("A Grant click during a background read is preserved and coalesced", arguments: [false, true])
    @MainActor
    func systemAudioGrantDuringRead(alreadyGranted: Bool) async {
        let read = PermissionCheckContinuation()
        let request = PermissionCheckContinuation()
        await request.finish(true)
        let check = SystemAudioPermissionCheck(read: { await read.wait() }, requestAccess: { await request.wait() })
        var backgroundResults: [Bool] = []
        var grantResults: [Bool] = []
        check.check { backgroundResults.append($0) }
        check.check(request: true) { grantResults.append($0) }
        check.check(request: true) { grantResults.append($0) }
        #expect(check.isChecking)
        #expect(await request.calls == 0)
        await read.finish(alreadyGranted)
        #expect(await waitUntil { !check.isChecking })
        #expect(backgroundResults.isEmpty)
        #expect(grantResults == [true])
        #expect(await request.calls == (alreadyGranted ? 0 : 1))
    }

    @Test("Leaving setup discards a queued Grant click without requesting access")
    @MainActor
    func systemAudioCancelQueuedGrant() async {
        let read = PermissionCheckContinuation()
        let request = PermissionCheckContinuation()
        await request.finish(true)
        let check = SystemAudioPermissionCheck(read: { await read.wait() }, requestAccess: { await request.wait() })
        var results: [Bool] = []
        check.check { results.append($0) }
        check.check(request: true) { results.append($0) }
        check.cancel()
        await read.finish(false)
        check.check { results.append($0) }
        #expect(await waitUntil { !check.isChecking })
        #expect(results == [false])
        #expect(await request.calls == 0)
    }

    @Test("Leaving permission setup cancels delivery and permits another attempt")
    @MainActor
    func systemAudioCancelledCompletion() async {
        let gate = PermissionCheckContinuation()
        let check = SystemAudioPermissionCheck(read: { true }, requestAccess: { await gate.wait() })
        var results: [Bool] = []
        check.check(request: true) { results.append($0) }
        check.check(request: true) { results.append($0) }
        #expect(check.isChecking)
        check.cancel()
        #expect(!check.isChecking)
        check.check { results.append($0) }
        #expect(await waitUntil { results == [true] })
        await gate.finish(false)
        for _ in 0..<10 { await Task.yield() }
        #expect(results == [true])
        #expect(!check.isChecking)
        #expect(await gate.calls <= 1)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() {
                return true
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private actor PermissionCheckContinuation {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    private(set) var calls = 0
    func wait() async -> Bool {
        calls += 1
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: Bool) {
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}
