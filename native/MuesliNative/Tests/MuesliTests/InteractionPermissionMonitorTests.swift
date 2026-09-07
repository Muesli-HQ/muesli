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
}
