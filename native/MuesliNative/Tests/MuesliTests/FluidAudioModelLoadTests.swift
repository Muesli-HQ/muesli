import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("FluidAudio load ownership", .timeLimit(.minutes(1)))
struct FluidAudioModelLoadTests {
    private static let phonon = BackendOption.phonon25.model
    private static let parakeet = BackendOption.parakeetMultilingual.model

    /// Ignores cancellation deliberately, like a Core ML operation already in progress.
    private actor Loader {
        let started = AsyncStream<String>.makeStream()
        let cancelled = AsyncStream<String>.makeStream()
        private var continuations: [String: CheckedContinuation<AsrManager, Error>] = [:]

        func load(_ modelID: String) async throws -> AsrManager {
            let cancellation = cancelled.continuation
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    continuations[modelID] = continuation
                    started.continuation.yield(modelID)
                }
            }, onCancel: {
                cancellation.yield(modelID)
            })
        }

        func complete(_ modelID: String) {
            continuations.removeValue(forKey: modelID)?.resume(returning: AsrManager(config: .default))
        }

        func releaseAll() {
            for continuation in continuations.values { continuation.resume(throwing: CancellationError()) }
            continuations.removeAll()
            started.continuation.finish()
            cancelled.continuation.finish()
        }
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var readyModels: [String] = []
        func record(_ progress: ModelDownloadProgress) {
            lock.lock()
            defer { lock.unlock() }
            if progress.phase == .ready { readyModels.append(progress.modelID) }
        }
        var ready: [String] {
            lock.lock()
            defer { lock.unlock() }
            return readyModels
        }
    }

    @Test("A newer load cancels its predecessor and wins even when the predecessor finishes last")
    func newestLoadWins() async throws {
        let loader = Loader()
        let progress = ProgressLog()
        let transcriber = FluidAudioTranscriber { modelID, _, _ in try await loader.load(modelID) }
        var started = loader.started.stream.makeAsyncIterator()
        var cancelled = loader.cancelled.stream.makeAsyncIterator()
        let older = Task { try await transcriber.loadModels(modelID: Self.phonon, progressSnapshot: { progress.record($0) }) }
        defer { older.cancel(); Task { await loader.releaseAll() } }
        #expect(await started.next() == Self.phonon)
        let newer = Task { try await transcriber.loadModels(modelID: Self.parakeet, progressSnapshot: { progress.record($0) }) }
        defer { newer.cancel() }
        #expect(await started.next() == Self.parakeet)
        #expect(await cancelled.next() == Self.phonon)
        await loader.complete(Self.parakeet)
        try await newer.value
        await loader.complete(Self.phonon)
        await #expect(throws: CancellationError.self) { try await older.value }
        #expect(await transcriber.loadedModelID == Self.parakeet)
        #expect(progress.ready == [Self.parakeet])
    }

    @Test("Completion of a superseded load cannot clear ownership of the pending newer load")
    func staleCompletionCannotHidePendingLoadFromDeletion() async {
        let loader = Loader()
        let progress = ProgressLog()
        let transcriber = FluidAudioTranscriber { modelID, _, _ in try await loader.load(modelID) }
        var started = loader.started.stream.makeAsyncIterator()
        var cancelled = loader.cancelled.stream.makeAsyncIterator()
        let older = Task { try await transcriber.loadModels(modelID: Self.phonon, progressSnapshot: { progress.record($0) }) }
        defer { older.cancel(); Task { await loader.releaseAll() } }
        #expect(await started.next() == Self.phonon)
        let newer = Task { try await transcriber.loadModels(modelID: Self.parakeet, progressSnapshot: { progress.record($0) }) }
        defer { newer.cancel() }
        #expect(await started.next() == Self.parakeet)
        #expect(await cancelled.next() == Self.phonon)
        await loader.complete(Self.phonon)
        await #expect(throws: CancellationError.self) { try await older.value }
        await transcriber.shutdown(ifLoadedModelID: Self.parakeet)
        #expect(await cancelled.next() == Self.parakeet)
        await loader.complete(Self.parakeet)
        await #expect(throws: CancellationError.self) { try await newer.value }
        #expect(await transcriber.loadedModelID == nil)
        #expect(progress.ready.isEmpty)
    }

    @Test("Returning to an already loaded model cancels a different pending load")
    func selectingCachedModelInvalidatesPendingLoad() async throws {
        let loader = Loader()
        let progress = ProgressLog()
        let transcriber = FluidAudioTranscriber { modelID, _, _ in try await loader.load(modelID) }
        var started = loader.started.stream.makeAsyncIterator()
        var cancelled = loader.cancelled.stream.makeAsyncIterator()
        let first = Task { try await transcriber.loadModels(modelID: Self.phonon, progressSnapshot: { progress.record($0) }) }
        defer { first.cancel(); Task { await loader.releaseAll() } }
        #expect(await started.next() == Self.phonon)
        await loader.complete(Self.phonon)
        try await first.value
        let pending = Task { try await transcriber.loadModels(modelID: Self.parakeet, progressSnapshot: { progress.record($0) }) }
        defer { pending.cancel() }
        #expect(await started.next() == Self.parakeet)
        try await transcriber.loadModels(modelID: Self.phonon, progressSnapshot: { progress.record($0) })
        #expect(await cancelled.next() == Self.parakeet)
        await loader.complete(Self.parakeet)
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await transcriber.loadedModelID == Self.phonon)
        #expect(progress.ready == [Self.phonon])
    }

    @Test("Deleting a pending model cancels its preparation and preserves a different loaded manager")
    func deletingPendingModel() async throws {
        let loader = Loader()
        let progress = ProgressLog()
        let transcriber = FluidAudioTranscriber { modelID, _, _ in try await loader.load(modelID) }
        var started = loader.started.stream.makeAsyncIterator()
        var cancelled = loader.cancelled.stream.makeAsyncIterator()
        let first = Task { try await transcriber.loadModels(modelID: Self.phonon, progressSnapshot: { progress.record($0) }) }
        defer { first.cancel(); Task { await loader.releaseAll() } }
        #expect(await started.next() == Self.phonon)
        await loader.complete(Self.phonon)
        try await first.value
        let pending = Task { try await transcriber.loadModels(modelID: Self.parakeet, progressSnapshot: { progress.record($0) }) }
        defer { pending.cancel() }
        #expect(await started.next() == Self.parakeet)
        await transcriber.shutdown(ifLoadedModelID: Self.parakeet)
        #expect(await cancelled.next() == Self.parakeet)
        #expect(await transcriber.loadedModelID == Self.phonon)
        await loader.complete(Self.parakeet)
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await transcriber.loadedModelID == Self.phonon)
        #expect(progress.ready == [Self.phonon])
    }

    @Test("Deleting a loaded or unrelated model leaves a different pending load intact", arguments: [true, false])
    func deletionIsScopedToModel(_ deleteLoaded: Bool) async throws {
        let loader = Loader()
        let transcriber = FluidAudioTranscriber { modelID, _, _ in try await loader.load(modelID) }
        var started = loader.started.stream.makeAsyncIterator()
        let first = Task { try await transcriber.loadModels(modelID: Self.phonon) }
        defer { first.cancel(); Task { await loader.releaseAll() } }
        #expect(await started.next() == Self.phonon)
        await loader.complete(Self.phonon)
        try await first.value
        let pending = Task { try await transcriber.loadModels(modelID: Self.parakeet) }
        defer { pending.cancel() }
        #expect(await started.next() == Self.parakeet)
        await transcriber.shutdown(ifLoadedModelID: deleteLoaded ? Self.phonon : BackendOption.parakeetEnglish.model)
        #expect(await transcriber.loadedModelID == (deleteLoaded ? nil : Self.phonon))
        await loader.complete(Self.parakeet)
        try await pending.value
        #expect(await transcriber.loadedModelID == Self.parakeet)
    }

    @Test("Shutdown cancels a pending load before any manager is loaded")
    func shutdownBeforeFirstLoadCompletes() async {
        let loader = Loader()
        let progress = ProgressLog()
        let transcriber = FluidAudioTranscriber { modelID, _, _ in try await loader.load(modelID) }
        var started = loader.started.stream.makeAsyncIterator()
        var cancelled = loader.cancelled.stream.makeAsyncIterator()
        let pending = Task { try await transcriber.loadModels(modelID: Self.phonon, progressSnapshot: { progress.record($0) }) }
        defer { pending.cancel(); Task { await loader.releaseAll() } }
        #expect(await started.next() == Self.phonon)
        await transcriber.shutdown()
        #expect(await cancelled.next() == Self.phonon)
        await loader.complete(Self.phonon)
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await transcriber.loadedModelID == nil)
        #expect(progress.ready.isEmpty)
    }

    @Test("Cancelling a selection task cancels preparation even if Core ML later returns success")
    func callerCancellationReachesPreparation() async {
        let loader = Loader()
        let progress = ProgressLog()
        let transcriber = FluidAudioTranscriber { modelID, _, _ in try await loader.load(modelID) }
        var started = loader.started.stream.makeAsyncIterator()
        var cancelled = loader.cancelled.stream.makeAsyncIterator()
        let pending = Task { try await transcriber.loadModels(modelID: Self.phonon, progressSnapshot: { progress.record($0) }) }
        defer { pending.cancel(); Task { await loader.releaseAll() } }
        #expect(await started.next() == Self.phonon)
        pending.cancel()
        #expect(await cancelled.next() == Self.phonon)
        await loader.complete(Self.phonon)
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(await transcriber.loadedModelID == nil)
        #expect(progress.ready.isEmpty)
    }
}
