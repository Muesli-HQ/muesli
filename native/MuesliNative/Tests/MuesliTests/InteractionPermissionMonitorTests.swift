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
