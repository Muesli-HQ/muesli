import CoreAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("Microphone activity isolation")
struct MicrophoneActivityMonitorTests {
    @Test("blocked microphone listener installation cannot block UI stop")
    func blockedInstallation() async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.mic-listener.blocked")
        let observer = FakeMicrophoneObserver()
        observer.onStart = {
            #expect(!Thread.isMainThread)
            entered.continuation.yield(())
            #expect(release.wait(timeout: .now() + 3) == .success)
            observer.onActivityChanged?(.init(deviceID: 42, isActive: true))
        }
        let monitor = MicrophoneActivityMonitor(queue: queue, observer: observer)
        var changes = 0
        monitor.onActivityChanged = { changes += 1 }
        monitor.start()
        for await _ in entered.stream { break }
        monitor.stop()
        #expect(monitor.deviceID == 0)
        release.signal()
        await drain(queue)
        try await Task.sleep(for: .milliseconds(20))
        #expect(changes == 0)
        #expect(monitor.deviceID == 0)
    }

    @Test("retired microphone listeners cannot update a restarted monitor")
    func staleListener() async throws {
        let queue = DispatchQueue(label: "test.mic-listener.generation")
        let observer = FakeMicrophoneObserver()
        let monitor = MicrophoneActivityMonitor(queue: queue, observer: observer)
        monitor.start()
        await drain(queue)
        let stale = queue.sync { observer.onActivityChanged }
        monitor.stop()
        monitor.start()
        await drain(queue)
        queue.async { stale?(.init(deviceID: 91, isActive: true)) }
        await drain(queue)
        try await Task.sleep(for: .milliseconds(20))
        #expect(monitor.deviceID == 0)
        let updates = AsyncStream<Void>.makeStream()
        monitor.onActivityChanged = { updates.continuation.yield(()) }
        queue.async { observer.onActivityChanged?(.init(deviceID: 82, isActive: true)) }
        for await _ in updates.stream { break }
        #expect(monitor.deviceID == 82)
        #expect(monitor.snapshot.isActive == true)
        monitor.stop()
        await drain(queue)
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

private final class FakeMicrophoneObserver: MicrophoneActivityObserving, @unchecked Sendable {
    var onActivityChanged: ((MicrophoneActivitySnapshot) -> Void)?
    var onStart: (() -> Void)?
    func start() { onStart?() }
    func stop() { onActivityChanged = nil }
}
