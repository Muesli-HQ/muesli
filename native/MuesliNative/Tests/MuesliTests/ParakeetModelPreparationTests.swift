import Testing
import MuesliCore

@Suite("Parakeet model preparation")
struct ParakeetModelPreparationTests {
    private actor Trace {
        var events: [String] = []
        func append(_ value: String) { events.append(value) }
    }

    private enum WarmupError: Error, Equatable { case failed }

    @Test("GPU preparation cannot publish readiness before warmup completes", .timeLimit(.minutes(1)))
    func waitsForGPUWarmup() async throws {
        let started = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let trace = Trace()
        let task = Task {
            let model = try await ParakeetRuntimePolicy.prepareLoadedModel(
                "candidate", for: ParakeetRuntimePolicy.phonon25ModelID
            ) { candidate, samples in
                #expect(candidate == "candidate")
                #expect(samples.count == 16_000)
                #expect(samples.allSatisfy { $0 == 0 })
                await trace.append("warming")
                started.continuation.yield()
                for await _ in resume.stream { break }
                await trace.append("warmed")
            }
            await trace.append("ready")
            return model
        }
        defer {
            started.continuation.finish()
            resume.continuation.finish()
            task.cancel()
        }
        for await _ in started.stream { break }
        #expect(await trace.events == ["warming"])
        resume.continuation.yield()
        #expect(try await task.value == "candidate")
        #expect(await trace.events == ["warming", "warmed", "ready"])
    }

    @Test("Existing non-GPU models do not run a silent inference", arguments: [
        "FluidInference/parakeet-tdt-0.6b-v2-coreml",
        "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        "FluidInference/parakeet-redux-coreml",
        "unknown-model",
    ])
    func otherModelsSkipWarmup(_ modelID: String) async throws {
        let model = try await ParakeetRuntimePolicy.prepareLoadedModel("candidate", for: modelID) { _, _ in
            Issue.record("Unexpected warmup for \(modelID)")
        }
        #expect(model == "candidate")
    }

    @Test("Warmup failure does not return a ready model")
    func warmupFailurePropagates() async {
        await #expect(throws: WarmupError.failed) {
            try await ParakeetRuntimePolicy.prepareLoadedModel("candidate", for: ParakeetRuntimePolicy.phonon25ModelID) { _, _ in
                throw WarmupError.failed
            }
        }
    }

    @Test("Cancellation before or during warmup prevents readiness", arguments: [false, true])
    func cancellationPreventsReadiness(_ duringWarmup: Bool) async {
        let task = Task {
            if !duringWarmup { withUnsafeCurrentTask { $0?.cancel() } }
            return try await ParakeetRuntimePolicy.prepareLoadedModel("candidate", for: ParakeetRuntimePolicy.phonon25ModelID) { _, _ in
                #expect(duringWarmup)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
