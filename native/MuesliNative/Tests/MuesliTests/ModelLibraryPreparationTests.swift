import Testing
@testable import MuesliNativeApp

@Suite("Library preparation concurrency", .timeLimit(.minutes(1)))
struct ModelLibraryPreparationTests {
    private enum Failure: Error { case preparation }

    /// Explicit completion signals keep these tests independent of timing or polling.
    private actor Stage {
        let started = AsyncStream<String>.makeStream()
        private var continuations: [String: CheckedContinuation<Void, Error>] = [:]
        private(set) var active = 0
        private(set) var maximumActive = 0
        private(set) var calls: [String] = []

        func run(_ id: String) async throws {
            active += 1
            maximumActive = max(maximumActive, active)
            calls.append(id)
            defer { active -= 1 }
            try await withCheckedThrowingContinuation { continuation in
                continuations[id] = continuation
                started.continuation.yield(id)
            }
        }

        func complete(_ id: String, failing: Bool = false) {
            let continuation = continuations.removeValue(forKey: id)
            if failing { continuation?.resume(throwing: Failure.preparation) }
            else { continuation?.resume() }
        }

        func releaseAll() {
            for continuation in continuations.values { continuation.resume(throwing: CancellationError()) }
            continuations.removeAll()
            started.continuation.finish()
        }
    }

    @Test("Downloads overlap but preparation stays at one, releasing the slot after success or error", arguments: [false, true])
    func parallelDownloadsSerialPreparation(_ firstFails: Bool) async throws {
        let queue = ModelLibraryPreparation()
        let downloads = Stage()
        let preparation = Stage()
        let queued = AsyncStream<Void>.makeStream()
        var downloadStarted = downloads.started.stream.makeAsyncIterator()
        var prepareStarted = preparation.started.stream.makeAsyncIterator()
        let first = Task {
            try await queue.run(download: { try await downloads.run("A") },
                prepare: { try await preparation.run("A") })
        }
        defer {
            first.cancel(); queued.continuation.finish()
            Task { await downloads.releaseAll(); await preparation.releaseAll() }
        }
        #expect(await downloadStarted.next() == "A")
        let second = Task {
            try await queue.run(download: { try await downloads.run("B") },
                onQueued: { queued.continuation.yield() },
                prepare: { try await preparation.run("B") })
        }
        defer { second.cancel() }
        #expect(await downloadStarted.next() == "B")
        #expect(await downloads.maximumActive == 2)
        await downloads.complete("A")
        #expect(await prepareStarted.next() == "A")
        await downloads.complete("B")
        for await _ in queued.stream { break }
        #expect(await preparation.calls == ["A"])
        await preparation.complete("A", failing: firstFails)
        if firstFails {
            await #expect(throws: Failure.self) { try await first.value }
        } else {
            try await first.value
        }
        #expect(await prepareStarted.next() == "B")
        await preparation.complete("B")
        try await second.value
        #expect(await preparation.maximumActive == 1)
        #expect(await preparation.active == 0)
    }

    @Test("Cancelling a queued preparation does not load it or consume the next slot")
    func queuedCancellation() async throws {
        let queue = ModelLibraryPreparation()
        let preparation = Stage()
        let queued = AsyncStream<Void>.makeStream()
        var started = preparation.started.stream.makeAsyncIterator()
        var waiting = queued.stream.makeAsyncIterator()
        let first = Task { try await queue.run(download: {}, prepare: { try await preparation.run("A") }) }
        defer { first.cancel(); queued.continuation.finish(); Task { await preparation.releaseAll() } }
        #expect(await started.next() == "A")
        let cancelled = Task {
            try await queue.run(download: {}, onQueued: { queued.continuation.yield() },
                prepare: { try await preparation.run("cancelled") })
        }
        defer { cancelled.cancel() }
        _ = await waiting.next()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let next = Task {
            try await queue.run(download: {}, onQueued: { queued.continuation.yield() },
                prepare: { try await preparation.run("B") })
        }
        defer { next.cancel() }
        _ = await waiting.next()
        #expect(await preparation.calls == ["A"])
        await preparation.complete("A")
        try await first.value
        #expect(await started.next() == "B")
        await preparation.complete("B")
        try await next.value
        #expect(await preparation.calls == ["A", "B"])
        #expect(await preparation.maximumActive == 1)
    }

    @Test("Cancellation of active uncancellable work holds the slot until it unwinds")
    func activeCancellationHoldsSlot() async throws {
        let queue = ModelLibraryPreparation()
        let preparation = Stage()
        let queued = AsyncStream<Void>.makeStream()
        var started = preparation.started.stream.makeAsyncIterator()
        let first = Task { try await queue.run(download: {}, prepare: { try await preparation.run("A") }) }
        defer { first.cancel(); queued.continuation.finish(); Task { await preparation.releaseAll() } }
        #expect(await started.next() == "A")
        let second = Task {
            try await queue.run(download: {}, onQueued: { queued.continuation.yield() },
                prepare: { try await preparation.run("B") })
        }
        defer { second.cancel() }
        for await _ in queued.stream { break }
        first.cancel()
        #expect(await preparation.calls == ["A"])
        await preparation.complete("A")
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await started.next() == "B")
        await preparation.complete("B")
        try await second.value
        #expect(await preparation.maximumActive == 1)
    }

    @Test("A cancelled request does not download or prepare")
    func alreadyCancelledRequest() async {
        let queue = ModelLibraryPreparation()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await queue.run(download: { Issue.record("Cancelled download started") },
                prepare: { Issue.record("Cancelled preparation started") })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
