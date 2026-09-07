import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Camera activity isolation")
@MainActor
struct CameraActivityMonitorTests {
    @Test("blocked camera discovery does not block stop or publish after stop")
    func blockedDiscoveryDoesNotBlockUI() async throws {
        let queue = DispatchQueue(label: "test.camera.blocked")
        let observer = FakeCameraObserver()
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        observer.onStart = {
            #expect(!Thread.isMainThread)
            entered.continuation.yield(())
            _ = release.wait(timeout: .now() + 5)
            observer.onCameraStateChanged?(true)
        }
        let monitor = CameraActivityMonitor(observer: observer, queue: queue)
        var updates = [Bool]()
        monitor.onCameraStateChanged = { updates.append($0) }
        monitor.start()
        for await _ in entered.stream { break }
        // This must return even while the driver is blocked on its worker.
        monitor.stop()
        #expect(!monitor.isCameraActive)
        release.signal()
        await drain(queue)
        try await Task.sleep(for: .milliseconds(20))
        #expect(updates.isEmpty)
        #expect(!monitor.isCameraActive)
        #expect(queue.sync { observer.stopCount } == 1)
    }

    @Test("camera activity reaches main actor and start is idempotent")
    func publishesCameraActivity() async {
        let queue = DispatchQueue(label: "test.camera.activity")
        let observer = FakeCameraObserver()
        observer.onStart = { observer.onCameraStateChanged?(true) }
        let monitor = CameraActivityMonitor(observer: observer, queue: queue)
        let updates = AsyncStream<Bool>.makeStream()
        monitor.onCameraStateChanged = { active in
            #expect(Thread.isMainThread)
            updates.continuation.yield(active)
        }
        monitor.start()
        monitor.start()
        var iterator = updates.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
        #expect(monitor.isCameraActive)
        #expect(queue.sync { observer.startCount } == 1)
        monitor.stop()
        await drain(queue)
    }

    @Test("old camera listener cannot overwrite a restarted monitor")
    func ignoresPreviousGeneration() async throws {
        let queue = DispatchQueue(label: "test.camera.generation")
        let observer = FakeCameraObserver()
        let monitor = CameraActivityMonitor(observer: observer, queue: queue)
        monitor.start()
        await drain(queue)
        let oldCallback = queue.sync { observer.onCameraStateChanged }
        monitor.stop()
        monitor.start()
        await drain(queue)
        queue.async { oldCallback?(true) }
        await drain(queue)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!monitor.isCameraActive)
        let updates = AsyncStream<Bool>.makeStream()
        monitor.onCameraStateChanged = { updates.continuation.yield($0) }
        queue.async { observer.onCameraStateChanged?(true) }
        var iterator = updates.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
        monitor.stop()
        await drain(queue)
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

// Configured before start; thereafter accessed only on the injected queue.
private final class FakeCameraObserver: CameraActivityObserving, @unchecked Sendable {
    var onCameraStateChanged: ((Bool) -> Void)?
    var onStart: (() -> Void)?
    var startCount = 0
    var stopCount = 0
    func start() {
        startCount += 1
        onStart?()
    }
    func stop() { stopCount += 1 }
    func refresh() {}
}
