import Foundation
import Testing
@testable import MuesliNativeApp

/// These are runtime continuity tests, independent of a model's vocabulary,
/// confidence calibration, or timestamp quality. PCM carries its absolute sample
/// index so a successful transcript cannot conceal dropped or replayed audio.
@Suite("Buffered transcription continuity", .timeLimit(.minutes(1)))
struct BufferedTranscriptionContinuityTests {
    @Test("missing timings switch to bounded disjoint chunks for either runtime policy", arguments: [false, true])
    func untimedHypothesesKeepStreaming(whisper: Bool) async throws {
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .deferral)
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        var updates = output.updates.stream.makeAsyncIterator()

        session.enqueue(ContinuityPCM.samples(0..<32_000))
        #expect(try await next(&updates).committedText.isEmpty)
        session.enqueue(ContinuityPCM.samples(32_000..<64_000))
        #expect(try await next(&updates).committedText == "chunk0")
        #expect(try await next(&updates).committedText == "chunk0 chunk32000")
        session.enqueue(ContinuityPCM.samples(64_000..<96_000))
        #expect(try await next(&updates).committedText == "chunk0 chunk32000 chunk64000")
        #expect(!session.diagnostics.closed)

        let result = await session.finishForReuse()
        #expect(result.canReuse && result.completed)
        #expect(result.receivedSamples == 96_000 && result.decodedThroughSample == 96_000)
        #expect(await decoder.timedCalls == 2)
        #expect(await decoder.rawRanges == [0..<32_000, 32_000..<64_000, 64_000..<96_000])
        #expect(output.failures == 0)
        assertCommittedPrefixes(output.values)
    }

    @Test("malformed timed hypotheses enter continuity without accepting their word ownership",
          arguments: [false, true], ContinuityInvalidWindow.allCases)
    func invalidTimingWindowsKeepStreaming(whisper: Bool, invalid: ContinuityInvalidWindow) async throws {
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .windows([invalid.window]))
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(ContinuityPCM.samples(0..<32_000))
        #expect(try await next(&updates).committedText.isEmpty)
        session.enqueue(ContinuityPCM.samples(32_000..<64_000))
        #expect(try await next(&updates).committedText == "chunk0")
        #expect(try await next(&updates).committedText == "chunk0 chunk32000")
        #expect(!session.diagnostics.closed)
        #expect(session.knownReuseFallbackReason == nil)

        let result = await session.finishForReuse()
        #expect(result.canReuse && result.completed)
        #expect(result.text == "chunk0 chunk32000")
        #expect(result.receivedSamples == 64_000 && result.decodedThroughSample == 64_000)
        #expect(await decoder.timedCalls == 2)
        #expect(await decoder.rawRanges == [0..<32_000, 32_000..<64_000])
        #expect(output.failures == 0)
        assertCommittedPrefixes(output.values)
    }

    @Test("a perpetually revised first word cannot hold all following speech", arguments: [false, true])
    func firstWordRevisionCannotStallDelivery(whisper: Bool) async throws {
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .unstableFirstWord)
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        var updates = output.updates.stream.makeAsyncIterator()

        session.enqueue(ContinuityPCM.samples(0..<32_000))
        #expect(try await next(&updates).committedText.isEmpty)
        for second in 3...5 {
            session.enqueue(ContinuityPCM.samples((second - 1) * 16_000..<second * 16_000))
            #expect(try await next(&updates).committedText.isEmpty)
        }
        session.enqueue(ContinuityPCM.samples(80_000..<96_000))
        for expectedCount in 1...3 {
            #expect(try await next(&updates).committedText.split(separator: " ").count == expectedCount)
        }
        #expect(!session.diagnostics.closed)
        session.enqueue(ContinuityPCM.samples(96_000..<112_000))

        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.text == "chunk0 chunk32000 chunk64000 chunk96000")
        #expect(result.decodedThroughSample == 112_000)
        #expect(await decoder.timedCalls == 5)
        #expect(await decoder.rawRanges == [0..<32_000, 32_000..<64_000, 64_000..<96_000, 96_000..<112_000])
        #expect(output.failures == 0)
        assertCommittedPrefixes(output.values)
    }

    @Test("recovery starts at the frozen commit fence even after an owned duration expands", arguments: [false, true])
    func changedAnchorsRetainEveryUnownedSample(whisper: Bool) async throws {
        let initial = ContinuityDecoder.window([
            .init(text: "hello", start: 0.1, end: 0.5),
            .init(text: "world", start: 1, end: 1.5),
            .init(text: "draft", start: 4, end: 4.5)
        ])
        let expanded = ContinuityDecoder.window([
            .init(text: "hello", start: 0.1, end: 0.5),
            .init(text: "world", start: 1, end: 5.5),
            .init(text: "draft", start: 4, end: 4.5)
        ])
        let changed = ContinuityDecoder.window([
            .init(text: "other", start: 2, end: 2.5),
            .init(text: "later", start: 3, end: 3.5),
            .init(text: "revision", start: 4, end: 4.5)
        ])
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .windows([initial, initial, expanded, changed, changed]))
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        var updates = output.updates.stream.makeAsyncIterator()

        session.enqueue(ContinuityPCM.samples(0..<72_000))
        _ = try await next(&updates)
        session.enqueue(ContinuityPCM.samples(72_000..<88_000))
        #expect(try await next(&updates).committedText == "hello world")
        session.enqueue(ContinuityPCM.samples(88_000..<104_000))
        #expect(try await next(&updates).committedText == "hello world")
        session.enqueue(ContinuityPCM.samples(104_000..<120_000))
        #expect(try await next(&updates).committedText == "hello world")
        session.enqueue(ContinuityPCM.samples(120_000..<136_000))
        #expect(try await next(&updates).committedText == "hello world chunk44000")
        #expect(try await next(&updates).committedText == "hello world chunk44000 chunk76000")

        let result = await session.finishForReuse()
        // The original seam is halfway between world.end=1.5 and draft.start=4.
        // Its 44,000-sample fence must not move to the later 5.5-second word end.
        #expect(await decoder.rawRanges == [44_000..<76_000, 76_000..<108_000, 108_000..<136_000])
        #expect(result.text == "hello world chunk44000 chunk76000 chunk108000")
        #expect(result.canReuse && result.decodedThroughSample == 136_000)
        #expect(output.failures == 0)
        assertCommittedPrefixes(output.values)
    }

    @Test("ambiguous repeated anchors preserve the committed prefix and continue on new audio", arguments: [false, true])
    func ambiguousRepeatedAnchorsDoNotTerminate(whisper: Bool) async throws {
        func repeated(_ shift: Double) -> BufferedTranscriptionWindow {
            ContinuityDecoder.window((0..<20).map { index in
                .init(text: "go", start: 0.3 + Double(index) * 0.2 + shift,
                      end: 0.45 + Double(index) * 0.2 + shift)
            })
        }
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .windows([repeated(0), repeated(0), repeated(0.2)]))
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(ContinuityPCM.samples(0..<72_000))
        _ = try await next(&updates)
        session.enqueue(ContinuityPCM.samples(72_000..<88_000))
        let committed = try await next(&updates).committedText
        #expect(!committed.isEmpty)
        session.enqueue(ContinuityPCM.samples(88_000..<104_000))
        #expect(try await next(&updates).committedText == committed)
        session.enqueue(ContinuityPCM.samples(104_000..<120_000))
        let resumed = try await next(&updates)
        #expect(resumed.committedText.hasPrefix(committed + " chunk"))
        #expect(resumed.tail.isEmpty)
        #expect(!session.diagnostics.closed)

        let result = await session.finishForReuse()
        #expect(result.canReuse && result.decodedThroughSample == 120_000)
        #expect(result.text.hasPrefix(committed + " chunk"))
        let ranges = await decoder.rawRanges
        #expect(!ranges.isEmpty)
        #expect(ranges.last?.upperBound == 120_000)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(output.failures == 0)
        assertCommittedPrefixes(output.values)
    }

    @Test("empty hypotheses and an empty raw chunk do not prevent later delivery", arguments: [false, true])
    func emptyRecognitionRemainsQualityUncertainty(whisper: Bool) async throws {
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .empty, blankFirstRaw: true)
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        var updates = output.updates.stream.makeAsyncIterator()
        let windowSeconds = (whisper ? BufferedTranscriptionSession.Configuration.whisper
                                    : BufferedTranscriptionSession.Configuration()).windowSamples / 16_000

        session.enqueue(ContinuityPCM.samples(0..<32_000))
        _ = try await next(&updates)
        for second in 3...windowSeconds {
            session.enqueue(ContinuityPCM.samples((second - 1) * 16_000..<second * 16_000))
            #expect(try await next(&updates).committedText.isEmpty)
        }
        session.enqueue(ContinuityPCM.samples(windowSeconds * 16_000..<(windowSeconds + 1) * 16_000))
        #expect(try await next(&updates).committedText.isEmpty)
        #expect(try await next(&updates).committedText == "chunk32000")

        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.decodedThroughSample == (windowSeconds + 1) * 16_000)
        #expect(!result.text.contains("chunk0 "))
        #expect(result.text.hasPrefix("chunk32000"))
        let ranges = await decoder.rawRanges
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == result.receivedSamples)
        #expect(zip(ranges, ranges.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        #expect(output.failures == 0)
        assertCommittedPrefixes(output.values)
    }

    @Test("more than five minutes of repeated words and long pauses keep bounded live progress", arguments: [false, true])
    func sustainedContinuityWithPauses(whisper: Bool) async throws {
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .deferral, repeatedRaw: "go")
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(ContinuityPCM.samples(0..<32_000))
        _ = try await next(&updates)
        session.enqueue(ContinuityPCM.samples(32_000..<64_000))
        _ = try await next(&updates)
        _ = try await next(&updates)

        var expectedWords = 2
        var expectedRanges = [0..<32_000, 32_000..<64_000]
        // 330 seconds of audio, including ten-second pauses every minute.
        for chunk in 2..<165 {
            let range = chunk * 32_000..<(chunk + 1) * 32_000
            let isPause = (20..<25).contains(chunk % 30)
            session.enqueue(isPause ? Array(repeating: 0, count: 32_000) : ContinuityPCM.samples(range))
            let update = try await next(&updates)
            if !isPause {
                expectedWords += 1
                expectedRanges.append(range)
            }
            #expect(update.committedText.split(separator: " ").count == expectedWords,
                    "Streaming stopped making progress at audio second \((chunk + 1) * 2)")
            #expect(update.tail.isEmpty)
            #expect(!session.diagnostics.closed)
        }

        let result = await session.finishForReuse()
        #expect(result.canReuse && result.completed)
        #expect(result.text == Array(repeating: "go", count: expectedWords).joined(separator: " "))
        #expect(result.receivedSamples == 330 * 16_000 && result.decodedThroughSample == 330 * 16_000)
        #expect(await decoder.timedCalls == 2)
        #expect(await decoder.rawRanges == expectedRanges)
        #expect(await decoder.maximumRawSamples == 32_000)
        #expect(await decoder.maximumInFlight == 1)
        #expect(output.failures == 0)
        assertCommittedPrefixes(output.values)
    }

    @Test("stopping an untimed short utterance drains only its actual samples", arguments: [false, true])
    func finalShortTailNeedsNoFullSessionPass(whisper: Bool) async {
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .deferral)
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        session.enqueue(ContinuityPCM.samples(0..<8_123))
        let result = await session.finishForReuse()
        #expect(result.canReuse && result.completed)
        #expect(result.text == "chunk0")
        #expect(result.receivedSamples == 8_123 && result.decodedThroughSample == 8_123)
        #expect(await decoder.rawRanges == [0..<8_123])
        #expect(output.failures == 0)

        let finalUpdates = output.values
        let finalRevision = session.diagnostics.revision
        session.enqueue(ContinuityPCM.samples(8_123..<40_123))
        let repeatedFinish = await session.finishForReuse()
        #expect(repeatedFinish.canReuse && repeatedFinish.text == result.text)
        #expect(repeatedFinish.receivedSamples == 8_123 && repeatedFinish.decodedThroughSample == 8_123)
        #expect(session.diagnostics.revision == finalRevision)
        #expect(output.values == finalUpdates)
        #expect(await decoder.rawRanges == [0..<8_123])
    }

    @Test("audio arriving during raw inference is retained and decoded once", arguments: [false, true])
    func arrivalsDuringInferenceAreNotLost(whisper: Bool) async throws {
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .deferral, holdFirstRaw: true)
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        var updates = output.updates.stream.makeAsyncIterator()
        var starts = decoder.rawStarted.stream.makeAsyncIterator()
        session.enqueue(ContinuityPCM.samples(0..<32_000))
        _ = try await next(&updates)
        session.enqueue(ContinuityPCM.samples(32_000..<64_000))
        #expect(await starts.next() == 0..<32_000)
        session.enqueue(ContinuityPCM.samples(64_000..<117_123))
        let finishing = Task { await session.finishForReuse() }
        await decoder.release()

        let result = await finishing.value
        #expect(result.canReuse && result.decodedThroughSample == 117_123)
        #expect(result.text == "chunk0 chunk32000 chunk64000 chunk96000")
        #expect(await decoder.rawRanges == [0..<32_000, 32_000..<64_000, 64_000..<96_000, 96_000..<117_123])
        #expect(await decoder.maximumInFlight == 1)
        #expect(output.failures == 0)
        assertCommittedPrefixes(output.values)
    }

    @Test("cancelling a held continuity decode prevents every late update", arguments: [false, true])
    func cancellationStillClosesTheSession(whisper: Bool) async throws {
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .deferral, holdFirstRaw: true)
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        var updates = output.updates.stream.makeAsyncIterator()
        var starts = decoder.rawStarted.stream.makeAsyncIterator()
        var completions = decoder.rawCompleted.stream.makeAsyncIterator()
        session.enqueue(ContinuityPCM.samples(0..<32_000))
        _ = try await next(&updates)
        session.enqueue(ContinuityPCM.samples(32_000..<64_000))
        _ = await starts.next()
        session.cancel()
        let countAtCancellation = output.values.count
        let result = await session.finishForReuse()
        #expect(!result.canReuse && result.fallbackReason == .cancelled)
        #expect(session.diagnostics.closed)
        await decoder.release()
        _ = await completions.next()
        session.enqueue(ContinuityPCM.samples(64_000..<96_000))
        #expect(output.values.count == countAtCancellation)
        #expect(session.diagnostics.receivedSamples == 64_000)
        #expect(output.failures == 0)
    }

    @Test("a real raw decoder error remains a failure", arguments: [false, true])
    func decoderErrorsAreNotMisreportedAsSuccessfulContinuity(whisper: Bool) async throws {
        let output = ContinuityOutput()
        let decoder = ContinuityDecoder(timed: .deferral, failRaw: true)
        let session = makeSession(whisper: whisper, decoder: decoder, output: output)
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(ContinuityPCM.samples(0..<32_000))
        _ = try await next(&updates)
        session.enqueue(ContinuityPCM.samples(32_000..<64_000))
        let result = await session.finishForReuse()
        #expect(!result.canReuse && !result.completed)
        #expect(result.fallbackReason == .transcriptionFailed)
        #expect(result.decodedThroughSample < result.receivedSamples)
        #expect(output.failures == 1)
        #expect(session.diagnostics.closed)
        #expect(await decoder.rawRanges == [0..<32_000])
    }

    private func makeSession(whisper: Bool, decoder: ContinuityDecoder,
                             output: ContinuityOutput) -> BufferedTranscriptionSession {
        BufferedTranscriptionSession(configuration: whisper ? .whisper : .init(),
            decode: { try await decoder.decode($0) },
            decodeWithoutTimings: { try await decoder.decodeRaw($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
    }

    private func next(_ updates: inout AsyncStream<BufferedTranscriptionUpdate>.Iterator) async throws -> BufferedTranscriptionUpdate {
        try #require(await updates.next())
    }

    private func assertCommittedPrefixes(_ values: [BufferedTranscriptionUpdate]) {
        for (previous, current) in zip(values, values.dropFirst()) {
            #expect(current.committedText.hasPrefix(previous.committedText))
            #expect(current.revision > previous.revision)
        }
    }
}

enum ContinuityInvalidWindow: String, CaseIterable, Sendable {
    case missingWords, textMismatch, negativeStart, reversedEnd, nonFiniteTime, nonMonotonicStarts, outsideSnapshot

    var window: BufferedTranscriptionWindow {
        switch self {
        case .missingWords:
            return .init(text: "heard", words: [])
        case .textMismatch:
            return .init(text: "heard", words: [.init(text: "other", start: 0.1, end: 0.5)])
        case .negativeStart:
            return ContinuityDecoder.window([.init(text: "heard", start: -0.1, end: 0.5)])
        case .reversedEnd:
            return ContinuityDecoder.window([.init(text: "heard", start: 1, end: 0.5)])
        case .nonFiniteTime:
            return ContinuityDecoder.window([.init(text: "heard", start: .nan, end: .infinity)])
        case .nonMonotonicStarts:
            return ContinuityDecoder.window([
                .init(text: "heard", start: 1, end: 1.5),
                .init(text: "again", start: 0.1, end: 0.5)
            ])
        case .outsideSnapshot:
            return ContinuityDecoder.window([.init(text: "heard", start: 0.1, end: 100)])
        }
    }
}

private enum ContinuityPCM {
    static func samples(_ range: Range<Int>) -> [Float] {
        range.map { Float($0 + 1) }
    }

    static func range(_ samples: [Float]) -> Range<Int> {
        let start = Int(samples[0]) - 1
        return start..<(start + samples.count)
    }
}

private final class ContinuityOutput: @unchecked Sendable {
    let updates = AsyncStream<BufferedTranscriptionUpdate>.makeStream()
    private let lock = NSLock()
    private var storage: [BufferedTranscriptionUpdate] = []
    private var errorCount = 0
    var values: [BufferedTranscriptionUpdate] { lock.withLock { storage } }
    var failures: Int { lock.withLock { errorCount } }

    func update(_ update: BufferedTranscriptionUpdate) {
        lock.withLock { storage.append(update) }
        updates.continuation.yield(update)
    }

    func fail(_ error: Error) {
        lock.withLock { errorCount += 1 }
        updates.continuation.finish()
    }
}

private actor ContinuityDecoder {
    enum Timed: Sendable {
        case deferral, unstableFirstWord, empty
        case windows([BufferedTranscriptionWindow])
    }
    enum Failure: Error { case decoderFailed }

    nonisolated let rawStarted = AsyncStream<Range<Int>>.makeStream()
    nonisolated let rawCompleted = AsyncStream<Void>.makeStream()
    private let timed: Timed
    private let blankFirstRaw: Bool
    private let repeatedRaw: String?
    private let holdFirstRaw: Bool
    private let failRaw: Bool
    private var released = false
    private var permit: CheckedContinuation<Void, Never>?
    private var inFlight = 0
    private(set) var timedCalls = 0
    private(set) var rawRanges: [Range<Int>] = []
    private(set) var maximumRawSamples = 0
    private(set) var maximumInFlight = 0

    init(timed: Timed, blankFirstRaw: Bool = false, repeatedRaw: String? = nil,
         holdFirstRaw: Bool = false, failRaw: Bool = false) {
        self.timed = timed
        self.blankFirstRaw = blankFirstRaw
        self.repeatedRaw = repeatedRaw
        self.holdFirstRaw = holdFirstRaw
        self.failRaw = failRaw
    }

    nonisolated static func window(_ words: [BufferedTranscriptionWord]) -> BufferedTranscriptionWindow {
        .init(text: words.map(\.text).joined(separator: " "), words: words)
    }

    func decode(_ samples: [Float]) throws -> BufferedTranscriptionWindow {
        timedCalls += 1
        switch timed {
        case .deferral:
            throw BufferedTranscriptionPreviewDeferral.missingWordTimings
        case .empty:
            return .init(text: "", words: [])
        case .unstableFirstWord:
            return Self.window([
                .init(text: "revision\(timedCalls)", start: 0.1, end: 0.5),
                .init(text: "suffix", start: 1, end: 1.5)
            ])
        case .windows(let windows):
            return windows[min(timedCalls - 1, windows.count - 1)]
        }
    }

    func decodeRaw(_ samples: [Float]) async throws -> String {
        let range = ContinuityPCM.range(samples)
        rawRanges.append(range)
        maximumRawSamples = max(maximumRawSamples, samples.count)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        defer {
            inFlight -= 1
            rawCompleted.continuation.yield(())
        }
        rawStarted.continuation.yield(range)
        if holdFirstRaw && rawRanges.count == 1 && !released {
            await withCheckedContinuation { permit = $0 }
        }
        // Deliberately ignore Task cancellation, as some native decoders do.
        // Session cancellation must reject their late completion independently.
        if failRaw { throw Failure.decoderFailed }
        if blankFirstRaw && rawRanges.count == 1 { return "" }
        return repeatedRaw ?? "chunk\(range.lowerBound)"
    }

    func release() {
        released = true
        permit?.resume()
        permit = nil
    }
}
