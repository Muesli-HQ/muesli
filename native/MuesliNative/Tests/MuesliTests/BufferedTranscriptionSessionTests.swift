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
    }

    @Test("word alignment rejects missing text instead of silently dropping it")
    func alignment() {
        #expect(throws: (any Error).self) {
            try BufferedTranscriptionWindow.aligned(text: "please keep everything", words: [.init(text: "please", start: 0, end: 1)])
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
    private let lock = NSLock()
    private var storage: [BufferedTranscriptionUpdate] = []
    private var errors = 0
    var values: [BufferedTranscriptionUpdate] { lock.withLock { storage } }
    var failures: Int { lock.withLock { errors } }
    func update(_ value: BufferedTranscriptionUpdate) { lock.withLock { storage.append(value) } }
    func fail(_ error: Error) { lock.withLock { errors += 1 } }
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
