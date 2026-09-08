import Foundation
import Testing
@testable import MuesliNativeApp

/// Intentionally ignores cancellation, like an in-flight model download/compilation can.
private actor BodhanLifecycleGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

@available(macOS 15, *)
private final class StubBodhanRuntime: BodhanRuntime {
    let warmupGate: BodhanLifecycleGate?
    init(warmupGate: BodhanLifecycleGate? = nil) { self.warmupGate = warmupGate }
    func warmup(mixedScript: Bool) async throws { await warmupGate?.suspend() }
    func transcribe(samples: [Float], language: String?, mixedScript: Bool) throws -> BodhanCoreML.Result {
        throw NSError(domain: "BodhanLifecycleTests", code: 1)
    }
}

@Suite("Bodhan load and warmup lifecycle", .timeLimit(.minutes(1)))
struct BodhanLifecycleTests {
    @Test("Shutdown prevents an in-flight load from restoring runtime state")
    func shutdownDuringLoad() async {
        guard #available(macOS 15, *) else { return }
        let loadGate = BodhanLifecycleGate()
        let transcriber = BodhanTranscriber { _, _, _ in
            await loadGate.suspend()
            return StubBodhanRuntime()
        }
        let preparing = Task { try await transcriber.prepare(modelID: BodhanModel.core.rawValue) }
        await loadGate.waitUntilEntered()
        await transcriber.shutdown(ifLoadedModelID: BodhanModel.core.rawValue)
        await loadGate.release()
        await expectCancellation(preparing)
        await expectUnloaded(transcriber)
    }

    @Test("Shutdown prevents an in-flight warmup from restoring readiness")
    func shutdownDuringWarmup() async {
        guard #available(macOS 15, *) else { return }
        let warmupGate = BodhanLifecycleGate()
        let transcriber = BodhanTranscriber { _, _, _ in StubBodhanRuntime(warmupGate: warmupGate) }
        let preparing = Task { try await transcriber.prepare(modelID: BodhanModel.flex.rawValue) }
        await warmupGate.waitUntilEntered()
        let warming = await transcriber.lifecycleState
        #expect(warming.loadedModel == .flex)
        #expect(warming.hasRuntime && !warming.hasCompletedWarmup)
        await transcriber.shutdown(ifLoadedModelID: BodhanModel.flex.rawValue)
        await warmupGate.release()
        await expectCancellation(preparing)
        await expectUnloaded(transcriber)
    }

    @Test("Stale completion cannot overwrite a newer prepared model", arguments: [false, true])
    func replacementPreservesNewRuntime(duringWarmup: Bool) async throws {
        guard #available(macOS 15, *) else { return }
        let gate = BodhanLifecycleGate()
        let transcriber = BodhanTranscriber { selected, _, _ in
            if selected == .core {
                if !duringWarmup { await gate.suspend() }
                return StubBodhanRuntime(warmupGate: duringWarmup ? gate : nil)
            }
            return StubBodhanRuntime()
        }
        let oldPreparation = Task { try await transcriber.prepare(modelID: BodhanModel.core.rawValue) }
        await gate.waitUntilEntered()
        try await transcriber.prepare(modelID: BodhanModel.flexInt8.rawValue)
        await gate.release()
        await expectCancellation(oldPreparation)
        let state = await transcriber.lifecycleState
        #expect(state.loadedModel == .flexInt8)
        #expect(state.loadingModel == nil)
        #expect(state.hasRuntime && state.hasCompletedWarmup)
    }

    @Test("Deleting another variant preserves loading and loaded selections")
    func conditionalShutdownPreservesOtherModel() async throws {
        guard #available(macOS 15, *) else { return }
        let gate = BodhanLifecycleGate()
        let transcriber = BodhanTranscriber { _, _, _ in
            await gate.suspend()
            return StubBodhanRuntime()
        }
        let preparing = Task { try await transcriber.prepare(modelID: BodhanModel.coreInt8.rawValue) }
        await gate.waitUntilEntered()
        await transcriber.shutdown(ifLoadedModelID: BodhanModel.core.rawValue)
        let loading = await transcriber.lifecycleState
        #expect(loading.loadingModel == .coreInt8)
        await gate.release()
        try await preparing.value
        await transcriber.shutdown(ifLoadedModelID: BodhanModel.core.rawValue)
        let loaded = await transcriber.lifecycleState
        #expect(loaded.loadedModel == .coreInt8)
        #expect(loaded.hasRuntime && loaded.hasCompletedWarmup)
        await transcriber.shutdown(ifLoadedModelID: BodhanModel.coreInt8.rawValue)
        await expectUnloaded(transcriber)
    }

    private func expectCancellation(_ task: Task<Void, Error>) async {
        do {
            try await task.value
            Issue.record("Stale preparation unexpectedly succeeded")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @available(macOS 15, *)
    private func expectUnloaded(_ transcriber: BodhanTranscriber) async {
        let state = await transcriber.lifecycleState
        #expect(state.loadedModel == nil)
        #expect(state.loadingModel == nil)
        #expect(!state.hasRuntime)
        #expect(!state.hasCompletedWarmup)
    }
}
