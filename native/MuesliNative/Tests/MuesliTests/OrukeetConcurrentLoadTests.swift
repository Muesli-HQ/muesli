import FluidAudio
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Concurrent FluidAudio model selection")
struct OrukeetConcurrentLoadTests {
    @Test("Overlapping loads of one selection both succeed", arguments: ["orukeet", "v2", "v3"], [false, true])
    func sameSelectionSurvivesBothCompletionOrders(model: String, secondFinishesFirst: Bool) async throws {
        let calls = LoadAttempts()
        let started = [LoadGate(), LoadGate()]
        let finish = [LoadGate(), LoadGate()]
        let transcriber = FluidAudioTranscriber(managerLoader: { _, _, _ in
            let index = await calls.next()
            await started[index].open()
            await finish[index].wait()
            return AsrManager(config: .default)
        })
        let first = Task { try await load(model, using: transcriber) }
        await started[0].wait()
        let second = Task { try await load(model, using: transcriber) }
        await started[1].wait()

        let earlier = secondFinishesFirst ? 1 : 0
        await finish[earlier].open()
        try await (secondFinishesFirst ? second : first).value
        // A cached third request must not invalidate the remaining in-flight caller.
        try await load(model, using: transcriber)
        await finish[1 - earlier].open()
        try await (secondFinishesFirst ? first : second).value
        #expect(await calls.count == 2)
    }

    @Test("Canceling one same-selection caller leaves the other active", arguments: ["orukeet", "v2", "v3"], [false, true])
    func sameSelectionCancellationIsIndependent(model: String, cancelSecond: Bool) async throws {
        let calls = LoadAttempts()
        let started = [LoadGate(), LoadGate()]
        let finish = [LoadGate(), LoadGate()]
        let transcriber = FluidAudioTranscriber(managerLoader: { _, _, _ in
            let index = await calls.next()
            await started[index].open()
            await finish[index].wait()
            return AsrManager(config: .default)
        })
        let first = Task { try await load(model, using: transcriber) }
        await started[0].wait()
        let second = Task { try await load(model, using: transcriber) }
        await started[1].wait()
        let canceled = cancelSecond ? second : first
        let remaining = cancelSecond ? first : second
        canceled.cancel()
        await finish[cancelSecond ? 1 : 0].open()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        await finish[cancelSecond ? 0 : 1].open()
        try await remaining.value
        try await load(model, using: transcriber)
        #expect(await calls.count == 2)
    }

    private func load(_ model: String, using transcriber: FluidAudioTranscriber) async throws {
        if model == "orukeet" {
            try await transcriber.loadOrukeet()
        } else {
            try await transcriber.loadModels(version: model == "v2" ? .v2 : .v3)
        }
    }
}

private actor LoadAttempts {
    private(set) var count = 0

    func next() -> Int {
        defer { count += 1 }
        return count
    }
}

private actor LoadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
