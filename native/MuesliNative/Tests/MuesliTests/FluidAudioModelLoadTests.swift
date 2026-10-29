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
        private(set) var loadCount = 0

        func load(_ modelID: String) async throws -> AsrManager {
            loadCount += 1
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

    private final class TranscriberFactory: @unchecked Sendable {
        private let lock = NSLock()
        private var transcribers: [FluidAudioTranscriber] = []
        private let loader: Loader
        init(loader: Loader) { self.loader = loader }
        func make() -> FluidAudioTranscriber {
            let transcriber = FluidAudioTranscriber { [loader] modelID, _, _, _ in
                try await loader.load(modelID)
            }
            lock.lock()
            transcribers.append(transcriber)
            lock.unlock()
            return transcriber
        }
        var instances: [FluidAudioTranscriber] {
            lock.lock()
            defer { lock.unlock() }
            return transcribers
        }
    }

    @Test("Library validation is serialized without blocking selection or replacing its runtime")
    func libraryDownloadsAreIndependentOfSelection() async throws {
        let loader = Loader()
        let factory = TranscriberFactory(loader: loader)
        let coordinator = TranscriptionCoordinator(fluidAudioTranscriberFactory: { factory.make() },
            libraryModelPreparation: ModelLibraryPreparation(), libraryModelDownload: { _, _, _ in })
        var started = loader.started.stream.makeAsyncIterator()
        let selected = Task {
            try await coordinator.preloadRequired(backend: .phonon25, includeMeetingHelpers: false)
        }
        defer { selected.cancel(); Task { await loader.releaseAll() } }
        #expect(await started.next() == Self.phonon)
        await loader.complete(Self.phonon)
        try await selected.value
        let first = Task {
            try await coordinator.preloadRequired(backend: .parakeetMultilingual,
                includeMeetingHelpers: false, meetingHelperTrigger: .modelLibrary)
        }
        defer { first.cancel() }
        #expect(await started.next() == Self.parakeet)
        let queued = AsyncStream<Void>.makeStream()
        let second = Task {
            try await coordinator.preloadRequired(backend: .parakeetEnglish,
                includeMeetingHelpers: false, meetingHelperTrigger: .modelLibrary,
                progressSnapshot: {
                    if $0.message?.hasPrefix("Waiting to prepare") == true { queued.continuation.yield() }
                })
        }
        defer { second.cancel(); queued.continuation.finish() }
        for await _ in queued.stream { break }
        #expect(await loader.loadCount == 2) // Selected model plus first library validation.
        // Selection uses the active runtime and must not wait for the library slot.
        let switchModel = Task {
            try await coordinator.preloadRequired(backend: .parakeetRedux, includeMeetingHelpers: false)
        }
        defer { switchModel.cancel() }
        #expect(await started.next() == BackendOption.parakeetRedux.model)
        await loader.complete(BackendOption.parakeetRedux.model)
        try await switchModel.value
        await loader.complete(Self.parakeet)
        try await first.value
        #expect(await started.next() == BackendOption.parakeetEnglish.model)
        await loader.complete(BackendOption.parakeetEnglish.model)
        try await second.value
        let instances = factory.instances
        #expect(instances.count == 3)
        #expect(await instances[0].loadedModelID == BackendOption.parakeetRedux.model)
        #expect(await instances[1].loadedModelID == nil)
        #expect(await instances[2].loadedModelID == nil)
    }

    @Test("Same-model callers share preparation and either caller can cancel independently", arguments: [0, 1, 2])
    func sameModelPreparationIsShared(_ cancelledCaller: Int) async throws {
        let loader = Loader()
        let firstProgress = ProgressLog()
        let secondProgress = ProgressLog()
        let joined = AsyncStream<Void>.makeStream()
        let transcriber = FluidAudioTranscriber { modelID, _, _, _ in try await loader.load(modelID) }
        var started = loader.started.stream.makeAsyncIterator()
        let first = Task {
            try await transcriber.loadModels(modelID: Self.phonon,
                progressSnapshot: { firstProgress.record($0) })
        }
        defer { first.cancel(); joined.continuation.finish(); Task { await loader.releaseAll() } }
        #expect(await started.next() == Self.phonon)
        let second = Task {
            try await transcriber.loadModels(modelID: Self.phonon, progressSnapshot: {
                if $0.phase == .preparing { joined.continuation.yield() }
                secondProgress.record($0)
            })
        }
        defer { second.cancel() }
        for await _ in joined.stream { break }
        if cancelledCaller == 1 { first.cancel() }
        if cancelledCaller == 2 { second.cancel() }
        await loader.complete(Self.phonon)
        if cancelledCaller == 1 {
            await #expect(throws: CancellationError.self) { try await first.value }
        } else {
            try await first.value
        }
        if cancelledCaller == 2 {
            await #expect(throws: CancellationError.self) { try await second.value }
        } else {
            try await second.value
        }
        #expect(await loader.loadCount == 1)
        #expect(await transcriber.loadedModelID == Self.phonon)
        #expect(firstProgress.ready == (cancelledCaller == 1 ? [] : [Self.phonon]))
        #expect(secondProgress.ready == (cancelledCaller == 2 ? [] : [Self.phonon]))
    }

    @Test("A newer load cancels its predecessor and wins even when the predecessor finishes last")
    func newestLoadWins() async throws {
        let loader = Loader()
        let progress = ProgressLog()
        let transcriber = FluidAudioTranscriber { modelID, _, _, _ in try await loader.load(modelID) }
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
        let transcriber = FluidAudioTranscriber { modelID, _, _, _ in try await loader.load(modelID) }
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
        let transcriber = FluidAudioTranscriber { modelID, _, _, _ in try await loader.load(modelID) }
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
        let transcriber = FluidAudioTranscriber { modelID, _, _, _ in try await loader.load(modelID) }
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
        let transcriber = FluidAudioTranscriber { modelID, _, _, _ in try await loader.load(modelID) }
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
        let transcriber = FluidAudioTranscriber { modelID, _, _, _ in try await loader.load(modelID) }
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
        let transcriber = FluidAudioTranscriber { modelID, _, _, _ in try await loader.load(modelID) }
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
