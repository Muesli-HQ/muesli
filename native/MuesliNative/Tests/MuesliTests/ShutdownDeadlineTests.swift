import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Shutdown deadline")
struct ShutdownDeadlineTests {
    @Test("confirmed quit lets AppKit run async shutdown and its fallback deadline")
    func appKitTerminationRunLoop() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let status = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("scripts/test_application_termination.sh").path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        #expect(status == 0)
    }

    @Test("screen discard is covered by the controller shutdown deadline")
    @MainActor
    func screenDiscardDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(directory: directory)
        let stuck = StuckWork()
        let shutdown = Task { @MainActor in
            await controller.shutdown(discardScreenRecording: { await stuck.park() }, cleanupAudioDevices: {})
        }
        let finished = await ShutdownDeadline.run(seconds: 0.2) { await shutdown.value }
        #expect(!finished)
        #expect(controller.shutdownStep == "screen recording discard")
        #expect(!controller.canModifyModelFiles)
        stuck.release()
        await shutdown.value
        #expect(controller.shutdownStep == "finished")
    }

    @Test("blocked audio cleanup leaves MainActor free to handle the deadline")
    @MainActor
    func audioCleanupDeadline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(directory: directory)
        let blocker = DispatchSemaphore(value: 0)
        let started = StuckWork()
        let shutdown = Task { @MainActor in
            await controller.shutdown(discardScreenRecording: {}, cleanupAudioDevices: {
                #expect(!Thread.isMainThread)
                started.release()
                // Bounded only to avoid hanging the test runner if this regresses.
                _ = blocker.wait(timeout: .now() + 3)
            })
        }
        await started.park()
        let finished = await ShutdownDeadline.run(seconds: 0.2) { await shutdown.value }
        #expect(!finished)
        #expect(controller.shutdownStep == "audio device cleanup")
        blocker.signal()
        await shutdown.value
        #expect(controller.shutdownStep == "finished")
    }

    @Test("audio devices are cleaned before shutdown waits for in-flight inference")
    @MainActor
    func cleanupPrecedesInferenceReservation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(directory: directory)
        let entered = StuckWork(), inference = StuckWork(), cleaned = StuckWork(), waiting = StuckWork()
        defer { inference.release() }
        await controller.transcriptionCoordinator.testingInstallASR(
            onWait: { waiting.release() }, prepare: { _ in }, infer: { _, _ in
                entered.release()
                await inference.park() // Simulates native inference ignoring cancellation.
                return .init(text: "meeting", segments: [])
            })
        let transcription = Task {
            try await controller.transcriptionCoordinator.transcribeMeeting(
                at: directory.appendingPathComponent("synthetic.wav"), backend: .parakeetEnglish)
        }
        let started = await ShutdownDeadline.run(seconds: 2) { await entered.park() }
        try #require(started)
        let shutdown = Task { @MainActor in
            await controller.shutdown(discardScreenRecording: {}, cleanupAudioDevices: { cleaned.release() })
        }
        let reachedWait = await ShutdownDeadline.run(seconds: 2) { await waiting.park() }
        #expect(reachedWait)
        let cleanupFinished = await ShutdownDeadline.run(seconds: 0.2) { await cleaned.park() }
        #expect(cleanupFinished, "Device cleanup must not depend on releasing the model reservation")
        #expect(controller.shutdownStep == "transcription coordinator")
        inference.release()
        _ = try await transcription.value
        await shutdown.value
        #expect(controller.shutdownStep == "finished")
    }

    @MainActor
    private func makeController(directory: URL) throws -> MuesliController {
        let store = DictationStore(databaseURL: directory.appendingPathComponent("test.db"))
        try store.migrateIfNeeded()
        return MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: makeTestConfigStore(supportDirectory: directory)
        )
    }

    @Test("work that finishes in time returns at once and reports success")
    func finishesInTime() async {
        let started = Date()
        let finished = await ShutdownDeadline.run(seconds: 5) {}
        #expect(finished)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test("work that never finishes is abandoned at the deadline")
    @MainActor
    func abandonsStuckWork() async {
        let started = Date()
        let stuck = StuckWork()
        let finished = await ShutdownDeadline.run(seconds: 0.2) { @MainActor in
            // Ignores cancellation, like a job blocked on something that never answers.
            await stuck.park()
        }
        // The deadline abandoned the job; resume it so the test leaves no suspended task behind.
        stuck.release()
        #expect(!finished)
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed >= 0.2 && elapsed < 2)
    }

    @Test("work completing after the deadline never reports success")
    func lateWorkCannotWinDelayedTimer() async {
        let finished = await ShutdownDeadline.run(seconds: 0.1) {
            try? await Task.sleep(for: .milliseconds(150))
        }
        #expect(!finished)
    }

    @Test("work released after timeout does not resume twice")
    func resumesOnce() async {
        let work = StuckWork()
        let completed = StuckWork()
        let finished = await ShutdownDeadline.run(seconds: 0.01) {
            await work.park()
            completed.release()
        }
        #expect(!finished)
        // Establish ordering explicitly instead of assuming relative sleeps
        // resume in deadline order on an overloaded CI executor.
        work.release()
        await completed.park()
    }
}

/// Holds a job suspended until the test releases it. A release that arrives first is kept, so
/// a job that parks late returns at once instead of hanging.
private final class StuckWork: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func park() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
