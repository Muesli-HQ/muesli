import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Buffered transcription")
struct BufferedTranscriptionSessionTests {
    @Test("Whisper preview cadence and window preserve context and recovery budgets")
    func whisperConfiguration() {
        let configuration = BufferedTranscriptionSession.Configuration.whisperPreview
        #expect(configuration.minimumSamples == 32_000)
        #expect(configuration.updateSamples == 8_000)
        #expect(configuration.windowSamples == 240_000)
        #expect(configuration.rightContextSamples == 48_000)
        #expect(configuration.leftContextSamples == 16_000)
        #expect(configuration.maximumRecoveryWindowSamples == 480_000)
        #expect(configuration.maximumBufferedSamples == 720_000)
        #expect(configuration.smoothWhisperPreviews)
        #expect(configuration.usesWhisperLocalAgreement)
        let standard = BufferedTranscriptionSession.Configuration()
        #expect(standard.updateSamples == 16_000)
        #expect(standard.windowSamples == 240_000)
        #expect(!standard.smoothWhisperPreviews)
        #expect(!standard.usesWhisperLocalAgreement)
    }

    @Test("Whisper text agreement survives timing drift, old lexical revisions and token splits", arguments: [false, true])
    func whisperLexicalAgreement(changedEarlier: Bool) async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([
            whisperWindow(["old", "phrase", "cannot", "go", "go", "draft"]),
            whisperWindow(["old", "phrase", "cannot", "go", "go", "next"], shift: 0.6),
            whisperWindow([changedEarlier ? "new" : "old", "phrase", "can", "not", "go", "go", "next", "later"], shift: 1.0)
        ])
        var config = BufferedTranscriptionSession.Configuration.whisperPreview
        config.smoothWhisperPreviews = false
        let session = BufferedTranscriptionSession(configuration: config, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        #expect(await updates.next()?.committedText == "")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "old phrase cannot")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "old phrase cannot go")
        #expect(await session.finishTranscript() == "old phrase cannot go go next later")
        #expect(output.failures == 0)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("Whisper never deduplicates the first of multiple matching repeated seams")
    func whisperAmbiguousRepeatedSeam() async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([
            whisperWindow(["old", "alpha", "go", "go", "held", "words", "draft"]),
            whisperWindow(["old", "alpha", "go", "go", "held", "words", "next"]),
            whisperWindow(["new", "alpha", "go", "go", "held", "words", "next", "alpha", "go", "go", "held", "words", "next"])
        ])
        let session = BufferedTranscriptionSession(configuration: .whisperPreview, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let stable = await updates.next()
        for _ in 0..<2 {
            session.enqueue(Array(repeating: 0.2, count: 16_000))
            #expect(await updates.next()?.text == stable?.text)
        }
        #expect(await session.finishTranscript() == nil)
        #expect(output.failures == 1)
        #expect(output.diagnostics.contains { $0.contains("local_agreement_deferred:ambiguous_anchor") && $0.contains("candidate_count=2") })
    }

    @Test("Whisper keeps two agreed edge words visible but revisable until more context arrives")
    func whisperAgreementLookbackCorrectsDIF() async {
        let output = BufferedPreviewOutput()
        let prefix = ["I", "am", "cutting", "a", "release"]
        let decoder = BufferedWindowSequence([
            whisperWindow(prefix + ["DIF", "means", "draft"]),
            whisperWindow(prefix + ["DIF", "means", "comparing"]),
            whisperWindow(prefix + ["Diff", "means", "comparing", "what", "is"]),
            whisperWindow(prefix + ["Diff", "means", "comparing", "what", "is", "changed"])
        ])
        let session = BufferedTranscriptionSession(configuration: .whisperPreview, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let edge = await updates.next()
        #expect(edge?.committedText == "I am cutting a release")
        #expect(edge?.text == "I am cutting a release DIF means comparing")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "I am cutting a release")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "I am cutting a release Diff means comparing")
        #expect(await session.finishTranscript() == "I am cutting a release Diff means comparing what is changed")
        #expect(output.failures == 0)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("Whisper retains following seam evidence after failed observations")
    func whisperFollowingContextSurvivesDeferral() async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([
            whisperWindow(["old", "alpha", "beta", "held", "words", "draft"]),
            whisperWindow(["old", "alpha", "beta", "held", "words", "next"]),
            whisperWindow(["new", "alpha", "beta", "wrong", "words", "next"]),
            whisperWindow(["new", "alpha", "beta", "wrong", "words", "next"]),
            whisperWindow(["new", "alpha", "beta", "held", "words", "next", "later"])
        ])
        let session = BufferedTranscriptionSession(configuration: .whisperPreview, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let stable = await updates.next()
        for _ in 0..<2 {
            session.enqueue(Array(repeating: 0.2, count: 16_000))
            #expect(await updates.next()?.text == stable?.text)
        }
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        _ = await updates.next()
        #expect(await session.finishTranscript() == "old alpha beta held words next later")
        #expect(output.failures == 0)
    }

    @Test("Whisper does not force commitment or trim an unconfirmed full window")
    func whisperNoAgreementIsBounded() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisperPreview, decode: { samples in
            let word = "hypothesis\(samples.count)"
            return .init(text: word, words: [.init(text: word, start: 0.1, end: 0.8)], segmentEnds: [1])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 15 * 16_000))
        #expect(await updates.next()?.committedText == "")
        #expect(session.diagnostics.decodeCount == 1)
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "")
        #expect(session.diagnostics.decodeCount == 2)
        session.enqueue(Array(repeating: 0.2, count: 14 * 16_000))
        #expect(await updates.next() == nil)
        #expect(await session.finishTranscript() == nil)
        #expect(output.values.allSatisfy { $0.committedText.isEmpty })
        #expect(output.failures == 1)
    }

    @Test("Whisper repeated clauses survive more than a minute of segment or word-gap rolls", arguments: [false, true])
    func whisperLongRepeatedClauses(segmentMetadata: Bool) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisperPreview, decode: { samples in
            let base = Double(samples[0]) / 16_000
            let end = base + Double(samples.count) / 16_000
            let vocabulary = ["go", "go", "again", "please", "now"]
            let words: [BufferedTranscriptionWord] = (0..<75).compactMap { index in
                let start = Double(index) + 0.2
                let stop = Double(index) + 0.7
                guard start >= base, stop <= end else { return nil }
                return .init(text: vocabulary[index % vocabulary.count], start: start - base, end: stop - base)
            }
            let ends = segmentMetadata ? (1...15).map { Double($0 * 5) - 0.3 - base }.filter { $0 > 0 && $0 < end - base } : []
            return try .aligned(text: words.map(\.text).joined(separator: " "), words: words, segmentEnds: ends)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        var previousEnd = 0
        for second in 2...75 {
            session.enqueue((previousEnd..<(second * 16_000)).map(Float.init))
            previousEnd = second * 16_000
            _ = await updates.next()
            if output.failures > 0 { break }
        }
        let expected = (0..<75).map { ["go", "go", "again", "please", "now"][$0 % 5] }.joined(separator: " ")
        #expect(await session.finishTranscript() == expected)
        #expect(output.failures == 0)
        #expect(output.diagnostics.filter { $0.hasPrefix("local_agreement_trim:") }.count >= 4)
        #expect(output.diagnostics.contains { $0.contains("segment=\(segmentMetadata)") })
        assertMonotonicCommittedPrefixes(output.values)
    }

    private func whisperWindow(_ text: [String], shift: Double = 0) -> BufferedTranscriptionWindow {
        .init(text: text.joined(separator: " "), words: text.enumerated().map {
            .init(text: $0.element, start: 0.1 + Double($0.offset) * 0.15 + shift,
                  end: 0.2 + Double($0.offset) * 0.15 + shift)
        })
    }

    @Test("healthy Whisper window awaiting a trim still finalizes without new audio")
    func whisperUntrimmedFinal() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisperPreview, decode: { _ in
            .init(text: "complete tail", words: [.init(text: "complete", start: 0.1, end: 0.4),
                                                .init(text: " tail", start: 0.5, end: 0.8)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 15 * 16_000))
        #expect(await updates.next()?.committedText == "")
        #expect(await session.finishTranscript() == "complete tail")
        #expect(session.diagnostics.decodeCount == 2)
        #expect(output.failures == 0)
    }

    @Test("Whisper cannot trim across an earlier owned word with an extended end")
    func whisperTrimChecksEveryRemovedWordEnd() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisperPreview, decode: { _ in
            let words = (0..<18).map { index in
                BufferedTranscriptionWord(text: "word\(index)", start: Double(index) * 0.7,
                    end: index == 0 ? 14 : Double(index) * 0.7 + 0.4)
            }
            return try .aligned(text: words.map(\.text).joined(separator: " "), words: words, segmentEnds: [5, 10])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 15 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText.isEmpty == false)
        #expect(!output.diagnostics.contains { $0.hasPrefix("local_agreement_trim:") })
        #expect(await session.finishTranscript() == (0..<18).map { "word\($0)" }.joined(separator: " "))
        #expect(output.failures == 0)
    }

    @Test("empty normalized punctuation never owns an arbitrary lexical word")
    func whisperPunctuationOnlyOwnership() async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([whisperWindow(["…", "!", "?"]), whisperWindow(["…", "!", "?"]), whisperWindow(["new"])])
        let session = BufferedTranscriptionSession(configuration: .whisperPreview, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let stable = await updates.next()
        #expect(stable?.committedText == "…")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.text == stable?.text)
        #expect(await session.finishTranscript() == nil)
    }

    @Test("cancellation from a Whisper seam diagnostic cannot publish or trim after close")
    func whisperSeamDiagnosticCancellation() async {
        let output = BufferedPreviewOutput()
        let cancellation = BufferedReentrantCancellation()
        let decoder = BufferedWindowSequence([
            whisperWindow(["old", "alpha", "beta", "held", "words", "draft"]),
            whisperWindow(["old", "alpha", "beta", "held", "words", "next"]),
            whisperWindow(["new", "alpha", "beta", "held", "words", "next"])
        ])
        let session = BufferedTranscriptionSession(configuration: .whisperPreview, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: {
                if $0.hasPrefix("local_agreement_seam_rebased:") { cancellation.cancel() }
            })
        cancellation.set(session)
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        _ = await updates.next()
        // Final decode deliberately changes older committed context.
        #expect(await session.finishTranscript() == nil)
        #expect(output.values.count == 2)
        #expect(output.failures == 0)
    }

    @Test("finish flushes short audio and preserves revisable punctuation")
    func shortFinal() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in
            try .aligned(text: "Hello, café!", words: [
                .init(text: "Hello,", start: 0, end: 0.2),
                .init(text: "café!", start: 0.3, end: 0.8)
            ])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        await session.finish()
        #expect(await session.finishTranscript() == "Hello, café!")
        #expect(await session.finishTranscript() == "Hello, café!")
        #expect(output.values.last?.text == "Hello, café!")
        #expect(output.failures == 0)
        #expect(session.diagnostics.receivedSamples == 16_000)
        #expect(session.diagnostics.decodeCount == 1)
        #expect(session.diagnostics.revision == 1)
        #expect(session.diagnostics.closed)
        #expect(output.diagnostics.contains { $0.hasPrefix("decode_completed:samples=16000:elapsed_ms=") && $0.hasSuffix(":final=true") })
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
        let separator = word == "你好" ? "" : " "
        #expect(await session.finishTranscript() == Array(repeating: word, count: 30).joined(separator: separator))
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

    @Test("stop promotes an in-flight full window but never one missing newer audio", arguments: [false, true])
    func stopDuringDecode(additionalAudio: Bool) async {
        let decoder = BufferedHeldDecoder()
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisperPreview, decode: { samples in
            _ = try await decoder.decode(samples)
            let words: [BufferedTranscriptionWord] = samples.count > 32_000
                ? [.init(text: "hello", start: 0, end: 0.5), .init(text: "later", start: 2.1, end: 2.5)]
                : [.init(text: "hello", start: 0, end: 0.5)]
            return try .aligned(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var started = decoder.started.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        #expect(await started.next() == 32_000)
        if additionalAudio { session.enqueue(Array(repeating: 0.2, count: 16_000)) }
        let completion = Task { await session.finishTranscript() }
        // Release the decoder only after finish has closed audio admission.
        // The deadline bounds a broken test without assuming executor ordering.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !session.diagnostics.finishing, ContinuousClock.now < deadline { await Task.yield() }
        #expect(session.diagnostics.finishing)
        #expect(output.values.isEmpty)
        session.enqueue(Array(repeating: 0.2, count: 16_000)) // Capture is closed.
        await decoder.release()
        #expect(await completion.value == (additionalAudio ? "hello later" : "hello"))
        #expect(await decoder.callCount == (additionalAudio ? 2 : 1))
        #expect(session.diagnostics.receivedSamples == (additionalAudio ? 48_000 : 32_000))
        #expect(output.values.count == (additionalAudio ? 2 : 1))
        #expect(output.values.last?.committedText == (additionalAudio ? "hello later" : "hello"))
        #expect(output.values.last?.tail == "")
        #expect(output.failures == 0)
        #expect(output.diagnostics.contains("finish_reused_inflight_decode:samples=32000") == !additionalAudio)
        if additionalAudio {
            #expect(await started.next() == 48_000)
            #expect(output.diagnostics.contains { $0.hasPrefix("decode_completed:samples=32000:") && $0.hasSuffix(":final=false") })
        } else {
            #expect(output.diagnostics.contains { $0.hasPrefix("decode_completed:samples=32000:") && $0.hasSuffix(":final=true") })
        }
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
        #expect(await session.finishTranscript() == nil)
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
        session.enqueue(Array(repeating: 0.2, count: 720_001))
        #expect(await session.finishTranscript() == nil)
        #expect(output.failures == 1)
        #expect(output.values.isEmpty)
    }

    @Test("missing timings fail and all-zero silence bypasses the model")
    func timingsAndSilence() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in .init(text: "unaccounted words", words: []) },
                                                  onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await session.finishTranscript() == nil)
        #expect(output.failures == 1)
        let silent = BufferedTranscriptionSession(decode: { _ in
            Issue.record("Silence must not reach hallucination-prone decoder")
            return .init(text: "", words: [])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        silent.enqueue(Array(repeating: 0, count: 16_000))
        #expect(await silent.finishTranscript() == "")
        #expect(output.values.last?.text == "")
        #expect(silent.diagnostics.receivedSamples == 16_000)
        #expect(silent.diagnostics.decodeCount == 0)
        #expect(silent.diagnostics.revision == 1)
        #expect(silent.diagnostics.closed)
    }

    @Test("completion cannot reuse a valid preview after final decoding fails", arguments: [0, 1, 2])
    func failedCompletionNeverReturnsPartial(mode: Int) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            if samples.count == 32_000 {
                return .init(text: "draft", words: [.init(text: "draft", start: 0, end: 0.5)])
            }
            switch mode {
            case 0: throw BufferedTranscriptionSession.Failure.invalidTimings
            case 1: throw BufferedTranscriptionPreviewDeferral.textAlignmentMismatch
            default: return .init(text: "missing timing", words: [])
            }
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        #expect(await updates.next()?.text == "draft")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await session.finishTranscript() == nil)
        #expect(await session.finishTranscript() == nil)
        #expect(output.failures == 1)
        #expect(output.values.last?.text == "draft")
    }

    @Test("cancelling completion returns without waiting for noncancellable inference")
    func cancelledCompletionWait() async {
        let decoder = BufferedHeldDecoder()
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { try await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var started = decoder.started.stream.makeAsyncIterator()
        var completed = decoder.completed.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let completion = Task { await session.finishTranscript() }
        #expect(await started.next() == 16_000)
        completion.cancel()
        #expect(await completion.value == nil)
        #expect(session.diagnostics.closed)
        await decoder.release()
        _ = await completed.next()
        #expect(await session.finishTranscript() == nil)
        #expect(output.values.isEmpty)
        #expect(output.failures == 0)
    }

    @Test("cancellation in the final callback cannot publish a successful completion")
    func finalCallbackCancellation() async {
        let output = BufferedPreviewOutput()
        let cancellation = BufferedReentrantCancellation()
        let session = BufferedTranscriptionSession(decode: { _ in
            .init(text: "complete", words: [.init(text: "complete", start: 0, end: 0.5)])
        }, onUpdate: {
            output.update($0)
            cancellation.cancel()
        }, onFailure: { output.fail($0) })
        cancellation.set(session)
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await session.finishTranscript() == nil)
        #expect(output.values.last?.text == "complete")
        #expect(output.failures == 0)
    }

    @Test("a session with no accepted audio has no completed transcript")
    func emptyCompletion() async {
        let session = BufferedTranscriptionSession(decode: { _ in
            Issue.record("empty capture must not decode")
            return .init(text: "", words: [])
        }, onUpdate: { _ in Issue.record("empty capture must not emit a final hypothesis") },
        onFailure: { _ in Issue.record("empty capture is not a decoder error") })
        #expect(await session.finishTranscript() == nil)
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
        let deferred = await updates.next()
        #expect(deferred?.text == committed?.text)
        #expect(deferred?.committedText == committed?.committedText)
        #expect(!session.diagnostics.closed)
        #expect(output.failures == 0)
        #expect(await session.finishTranscript() == nil) // No new audio can resolve the ambiguous occurrence.
        #expect(output.failures == 1)
        #expect(output.values.last == deferred)
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

    @Test("a permanently substituted anchor needs two fresh observations and keeps frozen text")
    func changedAnchorRecoversWithAgreement() async {
        func window(_ spelling: String) -> BufferedTranscriptionWindow {
            let words: [BufferedTranscriptionWord] = [
                .init(text: "hello", start: 0.1, end: 0.5),
                .init(text: spelling, start: 1, end: 1.5),
                .init(text: "draft", start: 4, end: 4.5)
            ]
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window("world"), window("world"), window("earth"), window("earth")])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 5 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let stable = await updates.next()
        for _ in 0..<2 {
            session.enqueue(Array(repeating: 0.2, count: 16_000))
            #expect(await updates.next()?.text == stable?.text)
        }
        #expect(output.failures == 0)
        #expect(output.diagnostics.contains { $0.contains("changed_anchor_waiting") })
        #expect(output.diagnostics.contains { $0.hasPrefix("ownership_recovered:") })
        await session.finish()
        #expect(output.values.last?.text == "hello world draft")
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("context grows past normal window and resumes after a missing anchor")
    func missingAnchorGrowsWindowAndRecovers() async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedRecoveryOracle(recoverAt: 9)
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 8 * 16_000
        config.maximumRecoveryWindowSamples = 10 * 16_000
        config.maximumBufferedSamples = 16 * 16_000
        let session = BufferedTranscriptionSession(configuration: config, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(5 * 16_000)).map(Float.init))
        _ = await updates.next()
        var stable: BufferedTranscriptionUpdate?
        for end in 6...9 {
            session.enqueue((((end - 1) * 16_000)..<(end * 16_000)).map(Float.init))
            let update = await updates.next()
            if end == 6 { stable = update }
            if end == 7 || end == 8 {
                #expect(update?.text == stable?.text)
                #expect(update?.committedText == stable?.committedText)
                #expect(!session.diagnostics.closed)
            }
        }
        #expect(await decoder.sampleCounts == [5, 6, 7, 8, 9].map { $0 * 16_000 })
        #expect(output.diagnostics.contains { $0 == "ownership_recovered:samples=144000" })
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.text == "hello world draft")
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("an exhausted recovery window closes without discarding the published hypothesis")
    func boundedRecoveryExhaustion() async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedRecoveryOracle(recoverAt: .infinity)
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 8 * 16_000
        config.maximumRecoveryWindowSamples = 10 * 16_000
        config.maximumBufferedSamples = 16 * 16_000
        let session = BufferedTranscriptionSession(configuration: config, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(5 * 16_000)).map(Float.init))
        _ = await updates.next()
        for end in 6...10 {
            session.enqueue((((end - 1) * 16_000)..<(end * 16_000)).map(Float.init))
            let update = await updates.next()
            #expect((update == nil) == (end == 10))
        }
        await session.finish()
        #expect(output.failures == 1)
        #expect(session.diagnostics.closed)
        #expect(session.diagnostics.receivedSamples == 10 * 16_000)
        #expect(output.values.last?.text == "hello world draft")
        #expect(output.diagnostics.last == "ownership_recovery_exhausted:window_limit")
        #expect(await decoder.sampleCounts == [5, 6, 7, 8, 9, 10].map { $0 * 16_000 })
    }

    @Test("owned onset may expand into a pause only with both neighboring anchors")
    func ownedOnsetExpandsIntoPause() async {
        let initial = Self.pauseExpansionWindow()
        let expanded = Self.pauseExpansionWindow(expanded: true)
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([initial, initial, expanded, expanded])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 198_400)) // 12.4 seconds
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "net new code and")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let revised = await updates.next()
        #expect(revised?.text == "net new code and analyzing if difference.")
        #expect(revised?.committedText == "net new code and analyzing if")
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.committedText == "net new code and analyzing if difference.")
        #expect(!output.diagnostics.contains { $0.contains("ownership_recovery:") })
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("owned onset may shorten with an unchanged end and following seam")
    func ownedOnsetShortensWithinWord() async {
        let first: [BufferedTranscriptionWord] = [
            .init(text: "and", start: 0, end: 0.22),
            .init(text: "analyzing", start: 0.22, end: 0.72),
            .init(text: "if", start: 0.72, end: 1.26),
            .init(text: "there's", start: 1.26, end: 1.44)
        ]
        // The observed 60 -> 61 second seam, relative to 55.6 seconds:
        // "if" moves from 56.32 to 56.64; its end and "there's" stay fixed.
        var shortened = first
        shortened[2] = .init(text: "if", start: 1.04, end: 1.26)
        shortened.append(.init(text: "difference.", start: 4, end: 4.38))
        func window(_ words: [BufferedTranscriptionWord]) -> BufferedTranscriptionWindow {
            .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window(first), window(first), window(shortened), window(shortened)])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 54_400)) // 3.4 seconds
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "and analyzing if")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.text == "and analyzing if there's difference.")
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.committedText == "and analyzing if there's difference.")
        #expect(!output.diagnostics.contains { $0.contains("ownership_recovery:") })
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("owned onset expansion cannot consume speech or lose its following anchor",
          arguments: ["crossed_previous_word", "changed_following_word", "moved_following_word", "changed_owned_word", "moved_owned_end"])
    func ownedOnsetExpansionRequiresContext(change: String) async {
        let initial = Self.pauseExpansionWindow()
        var words = Self.pauseExpansionWindow(expanded: true).words
        switch change {
        case "crossed_previous_word":
            words[3] = .init(text: "and", start: 9.25, end: 10.22)
        case "changed_following_word":
            words[4] = .init(text: "not", start: 10.22, end: 10.72)
        case "moved_following_word":
            words[4] = .init(text: "analyzing", start: 10.60, end: 10.72)
        case "moved_owned_end":
            words[3] = .init(text: "and", start: 9.58, end: 10.60)
        default:
            words[3] = .init(text: "or", start: 9.58, end: 10.22)
        }
        let changed = BufferedTranscriptionWindow(text: words.map(\.text).joined(separator: " "), words: words)
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([initial, initial, changed, changed])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 198_400))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let accepted = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.text == accepted?.text)
        session.cancel()
        #expect(output.failures == 0)
        #expect(output.values.last?.committedText == "net new code and")
    }

    private static func pauseExpansionWindow(expanded: Bool = false) -> BufferedTranscriptionWindow {
        // Observed Turbo seam at 59 -> 60 seconds, expressed relative to the
        // unchanged rolling PCM origin. Only "and" expands into the pause.
        var words: [BufferedTranscriptionWord] = [
            .init(text: "net", start: 8.82, end: 9.04),
            .init(text: "new", start: 9.04, end: 9.16),
            .init(text: "code", start: 9.16, end: 9.58),
            .init(text: "and", start: expanded ? 9.58 : 10.14, end: expanded ? 10.22 : 10.28),
            .init(text: "analyzing", start: expanded ? 10.22 : 10.28, end: expanded ? 10.72 : 10.80),
            .init(text: "if", start: expanded ? 10.72 : 10.80, end: expanded ? 11.26 : 11.30)
        ]
        if expanded { words.append(.init(text: "difference.", start: 13.24, end: 14.38)) }
        return .init(text: words.map(\.text).joined(separator: " "), words: words)
    }

    @Test("owned token splits cannot move the seam into already committed speech", arguments: [true, false])
    func tokenSplitCannotRecoverAcrossWrongBoundary(hasDraft: Bool) async {
        let first: [BufferedTranscriptionWord] = [
            .init(text: "I", start: 0.1, end: 0.5), .init(text: "cannot", start: 1, end: 1.8)
        ] + (hasDraft ? [.init(text: "continue", start: 4, end: 4.5)] : [])
        let split: [BufferedTranscriptionWord] = [
            .init(text: "I", start: 0.1, end: 0.5), .init(text: "can", start: 1, end: 1.2),
            .init(text: "not", start: 1.5, end: 1.8)
        ] + (hasDraft ? [.init(text: "continue", start: 4, end: 4.5)] : [])
        func window(_ words: [BufferedTranscriptionWord]) -> BufferedTranscriptionWindow {
            .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window(first), window(first), window(split), window(split)])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 5 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let stable = await updates.next()
        for _ in 0..<2 {
            session.enqueue(Array(repeating: 0.2, count: 16_000))
            #expect(await updates.next()?.text == stable?.text)
        }
        #expect(output.failures == 0)
        #expect(output.diagnostics.contains { $0.contains("changed_boundary") })
        await session.finish()
        #expect(output.failures == 1)
        #expect(output.values.last?.text == stable?.text)
    }

    @Test("pending PCM has bounded headroom while an extended decode is in flight")
    func recoveryDecodeRetainsQueuedArrivals() async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedRecoveryOracle(recoverAt: 10, holdAt: 10 * 16_000)
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 8 * 16_000
        config.maximumRecoveryWindowSamples = 10 * 16_000
        config.maximumBufferedSamples = 16 * 16_000
        let session = BufferedTranscriptionSession(configuration: config, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        var starts = decoder.started.stream.makeAsyncIterator()
        session.enqueue((0..<(5 * 16_000)).map(Float.init))
        _ = await starts.next()
        _ = await updates.next()
        for end in 6...9 {
            session.enqueue((((end - 1) * 16_000)..<(end * 16_000)).map(Float.init))
            _ = await starts.next()
            _ = await updates.next()
        }
        session.enqueue(((9 * 16_000)..<(10 * 16_000)).map(Float.init))
        #expect(await starts.next() == 10 * 16_000)
        session.enqueue(((10 * 16_000)..<(15 * 16_000)).map(Float.init))
        #expect(output.failures == 0)
        await decoder.release()
        await session.finish()
        #expect(output.failures == 0)
        #expect(session.diagnostics.receivedSamples == 15 * 16_000)
        #expect(output.values.last?.text == "hello world draft")
        #expect(await decoder.maximumInFlight == 1)
        #expect(await decoder.sampleCounts.max() == 10 * 16_000)
    }

    @Test("failed rollover proposals cannot commit text before recovery")
    func failedRollProposalIsTransactional() async {
        let output = BufferedPreviewOutput()
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 8 * 16_000
        config.leftContextSamples = 4 * 16_000
        config.maximumRecoveryWindowSamples = 10 * 16_000
        let session = BufferedTranscriptionSession(configuration: config, decode: { _ in
            .init(text: "hello", words: [.init(text: "hello", start: 0.1, end: 1)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 8 * 16_000))
        let deferred = await updates.next()
        #expect(deferred?.committedText == "")
        #expect(deferred?.tail == "")
        #expect(output.diagnostics.contains { $0.contains("no_roll_progress") })
        #expect(output.failures == 0)
        session.cancel()
        await session.finish()
        #expect(output.failures == 0)
    }

    private func assertMonotonicCommittedPrefixes(_ values: [BufferedTranscriptionUpdate]) {
        for (previous, current) in zip(values, values.dropFirst()) {
            #expect(current.committedText.utf16.starts(with: previous.committedText.utf16))
        }
    }

    @Test("recoverable preview errors preserve text and queued PCM until fresh evidence arrives",
          arguments: [BufferedTranscriptionPreviewDeferral.missingWordTimings, .textAlignmentMismatch, .invalidWordTimings])
    func previewDeferralRecoversWithPendingAudio(reason: BufferedTranscriptionPreviewDeferral) async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedDeferralOracle(reason: reason, rejectFrom: 7, recoverAt: 9, holdAt: 7 * 16_000)
        let session = BufferedTranscriptionSession(decode: { try await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        var starts = decoder.started.stream.makeAsyncIterator()
        session.enqueue((0..<(5 * 16_000)).map(Float.init))
        _ = await starts.next()
        _ = await updates.next()
        session.enqueue(((5 * 16_000)..<(6 * 16_000)).map(Float.init))
        _ = await starts.next()
        let stable = await updates.next()
        #expect(stable?.committedText == "hello world")
        #expect(stable?.tail == " draft")
        session.enqueue(((6 * 16_000)..<(7 * 16_000)).map(Float.init))
        #expect(await starts.next() == 7 * 16_000)
        session.enqueue(((7 * 16_000)..<(9 * 16_000)).map(Float.init))
        await decoder.release()
        let deferred = await updates.next()
        #expect(deferred?.committedText == stable?.committedText)
        #expect(deferred?.tail == stable?.tail)
        #expect(await starts.next() == 9 * 16_000)
        let recovered = await updates.next()
        #expect(recovered?.committedText == stable?.committedText)
        #expect(recovered?.tail == stable?.tail)
        #expect(!session.diagnostics.closed)
        #expect(output.failures == 0)
        #expect(await decoder.sampleCounts == [5, 6, 7, 9].map { $0 * 16_000 })
        #expect(await decoder.firstSamples.allSatisfy { $0 == 0 })
        #expect(await decoder.lastSamples.last == Float(9 * 16_000 - 1))
        #expect(output.diagnostics.contains("preview_deferred:\(reason.rawValue)"))
        session.enqueue(((9 * 16_000)..<(10 * 16_000)).map(Float.init))
        _ = await starts.next()
        #expect(await updates.next()?.committedText == "hello world draft")
        await session.finish()
        #expect(output.failures == 0)
        #expect(session.diagnostics.receivedSamples == 10 * 16_000)
        #expect(output.values.last?.text == "hello world draft")
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("Whisper deferral preserves the small displayed draft and final flush restores every word")
    func smoothedDeferralAndFinalFlush() async throws {
        let output = BufferedPreviewOutput()
        var configuration = BufferedTranscriptionSession.Configuration()
        configuration.smoothWhisperPreviews = true
        let session = BufferedTranscriptionSession(configuration: configuration, decode: { samples in
            if samples.count == 3 * 16_000 { throw BufferedTranscriptionPreviewDeferral.invalidWordTimings }
            return try .aligned(text: "one two three four five", words: (0..<5).map {
                .init(text: ["one", "two", "three", "four", "five"][$0],
                      start: Double($0) * 0.2, end: Double($0 + 1) * 0.2)
            })
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        defer { session.cancel() }
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 2 * 16_000))
        let first = try #require(await updates.next())
        #expect(first.committedText == "")
        #expect(first.text == "one two")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let deferred = try #require(await updates.next())
        #expect(deferred.text == first.text, "Deferral must not expose the hidden raw tail")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        _ = await updates.next()
        #expect(await session.finishTranscript() == "one two three four five")
        #expect(output.failures == 0)
        #expect(output.values.last?.text == "one two three four five")
        #expect(session.diagnostics.receivedSamples == 4 * 16_000)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("permanent preview deferral is bounded at thirty seconds and fails only once")
    func previewDeferralRecoveryLimit() async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedDeferralOracle(reason: .invalidWordTimings, rejectFrom: 0, recoverAt: .infinity)
        let session = BufferedTranscriptionSession(decode: { try await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        var previousEnd = 0
        for seconds in [2, 15, 30] {
            session.enqueue((previousEnd..<(seconds * 16_000)).map(Float.init))
            previousEnd = seconds * 16_000
            let update = await updates.next()
            if seconds < 30 { #expect(update?.text == "") }
            else { #expect(update == nil) }
        }
        await session.finish()
        #expect(session.diagnostics.closed)
        #expect(output.failures == 1)
        #expect(await decoder.sampleCounts == [2, 15, 30].map { $0 * 16_000 })
        #expect(output.diagnostics.last == "ownership_recovery_exhausted:window_limit")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        await session.finish()
        #expect(output.failures == 1)
        #expect(session.diagnostics.receivedSamples == 30 * 16_000)
        #expect(output.values.allSatisfy { $0.text.isEmpty })
    }

    @Test("unusable final short window fails once without publishing a hypothesis")
    func previewDeferralAtFinalization() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in
            throw BufferedTranscriptionPreviewDeferral.textAlignmentMismatch
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        await session.finish()
        #expect(output.failures == 1)
        #expect(output.values.isEmpty)
        #expect(output.diagnostics.last == "ownership_recovery_exhausted:final")
        await session.finish()
        #expect(output.failures == 1)
        #expect(session.diagnostics.decodeCount == 1)
    }

    @Test("cancellation discards an in-flight deferral without callbacks or retry")
    func cancelInFlightPreviewDeferral() async {
        let output = BufferedPreviewOutput()
        let decoder = BufferedDeferralOracle(reason: .missingWordTimings, rejectFrom: 0,
            recoverAt: .infinity, holdAt: 2 * 16_000)
        let session = BufferedTranscriptionSession(decode: { try await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var starts = decoder.started.stream.makeAsyncIterator()
        var completed = decoder.completed.stream.makeAsyncIterator()
        session.enqueue((0..<(2 * 16_000)).map(Float.init))
        _ = await starts.next()
        session.cancel()
        await session.finish()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        await decoder.release()
        _ = await completed.next()
        #expect(output.values.isEmpty)
        #expect(output.failures == 0)
        #expect(output.diagnostics.isEmpty)
        #expect(await decoder.sampleCounts == [2 * 16_000])
        #expect(session.diagnostics.receivedSamples == 2 * 16_000)
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
    private var diagnosticStorage: [String] = []
    var diagnostics: [String] { lock.withLock { diagnosticStorage } }
    func diagnostic(_ value: String) { lock.withLock { diagnosticStorage.append(value) } }
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

private actor BufferedDeferralOracle {
    nonisolated let started = AsyncStream<Int>.makeStream()
    nonisolated let completed = AsyncStream<Void>.makeStream()
    private let reason: BufferedTranscriptionPreviewDeferral
    private let rejectFrom: Double
    private let recoverAt: Double
    private let holdAt: Int?
    private var permit: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var sampleCounts: [Int] = []
    private(set) var firstSamples: [Float] = []
    private(set) var lastSamples: [Float] = []

    init(reason: BufferedTranscriptionPreviewDeferral, rejectFrom: Double, recoverAt: Double, holdAt: Int? = nil) {
        self.reason = reason
        self.rejectFrom = rejectFrom
        self.recoverAt = recoverAt
        self.holdAt = holdAt
    }

    func decode(_ samples: [Float]) async throws -> BufferedTranscriptionWindow {
        sampleCounts.append(samples.count)
        firstSamples.append(samples.first ?? -1)
        lastSamples.append(samples.last ?? -1)
        started.continuation.yield(samples.count)
        if samples.count == holdAt && !released { await withCheckedContinuation { permit = $0 } }
        defer { completed.continuation.yield(()) }
        let base = Double(samples[0]) / 16_000
        let end = base + Double(samples.count) / 16_000
        if end >= rejectFrom && end < recoverAt { throw reason }
        let words: [BufferedTranscriptionWord] = [
            .init(text: "hello", start: 0.1 - base, end: 0.5 - base),
            .init(text: "world", start: 1 - base, end: 1.5 - base),
            .init(text: "draft", start: 4 - base, end: 4.5 - base)
        ].filter { $0.start >= 0 && $0.end <= Double(samples.count) / 16_000 }
        return .init(text: words.map(\.text).joined(separator: " "), words: words)
    }

    func release() { released = true; permit?.resume(); permit = nil }
}

private actor BufferedRecoveryOracle {
    nonisolated let started = AsyncStream<Int>.makeStream()
    private let recoverAt: Double
    private let holdAt: Int?
    private var permit: CheckedContinuation<Void, Never>?
    private var released = false
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var sampleCounts: [Int] = []
    init(recoverAt: Double, holdAt: Int? = nil) { self.recoverAt = recoverAt; self.holdAt = holdAt }
    func decode(_ samples: [Float]) async -> BufferedTranscriptionWindow {
        sampleCounts.append(samples.count)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        started.continuation.yield(samples.count)
        if samples.count == holdAt && !released { await withCheckedContinuation { permit = $0 } }
        defer { inFlight -= 1 }
        let base = Double(samples[0]) / 16_000
        let end = base + Double(samples.count) / 16_000
        let missing = end >= 7 && end < recoverAt
        let values: [(String, Double, Double)] = [
            ("hello", 0.1, 0.5), (missing ? "unmatched" : "world", missing ? 2.5 : 1, missing ? 2.8 : 1.5),
            ("draft", 4, 4.5)
        ]
        let words: [BufferedTranscriptionWord] = values.compactMap { text, start, finish in
            guard start >= base, finish <= end else { return nil }
            return .init(text: text, start: start - base, end: finish - base)
        }
        return .init(text: words.map(\.text).joined(separator: " "), words: words)
    }
    func release() { released = true; permit?.resume(); permit = nil }
}
