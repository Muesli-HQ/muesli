import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Buffered transcription")
struct BufferedTranscriptionSessionTests {
    @Test("finish flushes short audio and preserves revisable punctuation")
    func shortFinal() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in
            try .aligned(text: "Hello, café!", words: [
                .init(text: "Hello,", start: 0, end: 0.2),
                .init(text: "café!", start: 0.3, end: 0.8)
            ])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        await session.finish()
        #expect(output.values.last?.text == "Hello, café!")
        #expect(output.failures == 0)
        #expect(session.diagnostics.receivedSamples == 16_000)
        #expect(session.diagnostics.decodeCount == 1)
        #expect(session.diagnostics.revision == 1)
        #expect(session.diagnostics.closed)
    }

    @Test("continuous audio rolls over using times without deleting repeated words", arguments: ["go", "café", "привет", "مرحبا", "你好"])
    func longRepeatedSpeech(word: String) async {
        let output = BufferedPreviewOutput()
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 6 * 16_000
        config.rightContextSamples = 2 * 16_000
        config.maximumBufferedSamples = 40 * 16_000
        let session = BufferedTranscriptionSession(configuration: config, decode: { samples in
            // PCM encodes absolute sample position, allowing an oracle with
            // word timestamps independent of where the rolling window starts.
            let base = Double(samples[0]) / 16_000
            let end = base + Double(samples.count) / 16_000
            let words: [BufferedTranscriptionWord] = (0..<30).compactMap { index in
                let start = Double(index) + 0.1
                let finish = Double(index) + 0.7
                guard start >= base, finish <= end else { return nil }
                return .init(text: word, start: start - base, end: finish - base)
            }
            let separator = word == "你好" ? "" : " "
            return try .aligned(text: words.map(\.text).joined(separator: separator), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        session.enqueue((0..<(30 * 16_000)).map(Float.init))
        await session.finish()
        let separator = word == "你好" ? "" : " "
        #expect(output.values.last?.text == Array(repeating: word, count: 30).joined(separator: separator))
        #expect(output.values.count > 3)
        #expect(output.values.map(\.revision) == (1...output.values.count).map(UInt64.init))
        #expect(output.failures == 0)
    }

    @Test("arrivals coalesce while a single decoder is in flight")
    func singleFlight() async {
        let decoder = BufferedHeldDecoder()
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { try await decoder.decode($0) },
                                                  onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var calls = decoder.started.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        #expect(await calls.next() == 32_000)
        for _ in 0..<8 { session.enqueue(Array(repeating: 0.3, count: 4_000)) }
        await decoder.release()
        await session.finish()
        #expect(await decoder.maximumInFlight == 1)
        #expect(await decoder.callCount <= 3)
        #expect(output.values.last?.text == "hello")
    }

    @Test("cancel releases finish and rejects in-flight completion and future audio")
    func cancellation() async {
        let decoder = BufferedHeldDecoder()
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { try await decoder.decode($0) },
                                                  onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var calls = decoder.started.stream.makeAsyncIterator()
        var completions = decoder.completed.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await calls.next()
        session.cancel()
        await session.finish()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        await decoder.release()
        _ = await completions.next()
        #expect(output.values.isEmpty)
        #expect(output.failures == 0)
        #expect(await decoder.callCount == 1)
    }

    @Test("overrun fails explicitly instead of dropping uncommitted audio")
    func overrun() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in
            Issue.record("Overflow must fail before decoding")
            return .init(text: "", words: [])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        session.enqueue(Array(repeating: 0.2, count: 480_001))
        await session.finish()
        #expect(output.failures == 1)
        #expect(output.values.isEmpty)
    }

    @Test("missing timings fail and all-zero silence bypasses the model")
    func timingsAndSilence() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in .init(text: "unaccounted words", words: []) },
                                                  onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        await session.finish()
        #expect(output.failures == 1)
        let silent = BufferedTranscriptionSession(decode: { _ in
            Issue.record("Silence must not reach hallucination-prone decoder")
            return .init(text: "", words: [])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        silent.enqueue(Array(repeating: 0, count: 16_000))
        await silent.finish()
        #expect(output.values.last?.text == "")
        #expect(silent.diagnostics.receivedSamples == 16_000)
        #expect(silent.diagnostics.decodeCount == 0)
        #expect(silent.diagnostics.revision == 1)
        #expect(silent.diagnostics.closed)
    }

    @Test("word alignment rejects missing text instead of silently dropping it")
    func alignment() {
        #expect(throws: (any Error).self) {
            try BufferedTranscriptionWindow.aligned(text: "please keep everything", words: [.init(text: "please", start: 0, end: 1)])
        }
    }

    @Test("default previews freeze an agreed prefix before the first fifteen-second roll")
    func incrementalStablePrefix() async {
        let output = BufferedPreviewOutput()
        let oracle = BufferedTimedOracle()
        let session = BufferedTranscriptionSession(decode: { try await oracle.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(5 * 16_000)).map(Float.init))
        let first = await updates.next()
        #expect(first?.committedText == "")
        session.enqueue(((5 * 16_000)..<(6 * 16_000)).map(Float.init))
        let second = await updates.next()
        #expect(second?.committedText == "go go café,")
        #expect(second?.tail.isEmpty == false)
        #expect(session.diagnostics.receivedSamples < 15 * 16_000)
        await session.finish()
        #expect(output.failures == 0)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("punctuation remains draft until agreement and committed text ignores later casing changes")
    func stablePunctuationAndFinalTail() async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedScriptedDecoder([
            ["hello", "world", "draft"],
            ["Hello", "world", "draft"],
            ["Hello", "world,", "latest"],
            ["HELLO", "world,", "latest!"],
            ["hello", "WORLD,", "final."]
        ])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 5 * 16_000))
        #expect(await updates.next()?.committedText == "")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "Hello")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "Hello world,")
        await session.finish()
        #expect(output.values.last?.committedText == "Hello world, final.")
        #expect(output.values.last?.tail == "")
        #expect(output.failures == 0)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("incremental prefixes survive multiple default rolls, repeated words, punctuation, and timing jitter")
    func stablePrefixAcrossRolls() async {
        let output = BufferedPreviewOutput()
        let oracle = BufferedTimedOracle(jitter: 0.06)
        let session = BufferedTranscriptionSession(decode: { try await oracle.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(2 * 16_000)).map(Float.init))
        _ = await updates.next()
        for end in 3...31 {
            session.enqueue((((end - 1) * 16_000)..<(end * 16_000)).map(Float.init))
            _ = await updates.next()
            if output.failures > 0 { break }
        }
        await session.finish()
        #expect(output.values.last?.text == BufferedTimedOracle.expectedText)
        #expect(output.values.last?.tail == "")
        #expect(output.failures == 0)
        #expect(await oracle.maximumInFlight == 1)
        #expect(await oracle.largestWindow <= 15 * 16_000)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("slow inference coalesces across rollover without losing uncommitted repeated speech")
    func stableSlowInference() async {
        let output = BufferedPreviewOutput()
        let oracle = BufferedTimedOracle(jitter: 0.06, holdFirst: true)
        let session = BufferedTranscriptionSession(decode: { try await oracle.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var starts = oracle.started.stream.makeAsyncIterator()
        session.enqueue((0..<(2 * 16_000)).map(Float.init))
        _ = await starts.next()
        session.enqueue(((2 * 16_000)..<(30 * 16_000)).map(Float.init))
        await oracle.release()
        await session.finish()
        #expect(output.values.last?.text == BufferedTimedOracle.expectedText)
        #expect(output.failures == 0)
        #expect(await oracle.maximumInFlight == 1)
        #expect(await oracle.largestWindow <= 15 * 16_000)
        #expect(await oracle.callCount <= 5)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("uniform jitter on dense repeated words fails rather than choosing the wrong occurrence", arguments: [-0.2, 0.2])
    func ambiguousRepeatedAnchors(shift: Double) async {
        func window(_ shift: Double) -> BufferedTranscriptionWindow {
            let words = (0..<20).map { index in
                BufferedTranscriptionWord(text: "go", start: 0.3 + Double(index) * 0.2 + shift,
                    end: 0.45 + Double(index) * 0.2 + shift)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window(0), window(0), window(shift)])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 5 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let committed = await updates.next()
        #expect(committed?.committedText.isEmpty == false)
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next() == nil)
        await session.finish()
        #expect(output.failures == 1)
        #expect(output.values.last == committed)
    }

    @Test("owned word duration may expand through silence without changing its timed occurrence")
    func committedDurationExtension() async {
        func window(extended: Bool) -> BufferedTranscriptionWindow {
            let research = extended ? "research," : "research"
            let words: [BufferedTranscriptionWord] = [
                .init(text: "Please", start: 0.1, end: 0.5),
                .init(text: research, start: 4.4, end: extended ? 6.96 : 5.28),
                .init(text: "and", start: 6.88, end: 6.96)
            ]
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window(extended: false), window(extended: false), window(extended: true)])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 8 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "Please research")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "Please research and")
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.text == "Please research and")
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("transient empty hypothesis preserves draft and requires fresh agreement")
    func transientEmptyPreservesDraft() async {
        let words: [BufferedTranscriptionWord] = [
            .init(text: "hello", start: 0.1, end: 0.5),
            .init(text: "world", start: 1, end: 1.5),
            .init(text: "draft", start: 4, end: 4.5)
        ]
        let window = BufferedTranscriptionWindow(text: "hello world draft", words: words)
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window, window, .init(text: "", words: []), window, window])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 5 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let stable = await updates.next()
        #expect(stable?.committedText == "hello world")
        for _ in 0..<2 {
            session.enqueue(Array(repeating: 0.2, count: 16_000))
            let next = await updates.next()
            #expect(next?.text == stable?.text)
            #expect(next?.committedText == stable?.committedText)
        }
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "hello world draft")
        await session.finish()
        #expect(output.failures == 0)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("sentence spacing survives silence that removes old timing anchors")
    func spacingAfterSilentRollover() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let base = Double(samples[0]) / 16_000
            let end = base + Double(samples.count) / 16_000
            let words: [BufferedTranscriptionWord] = [("Done.", 0.1, 0.5), ("Next", 18.1, 18.5)].compactMap { text, start, finish in
                guard start >= base, finish <= end else { return nil }
                return .init(text: text, start: start - base, end: finish - base)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        session.enqueue((0..<(30 * 16_000)).map(Float.init))
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.text == "Done. Next")
    }

    private func assertMonotonicCommittedPrefixes(_ values: [BufferedTranscriptionUpdate]) {
        for (previous, current) in zip(values, values.dropFirst()) {
            #expect(current.committedText.utf16.starts(with: previous.committedText.utf16))
        }
    }

    @Test("decoder failure closes the session once before finish returns")
    func decoderFailure() async {
        let output = BufferedPreviewOutput()
        let cancellation = BufferedReentrantCancellation()
        let session = BufferedTranscriptionSession(decode: { _ in
            throw BufferedTranscriptionSession.Failure.invalidTimings
        }, onUpdate: { output.update($0) }, onFailure: {
            cancellation.cancel()
            output.fail($0)
        })
        cancellation.set(session)
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        await session.finish()
        #expect(output.failures == 1)
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        await session.finish()
        #expect(output.failures == 1)
        #expect(output.values.isEmpty)
    }
}

private final class BufferedReentrantCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private weak var session: BufferedTranscriptionSession?
    func set(_ session: BufferedTranscriptionSession) { lock.withLock { self.session = session } }
    func cancel() {
        let session = lock.withLock { self.session }
        session?.cancel()
    }
}

private final class BufferedPreviewOutput: @unchecked Sendable {
    let updates = AsyncStream<BufferedTranscriptionUpdate>.makeStream()
    private let lock = NSLock()
    private var storage: [BufferedTranscriptionUpdate] = []
    private var errors = 0
    var values: [BufferedTranscriptionUpdate] { lock.withLock { storage } }
    var failures: Int { lock.withLock { errors } }
    func update(_ value: BufferedTranscriptionUpdate) {
        lock.withLock { storage.append(value) }
        updates.continuation.yield(value)
    }
    func fail(_ error: Error) {
        lock.withLock { errors += 1 }
        updates.continuation.finish()
    }
}

private actor BufferedHeldDecoder {
    nonisolated let started = AsyncStream<Int>.makeStream()
    nonisolated let completed = AsyncStream<Void>.makeStream()
    private var permit: CheckedContinuation<Void, Never>?
    private var released = false
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var callCount = 0
    func decode(_ samples: [Float]) async throws -> BufferedTranscriptionWindow {
        callCount += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        started.continuation.yield(samples.count)
        if !released { await withCheckedContinuation { permit = $0 } }
        inFlight -= 1
        completed.continuation.yield(())
        return .init(text: "hello", words: [.init(text: "hello", start: 0, end: 0.5)])
    }
    func release() { released = true; permit?.resume(); permit = nil }
}

private actor BufferedScriptedDecoder {
    private let hypotheses: [[String]]
    private var index = 0
    init(_ hypotheses: [[String]]) { self.hypotheses = hypotheses }
    func decode(_ samples: [Float]) -> BufferedTranscriptionWindow {
        let text = hypotheses[min(index, hypotheses.count - 1)]
        index += 1
        let times: [(Double, Double)] = [(0.1, 0.5), (1, 1.5), (4, 4.5)]
        return .init(text: text.joined(separator: " "), words: zip(text, times).map {
            .init(text: $0.0, start: $0.1.0, end: $0.1.1)
        })
    }
}

private actor BufferedTimedOracle {
    nonisolated let started = AsyncStream<Void>.makeStream()
    private let jitter: Double
    private let holdFirst: Bool
    private var permit: CheckedContinuation<Void, Never>?
    private var released = false
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var largestWindow = 0
    private(set) var callCount = 0
    private static let words = (0..<30).map { ["go", "go", "café,", "go"][$0 % 4] }
    static var expectedText: String { words.joined(separator: " ") }

    init(jitter: Double = 0, holdFirst: Bool = false) { self.jitter = jitter; self.holdFirst = holdFirst }
    func decode(_ samples: [Float]) async throws -> BufferedTranscriptionWindow {
        callCount += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        largestWindow = max(largestWindow, samples.count)
        started.continuation.yield(())
        if holdFirst && !released { await withCheckedContinuation { permit = $0 } }
        defer { inFlight -= 1 }
        let base = Double(samples[0]) / 16_000
        let end = base + Double(samples.count) / 16_000
        let shift = callCount.isMultiple(of: 2) ? jitter : -jitter
        let words: [BufferedTranscriptionWord] = Self.words.enumerated().compactMap { index, word in
            let start = Double(index) + 0.2
            let finish = Double(index) + 0.65
            guard start >= base, finish <= end else { return nil }
            return .init(text: word, start: max(0, start - base + shift), end: finish - base + shift)
        }
        return .init(text: words.map(\.text).joined(separator: " "), words: words)
    }
    func release() { released = true; permit?.resume(); permit = nil }
}

private actor BufferedWindowSequence {
    private let windows: [BufferedTranscriptionWindow]
    private var index = 0
    init(_ windows: [BufferedTranscriptionWindow]) { self.windows = windows }
    func decode(_ samples: [Float]) -> BufferedTranscriptionWindow {
        defer { index += 1 }
        return windows[min(index, windows.count - 1)]
    }
}
