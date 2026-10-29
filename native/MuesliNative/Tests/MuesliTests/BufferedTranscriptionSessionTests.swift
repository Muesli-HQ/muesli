import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Buffered transcription")
struct BufferedTranscriptionSessionTests {
    @Test("edited context does not guess an unsupported or ambiguous owned endpoint",
          arguments: ["missing_context", "moved_endpoint", "zero_endpoint", "split_endpoint", "unequal_split_endpoint", "short_split_tail", "overlapping_endpoint", "changed_following", "moved_following"])
    func revisedOwnedTokenSequenceRequiresUniqueBoundary(change: String) async {
        func window(_ words: [BufferedTranscriptionWord]) -> BufferedTranscriptionWindow {
            .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let initial: [BufferedTranscriptionWord] = [
            .init(text: "we", start: 2.0, end: 2.2),
            .init(text: "worked", start: 2.2, end: 2.6),
            .init(text: "weekly", start: 3.0, end: 4.0)
        ] + (change.hasSuffix("following") ? [.init(text: "next", start: 5.2, end: 5.8)] : [])
        var revised: [BufferedTranscriptionWord] = [
            .init(text: change == "missing_context" ? "they" : "we", start: 2.0, end: 2.2),
            .init(text: "all", start: 2.2, end: 2.25),
            .init(text: "worked", start: 2.25, end: 2.6),
            .init(text: "daily", start: 3.0, end: 4.0),
            .init(text: "next", start: 7.0, end: 7.5)
        ]
        if change == "changed_following" { revised[4] = .init(text: "later", start: 5.2, end: 5.8) }
        if change == "moved_following" { revised[4] = .init(text: "next", start: 5.6, end: 5.8) }
        if change == "moved_endpoint" { revised[3] = .init(text: "daily", start: 4.5, end: 5.0) }
        if change == "zero_endpoint" { revised[3] = .init(text: "daily", start: 3.5, end: 3.5) }
        if ["split_endpoint", "unequal_split_endpoint", "short_split_tail"].contains(change) {
            let split = change == "split_endpoint" ? 3.5 : change == "unequal_split_endpoint" ? 3.6 : 3.9
            revised[3] = .init(text: "day", start: 3.0, end: split)
            revised.insert(.init(text: "lee", start: split, end: 4.0), at: 4)
        }
        if change == "overlapping_endpoint" {
            revised.insert(.init(text: "daily", start: 3.1, end: 4.0), at: 4)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window(initial), window(initial), window(revised)])
        var config = BufferedTranscriptionSession.Configuration.whisper
        config.windowSamples = 15 * 16_000
        let session = BufferedTranscriptionSession(configuration: config, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 6 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let stable = await updates.next()
        #expect(stable?.committedText == "we worked weekly")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == stable?.committedText)
        #expect(!output.diagnostics.contains("ownership_realigned:edited_context"))
        session.cancel()
    }

    @Test("Whisper token insertion and endpoint correction preserve committed words and resume new speech",
          arguments: [false, true], [false, true])
    func revisedOwnedTokenSequenceResumes(deleteContextWord: Bool, hasFollowingAnchor: Bool) async {
        // Reduced from captured Turbo hypotheses, with the absolute PCM origin
        // removed. The new "I" and Daly -> daily must not strand the live stream.
        let initial: [BufferedTranscriptionWord] = [
            .init(text: "who", start: 2.56, end: 2.68),
            .init(text: "worked", start: 2.68, end: 2.92),
            .init(text: "with", start: 2.92, end: 3.16),
            .init(text: "Daly.", start: 3.16, end: 3.94)
        ] + (hasFollowingAnchor ? [.init(text: "There's", start: 5.20, end: 5.26)] : [])
        var revised: [BufferedTranscriptionWord] = [
            .init(text: "who", start: 2.56, end: 2.70),
            .init(text: "I", start: 2.70, end: 2.72),
            .init(text: "worked", start: 2.72, end: 2.98),
            .init(text: "with", start: 2.98, end: 3.06),
            .init(text: "daily.", start: 3.06, end: 3.64),
            .init(text: "There's", start: 7.20, end: 7.26),
            .init(text: "a", start: 7.26, end: 7.30),
            .init(text: "few", start: 7.30, end: 7.46),
            .init(text: "things.", start: 7.46, end: 7.94)
        ]
        if hasFollowingAnchor {
            for index in 5..<revised.count {
                let word = revised[index]
                revised[index] = .init(text: word.text, start: word.start - 2, end: word.end - 2)
            }
        }
        if deleteContextWord { revised.removeAll { $0.text == "with" } }
        func window(_ words: [BufferedTranscriptionWord]) -> BufferedTranscriptionWindow {
            .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window(initial), window(initial), window(revised), window(revised)])
        var config = BufferedTranscriptionSession.Configuration.whisper
        config.windowSamples = 15 * 16_000 // keep these reduced hypotheses at one PCM origin
        let session = BufferedTranscriptionSession(configuration: config, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 6 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "who worked with Daly.")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let progressed = await updates.next()
        let expected = "who worked with Daly. There's a few" + (hasFollowingAnchor ? " things." : "")
        #expect(progressed?.committedText == expected)
        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.text == "who worked with Daly. There's a few things.")
        #expect(output.failures == 0)
        #expect(output.diagnostics.contains("ownership_realigned:edited_context"))
        #expect(!output.diagnostics.contains { $0.contains("ownership_recovery:") })
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("Whisper closes a mature prefix at a stable ordered seam before the physical rollover", arguments: [
        "none", "followingSpelling", "followingStart", "followingEnd", "endpointStart", "endpointEnd",
        "zeroEndpoint", "zeroFollowing", "missingFollowing", "shiftedIndex"
    ])
    func whisperStableSeamBeforeRollover(change: String) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisper, decode: { samples in
            let phase = samples.count < 100_000 ? 0 : samples.count < 120_000 ? 1 : 2
            var words: [BufferedTranscriptionWord]
            if phase == 0 {
                words = [.init(text: "DIF", start: 3.28, end: 3.62),
                         .init(text: "means", start: 3.62, end: 4.12)]
            } else if phase == 1 {
                words = [.init(text: "DIF", start: 2.52, end: 3.56),
                         .init(text: "means", start: 3.56, end: change == "zeroEndpoint" ? 3.7 : 4.08),
                         .init(text: "comparing", start: change == "zeroFollowing" ? 4.98 : 4.08,
                               end: change == "zeroFollowing" ? 5.1 : 6.36)]
            } else {
                words = [.init(text: "- Diff", start: 3.26, end: 3.62),
                         .init(text: "means", start: change == "endpointStart" ? 3.9 : 3.62,
                               end: change == "zeroEndpoint" ? 3.62 : change == "endpointEnd" ? 4.5 : 4.10)]
                if change != "missingFollowing" {
                    words.append(.init(text: change == "followingSpelling" ? "contrasting" : "comparing",
                        start: change == "zeroFollowing" ? 5.0 : change == "followingStart" ? 4.5 : 4.10,
                        end: change == "zeroFollowing" ? 5.0 : change == "followingEnd" ? 6.9 : 6.36))
                }
                if change == "shiftedIndex" { words.insert(.init(text: "the", start: 2.9, end: 3.1), at: 0) }
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) },
        onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 91_520)) // 5.72 seconds
        #expect(await updates.next()?.committedText == "")
        session.enqueue(Array(repeating: 0.2, count: 17_600)) // 6.82 seconds
        #expect(await updates.next()?.committedText == "")
        session.enqueue(Array(repeating: 0.2, count: 17_600)) // 7.92 seconds: no 8-second decode
        #expect(await updates.next()?.committedText == (change == "none" ? "- Diff means" : ""))
        #expect(session.diagnostics.receivedSamples < BufferedTranscriptionSession.Configuration.whisper.windowSamples)
        if change == "none" {
            #expect(output.diagnostics.contains { $0.contains("stableSeam=2") && $0.contains("roll=false") })
        }
        let result = await session.finishForReuse()
        let expected = (change == "shiftedIndex" ? "the " : "") + "- Diff means"
            + (change == "missingFollowing" ? "" : change == "followingSpelling" ? " contrasting" : " comparing")
        #expect(result.canReuse && result.text == expected)
        #expect(output.failures == 0)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("Parakeet emission-point words retain their live ownership policy")
    func parakeetEmissionPointsStillCommit() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in
            .init(text: "go again", words: [.init(text: "go", start: 0.2, end: 0.2),
                .init(text: "again", start: 0.6, end: 0.6)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 4 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "go again")
        let result = await session.finishForReuse()
        #expect(result.canReuse && result.text == "go again")
    }

    @Test("a zero-duration leading word cannot strand streaming on a lone anchor")
    func zeroDurationLeadingAnchorDoesNotStall() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisper, decode: { samples in
            let corrected = samples.count >= 6 * 16_000
            return .init(text: "Thank you.", words: [
                .init(text: "Thank", start: corrected ? 0.5 : 0, end: corrected ? 0.9 : 0),
                .init(text: "you.", start: 1.0, end: 2.5)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) },
        onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 4 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "")
        for _ in 6...7 {
            session.enqueue(Array(repeating: 0.2, count: 16_000))
            _ = await updates.next()
        }
        #expect(output.values.last?.committedText == "Thank you.")
        #expect(!output.diagnostics.contains { $0.contains("ownership_recovery") })
        let result = await session.finishForReuse()
        #expect(result.canReuse && result.text == "Thank you.")
        #expect(output.failures == 0)
    }

    @Test("Whisper retains an owned word's onset when its duration crosses an empty-tail crop")
    func whisperEmptyTailRetainsCrossingOwnedWord() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisper, decode: { samples in
            let base = Double(samples.first ?? 0) / 16_000
            let end = base + Double(samples.count) / 16_000
            var events: [(String, Double, Double)] = [("hello", 1, 1.5)]
            if end <= 8 {
                events.append(("long", 4.5, 5.8))
                if end <= 7 { events.append(("following", 5.9, 6)) }
            } else {
                // More context extends the owned word through a pause. If its
                // onset was cropped, the decoder retimes the surviving suffix
                // at the new window's start instead of the original occurrence.
                events.append(("long", max(4.5, base), 7.5))
                events.append(("resumed", 8, 8.6))
            }
            let words = events.compactMap { text, start, finish -> BufferedTranscriptionWord? in
                guard start >= base else { return nil }
                return .init(text: text, start: start - base, end: finish - base)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(6 * 16_000)).map(Float.init))
        _ = await updates.next()
        session.enqueue(((6 * 16_000)..<(7 * 16_000)).map(Float.init))
        #expect(await updates.next()?.committedText == "hello long")
        // The following draft disappears at the full-window boundary. The owned
        // word still spans its 5-second crop and requires its left context.
        for second in 8...10 {
            session.enqueue((((second - 1) * 16_000)..<(second * 16_000)).map(Float.init))
            _ = await updates.next()
        }
        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.text == "hello long resumed")
        #expect(output.failures == 0)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("Whisper retains lexical ownership when an older owned word outlasts the four saved anchors")
    func whisperOlderOwnedWordCannotReappearAfterEmptyTailCrop() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisper, decode: { samples in
            let base = Double(samples.first ?? 0) / 16_000
            let end = base + Double(samples.count) / 16_000
            // End times are not required to be monotonic by the decoder
            // contract. The long owned word leaves the last-four anchor list.
            var events: [(String, Double, Double)] = [
                ("long", end <= 8 ? 1 : max(1, base), end <= 8 ? 5.8 : 7.5),
                ("a", 1.5, 1.7), ("b", 2, 2.2), ("c", 2.5, 2.7),
                ("d", 3, 3.2), ("e", 3.5, 3.7)]
            if end <= 7 { events.append(("following", 4, 4.2)) }
            if end > 8 { events.append(("resumed", 8, 8.6)) }
            let words = events.compactMap { text, start, finish -> BufferedTranscriptionWord? in
                guard start >= base else { return nil }
                return .init(text: text, start: start - base, end: finish - base)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(6 * 16_000)).map(Float.init))
        _ = await updates.next()
        session.enqueue(((6 * 16_000)..<(7 * 16_000)).map(Float.init))
        #expect(await updates.next()?.committedText == "long a b c d e")
        for second in 8...10 {
            session.enqueue((((second - 1) * 16_000)..<(second * 16_000)).map(Float.init))
            _ = await updates.next()
        }
        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.text == "long a b c d e resumed")
        #expect(output.failures == 0)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("Whisper lexical agreement emits small groups for five minutes despite punctuation revisions")
    func whisperPunctuationCadenceAcrossFiveMinutes() async {
        let config = BufferedTranscriptionSession.Configuration.whisper
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: config, decode: { samples in
            let base = Double(samples.first ?? 0) / 16_000
            let end = base + Double(samples.count) / 16_000
            let upper = Int(end.rounded()) % 2 == 0
            let words: [BufferedTranscriptionWord] = (0..<300).compactMap { index in
                let start = Double(index) + 0.1
                let finish = start + 0.4
                guard start >= base, finish <= end else { return nil }
                // Includes deliberate repeats; spelling changes at the edge
                // must not merge occurrences or reset otherwise stable agreement.
                let text = upper ? "Go," : "go"
                return .init(text: text, start: start - base, end: finish - base, confidence: 0.95)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<32_000).map(Float.init))
        _ = await updates.next()
        var previousCount = 0
        var stalledSteps = 0
        for second in 3...300 {
            session.enqueue((((second - 1) * 16_000)..<(second * 16_000)).map(Float.init))
            guard let update = await updates.next() else { break }
            let count = update.committedText.split(separator: " ").count
            if second >= 5 {
                // The capped rollover snapshot can end between sample arrivals.
                // Permit that one-step boundary, never a sentence-length hold.
                #expect((second - 2...second - 1).contains(count), "Stable words stalled at audio second \(second)")
                #expect(count - previousCount <= 2, "Committed a sentence-sized catch-up group")
                stalledSteps = count == previousCount ? stalledSteps + 1 : 0
                #expect(stalledSteps <= 1)
            }
            previousCount = count
        }
        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.text.split(separator: " ").count == 300)
        #expect(output.failures == 0)
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("Whisper lexical agreement still rejects changed words and occurrences", arguments: ["spelling", "internalPunctuation", "timing", "punctuationOnly", "numberSign", "leadingDecimal", "decimalComma", "percentage", "codeSuffix", "primeUnit"])
    func whisperAgreementRequiresSameWordAndOccurrence(change: String) async {
        var config = BufferedTranscriptionSession.Configuration()
        config.lexicalAgreement = true
        let variants: [String: (String, String)] = ["spelling": ("go", "stop"), "internalPunctuation": ("can't", "cant"),
            "punctuationOnly": ("-", ","), "numberSign": ("-1", "1"), "leadingDecimal": (".5", "5"),
            "decimalComma": (",5", "5"), "percentage": ("50%", "50"), "codeSuffix": ("C#", "C"), "primeUnit": ("2′", "2")]
        let (original, revised) = variants[change] ?? ("go", "go")
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: config, decode: { samples in
            let first = samples.count == 2 * 16_000
            let text = first ? original : revised
            let start = !first && change == "timing" ? 0.5 : 0.1
            return .init(text: text + " now", words: [.init(text: text, start: start, end: start + 0.4),
                .init(text: "now", start: 1.0, end: 1.4)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 2 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "")
        let result = await session.finishForReuse()
        #expect(result.canReuse && result.text == revised + " now")
    }

    @Test("a zero-timed word on the silent ownership edge survives rollover", arguments: [false, true])
    func zeroDurationAtSilentBoundaryIsNotDiscarded(hasEarlierWord: Bool) async {
        let output = BufferedPreviewOutput()
        var configuration = BufferedTranscriptionSession.Configuration.whisper
        configuration.windowSamples = 240_000
        let session = BufferedTranscriptionSession(configuration: configuration, decode: { samples in
            let base = Double(samples.first ?? 0) / 16_000
            let end = base + Double(samples.count) / 16_000
            let events: [(String, Double, Double)] = (hasEarlierWord ? [("hello", 1, 2)] : [])
                + [("I", 12, 12)] + (end > 15 ? [("agree", 12.1, 12.5)] : [])
            let words: [BufferedTranscriptionWord] = events.compactMap { text, start, finish in
                guard start >= base else { return nil }
                return .init(text: text, start: start - base, end: finish - base)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(15 * 16_000)).map(Float.init))
        _ = await updates.next()
        for second in 16...17 {
            session.enqueue((((second - 1) * 16_000)..<(second * 16_000)).map(Float.init))
            _ = await updates.next()
        }
        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.text == (hasEarlierWord ? "hello I agree" : "I agree"))
        #expect(output.failures == 0)
    }

    @Test("Whisper only uses positive-duration following context before the age cutoff", arguments: [false, true])
    func whisperFollowingWordConfirmsPrefix(zeroDurationFollower: Bool) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisper, decode: { _ in
            .init(text: "hello world again", words: [
                .init(text: "hello", start: 0.3, end: 0.6),
                .init(text: "world", start: 0.7, end: 1.2),
                .init(text: "again", start: 1.3, end: zeroDurationFollower ? 1.3 : 1.8)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        #expect(await updates.next()?.committedText == "")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == (zeroDurationFollower ? "" : "hello world"))
        let result = await session.finishForReuse()
        #expect(result.canReuse && result.text == "hello world again")
    }

    @Test("Whisper waits for a corroborated initial group after a speculative pause word", arguments: ["zero", "punctuation", "changed"])
    func whisperInitialGroupSurvivesPauseHallucination(kind: String) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisper, decode: { samples in
            let base = Double(samples.first ?? 0) / 16_000
            let end = base + Double(samples.count) / 16_000
            let initial: [(String, Double, Double)] = kind == "punctuation"
                ? [(".", 1.92, 3.0), ("-", 3.0, 3.32)]
                : [("Thank", 1.92, 3.32), ("you", 3.32, 3.32)]
            let changed = kind == "changed" && end >= 10
            let events: [(String, Double, Double)] = end <= 8 ? initial
                : [(changed ? "other" : "diff", 7.4, 7.7), ("means", 7.7, 8.2), ("comparing", 8.2, 8.8)]
            let words = events.filter { $0.1 >= base }.map {
                BufferedTranscriptionWord(text: $0.0, start: $0.1 - base, end: $0.2 - base)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) },
        onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(8 * 16_000)).map(Float.init))
        #expect(await updates.next()?.committedText == "")
        for second in 9...10 {
            session.enqueue((((second - 1) * 16_000)..<(second * 16_000)).map(Float.init))
            _ = await updates.next()
        }
        #expect(output.values.last?.committedText == (kind == "changed" ? "" : "diff means"))
        let result = await session.finishForReuse()
        #expect(result.canReuse && result.text == (kind == "changed" ? "other means comparing" : "diff means comparing"))
        #expect(output.failures == 0)
        #expect(!output.diagnostics.contains { $0.contains("missing_anchor") })
    }

    @Test("Whisper confirms a single real word before a long pause without exhausting recovery")
    func whisperSingleWordWithLongPause() async {
        let output = BufferedPreviewOutput()
        let events: [(String, Double, Double)] = [("yes", 0.1, 0.5), ("later", 40.1, 40.5), ("now", 41.1, 41.5)]
        let session = BufferedTranscriptionSession(configuration: .whisper, decode: { samples in
            let base = BufferedTimedAudio.origin(samples)
            let end = base + Double(samples.count) / 16_000
            let words = events.filter { $0.1 >= base && $0.2 <= end }.map {
                BufferedTranscriptionWord(text: $0.0, start: $0.1 - base, end: $0.2 - base)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(BufferedTimedAudio.samples(0..<32_000, speech: events.map { $0.1..<$0.2 }))
        _ = await updates.next()
        for second in 3...44 {
            session.enqueue(BufferedTimedAudio.samples(((second - 1) * 16_000)..<(second * 16_000), speech: events.map { $0.1..<$0.2 }))
            guard let update = await updates.next() else { break }
            if second == 4 { #expect(update.committedText == "yes") }
        }
        let result = await session.finishForReuse()
        #expect(result.canReuse && result.text == "yes later now")
        #expect(output.failures == 0)
    }

    @Test("Whisper retires old silent context only when no unfinished word needs it", arguments: [false, true])
    func whisperRetiresOwnedPauseContext(hasPendingWord: Bool) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: .whisper, decode: { samples in
            let base = Double(samples.first ?? 0) / 16_000
            output.diagnostic("origin=\(base)")
            let events: [(String, Double, Double)] = [("all", 0.5, 1), ("right", 1, 1.5)]
                + (hasPendingWord ? [("later", 5, 6)] : [])
            let words = events.filter { $0.1 >= base }.map {
                BufferedTranscriptionWord(text: $0.0, start: $0.1 - base, end: $0.2 - base)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(8 * 16_000)).map(Float.init))
        #expect(await updates.next()?.committedText == "all right")
        session.enqueue(((8 * 16_000)..<(9 * 16_000)).map(Float.init))
        _ = await updates.next()
        #expect(output.diagnostics.contains("origin=\(hasPendingWord ? 4.0 : 5.0)"))
        let result = await session.finishForReuse()
        #expect(result.canReuse && result.text == (hasPendingWord ? "all right later" : "all right"))
        #expect(output.failures == 0)
    }

    @Test("empty rolling recognition retains audible words for later context")
    func emptyRollRetainsUnrecognizedAudio() async {
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 64_000
        config.rightContextSamples = 8_000
        config.leftContextSamples = 4_000
        config.maximumRecoveryWindowSamples = 128_000
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: config, decode: { samples in
            samples.count >= 80_000
                ? .init(text: "hello", words: [.init(text: "hello", start: 0.25, end: 0.75, confidence: 0.99)])
                : .init(text: "", words: [])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 64_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let recovered = await updates.next()
        #expect(recovered?.committedText == "hello")
        let result = await session.finishForReuse()
        #expect(result.completed && result.canReuse)
        #expect(result.text == "hello")
        #expect(result.decodedThroughSample == 80_000)
    }

    @Test("unresolved empty audible rolls fail without claiming coverage", arguments: [false, true])
    func unresolvedEmptyRollCannotComplete(reachLimit: Bool) async {
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 64_000
        config.rightContextSamples = 8_000
        config.leftContextSamples = 4_000
        config.maximumRecoveryWindowSamples = 80_000
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: config,
            decode: { _ in .init(text: "", words: []) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) },
            onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 64_000))
        _ = await updates.next()
        if reachLimit {
            session.enqueue(Array(repeating: 0.2, count: 16_000))
            #expect(await updates.next() == nil)
            #expect(output.diagnostics.contains("ownership_recovery_exhausted:window_limit"))
        }
        let result = await session.finishForReuse()
        #expect(!result.completed && !result.canReuse)
        #expect(result.fallbackReason == .transcriptionFailed)
        #expect(result.decodedThroughSample == 0)
    }

    @Test("a word at the audio origin survives preview agreement and finalization", arguments: [false, true])
    func zeroDurationFirstWord(finalOnly: Bool) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in
            .init(text: "I agree", words: [
                .init(text: "I", start: 0, end: 0, confidence: 0.99),
                .init(text: "agree", start: 0.1, end: 0.5, confidence: 0.99)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: (finalOnly ? 1 : 5) * 16_000))
        if !finalOnly {
            let first = await updates.next()
            #expect(first?.text == "I agree")
            #expect(first?.committedText == "")
            session.enqueue(Array(repeating: 0.2, count: 16_000))
            let agreed = await updates.next()
            #expect(agreed?.committedText == "I agree")
        }
        let result = await session.finishForReuse()
        #expect(result.completed && result.canReuse)
        #expect(result.text == "I agree")
        #expect(result.decodedThroughSample == result.receivedSamples)
        #expect(result.diagnostics.committedWordCount == 2)
        #expect(result.diagnostics.qualityConcern == (finalOnly ? .unsupportedWordTiming : nil))
    }

    @Test("confidence uncertainty remains diagnostic while completed raw text is reused", arguments: ["strong", "missing", "low", "nan", "negative", "aboveOne"])
    func reuseConfidence(kind: String) async {
        let confidence: Float? = switch kind {
        case "strong": 0.95
        case "missing": nil
        case "low": 0.1
        case "nan": .nan
        case "negative": -0.1
        default: 1.1
        }
        let session = BufferedTranscriptionSession(decode: { _ in
            .init(text: "hello", words: [.init(text: "hello", start: 0.1, end: 0.5, confidence: confidence)])
        }, onUpdate: { _ in }, onFailure: { _ in })
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let result = await session.finishForReuse()
        #expect(result.completed)
        #expect(result.text == "hello")
        #expect(result.receivedSamples == 16_000 && result.decodedThroughSample == 16_000)
        #expect(result.canReuse)
        #expect(result.fallbackReason == nil)
        let expected: BufferedTranscriptionSession.ReuseFallbackReason? = switch kind {
        case "strong": nil
        case "missing": .missingConfidence
        case "low": .lowConfidence
        default: .invalidConfidence
        }
        #expect(result.diagnostics.qualityConcern == expected)
        #expect(result.diagnostics.committedWordCount == 1)
    }

    @Test("growing audio agreement supplies moderate-confidence telemetry")
    func reuseAgreedConfidence() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in
            .init(text: "hello", words: [.init(text: "hello", start: 0.1, end: 0.5, confidence: 0.3)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 5 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        _ = await updates.next()
        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.diagnostics.agreedWordCount == 1)
        #expect(result.diagnostics.unagreedWordCount == 0)
    }

    @Test("identical final decode does not manufacture confidence agreement")
    func reuseSameAudioIsNotAgreement() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in
            .init(text: "hello", words: [.init(text: "hello", start: 0.1, end: 0.5, confidence: 0.3)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 5 * 16_000))
        _ = await updates.next()
        let result = await session.finishForReuse()
        #expect(result.completed && result.canReuse)
        #expect(result.fallbackReason == nil)
        #expect(result.diagnostics.qualityConcern == .lowConfidence)
        #expect(result.diagnostics.agreedWordCount == 0)
    }

    @Test("unsupported context and isolated zero-duration words retain quality telemetry", arguments: [false, true])
    func reuseUnsupportedFinal(zeroDuration: Bool) async {
        let session = BufferedTranscriptionSession(decode: { _ in
            .init(text: "hello", words: [.init(text: "hello", start: 0.1,
                end: zeroDuration ? 0.1 : 5, confidence: 0.99)])
        }, onUpdate: { _ in }, onFailure: { _ in })
        session.enqueue(Array(repeating: 0.2, count: 6 * 16_000))
        let result = await session.finishForReuse()
        #expect(result.completed && result.canReuse)
        #expect(result.fallbackReason == nil)
        #expect(result.diagnostics.qualityConcern == (zeroDuration ? .unsupportedWordTiming : .unagreedContextTooLong))
    }

    @Test("reuse cancellation releases a waiter before an uncooperative decode completes")
    func reuseCancellation() async {
        let decoder = BufferedHeldDecoder()
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { try await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var started = decoder.started.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await started.next()
        let task = Task { await session.finishForReuse() }
        task.cancel()
        let result = await task.value
        #expect(!result.canReuse && !result.completed)
        #expect(result.fallbackReason == .cancelled)
        #expect(result.receivedSamples == 32_000)
        #expect(output.values.isEmpty)
        await decoder.release()
    }

    @Test("failure, overrun, and unresolved ownership never yield reusable text", arguments: ["failure", "overrun", "deferral"])
    func reuseFailure(kind: String) async {
        let session = BufferedTranscriptionSession(decode: { _ in
            if kind == "deferral" { throw BufferedTranscriptionPreviewDeferral.invalidWordTimings }
            throw BufferedTranscriptionSession.Failure.invalidTimings
        }, onUpdate: { _ in }, onFailure: { _ in })
        session.enqueue(Array(repeating: 0.2, count: kind == "overrun" ? 720_001 : 16_000))
        let result = await session.finishForReuse()
        #expect(!result.completed && !result.canReuse)
        #expect(result.fallbackReason == .transcriptionFailed)
    }

    @Test("empty recognition over nonzero audio is diagnostic, not missing coverage")
    func reuseEmptyCoverage() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            samples.count < 48_000 ? .init(text: "", words: []) :
                .init(text: "hello", words: [.init(text: "hello", start: 2, end: 2.5, confidence: 0.99)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await session.finishForReuse().canReuse)
        for amplitude: Float in [0, 0.2] {
            let empty = BufferedTranscriptionSession(decode: { _ in .init(text: "", words: []) },
                onUpdate: { _ in }, onFailure: { _ in })
            empty.enqueue(Array(repeating: amplitude, count: 16_000))
            let result = await empty.finishForReuse()
            #expect(result.completed)
            #expect(result.canReuse)
            #expect(result.fallbackReason == nil)
            #expect(result.diagnostics.qualityConcern == (amplitude == 0 ? nil : .unverifiedEmptyAudio))
        }
    }

    @Test("owned-word revision stays diagnostic and finalization preserves frozen transcript")
    func reuseOwnedRevision() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let first = samples.count >= 7 * 16_000 ? "hallo" : "hello"
            return .init(text: "\(first) world draft", words: [
                .init(text: first, start: 0.1, end: 0.5, confidence: 0.99),
                .init(text: "world", start: 1, end: 1.5, confidence: 0.99),
                .init(text: "draft", start: 4, end: 4.5, confidence: 0.99)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 5 * 16_000))
        _ = await updates.next()
        for _ in 0..<2 {
            session.enqueue(Array(repeating: 0.2, count: 16_000))
            _ = await updates.next()
        }
        let result = await session.finishForReuse()
        #expect(result.completed && result.canReuse)
        #expect(result.text == "hello world draft")
        #expect(result.fallbackReason == nil)
        #expect(result.diagnostics.qualityConcern == .committedTranscriptChanged)
    }

    @Test("failed rollover restores confidence bookkeeping with its text and audio checkpoint")
    func reuseQualityRollback() async {
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 96_000
        config.updateSamples = 32_000
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: config, decode: { samples in
            let base = Double(samples[0]) / 16_000
            let confidence: Float = base == 0 && samples.count == 96_000 ? 0.01 : 0.99
            let words: [BufferedTranscriptionWord] = [("first", 0.1, 0.5), ("second", 2.8, 3.5), ("third", 6.0, 6.5)].compactMap { text, start, end in
                guard start >= base, end <= base + Double(samples.count) / 16_000 else { return nil }
                return .init(text: text, start: start - base, end: end - base, confidence: confidence)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<96_000).map(Float.init))
        _ = await updates.next()
        #expect(output.values.last?.text == "")
        #expect(session.knownReuseFallbackReason == nil)
        session.enqueue((96_000..<128_000).map(Float.init))
        _ = await updates.next()
        let result = await session.finishForReuse()
        // The later strong words still form a long unsupported run; the
        // rejected low-confidence proposal must not pollute its diagnostics.
        #expect(result.completed && result.canReuse)
        #expect(result.fallbackReason == nil)
        #expect(result.diagnostics.qualityConcern == .unagreedContextTooLong)
        #expect(result.text == "first second third")
        #expect(result.diagnostics.committedWordCount == 3)
        #expect(result.diagnostics.lowConfidenceCount == 0)
        #expect(result.diagnostics.minimumConfidence == 0.99)
        #expect(result.diagnostics.discardedSamples > 0)
    }

    @Test("reuse quality survives retired windows and preserves every repeated word", arguments: [false, true])
    func reuseAcrossRolls(earlyLowConfidence: Bool) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let base = Double(samples[0]) / 16_000
            let end = base + Double(samples.count) / 16_000
            let words: [BufferedTranscriptionWord] = (0..<30).compactMap { index in
                let start = Double(index) + 0.1
                let finish = Double(index) + 0.7
                guard start >= base, finish <= end else { return nil }
                return .init(text: "go", start: start - base, end: finish - base,
                    confidence: earlyLowConfidence && index == 0 ? 0.1 : 0.99)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<32_000).map(Float.init))
        _ = await updates.next()
        for second in 2..<30 {
            session.enqueue(((second * 16_000)..<((second + 1) * 16_000)).map(Float.init))
            _ = await updates.next()
        }
        let result = await session.finishForReuse()
        #expect(result.completed)
        #expect(result.canReuse)
        #expect(result.fallbackReason == nil)
        #expect(result.diagnostics.qualityConcern == (earlyLowConfidence ? .lowConfidence : nil))
        #expect(result.text == Array(repeating: "go", count: 30).joined(separator: " "))
        #expect(result.diagnostics.committedWordCount == 30)
        #expect(result.diagnostics.discardedSamples > 15 * 16_000)
        #expect(result.decodedThroughSample == 30 * 16_000)
        #expect(result.diagnostics.lowConfidenceCount == (earlyLowConfidence ? 1 : 0))
    }

    @Test("final callback cancellation invalidates reuse and empty sessions have no coverage")
    func reuseReentrantCancellationAndNoAudio() async {
        let cancellation = BufferedReentrantCancellation()
        let session = BufferedTranscriptionSession(decode: { _ in
            .init(text: "hello", words: [.init(text: "hello", start: 0.1, end: 0.5, confidence: 0.99)])
        }, onUpdate: { _ in cancellation.cancel() }, onFailure: { _ in })
        cancellation.set(session)
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let cancelled = await session.finishForReuse()
        #expect(!cancelled.canReuse && !cancelled.completed)
        #expect(cancelled.fallbackReason == .cancelled)
        let empty = BufferedTranscriptionSession(decode: { _ in .init(text: "", words: []) },
            onUpdate: { _ in }, onFailure: { _ in })
        let result = await empty.finishForReuse()
        #expect(!result.canReuse && !result.completed)
        #expect(result.fallbackReason == .noAudio)
        #expect(result.receivedSamples == 0)
    }

    @Test("reuse keeps independent later-word agreement after an earlier draft revision")
    func reuseIndependentWordAgreement() async {
        let output = BufferedPreviewOutput()
        var config = BufferedTranscriptionSession.Configuration()
        config.smoothWhisperPreviews = true
        let session = BufferedTranscriptionSession(configuration: config, decode: { samples in
            let first = samples.count <= 32_000 ? "old" : "new"
            return .init(text: "\(first) stable", words: [
                .init(text: first, start: 0.1, end: 0.5, confidence: 0.99),
                .init(text: "stable", start: 1, end: 1.5, confidence: 0.3)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        _ = await updates.next()
        #expect(output.values.last?.committedText == "")
        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.text == "new stable")
        #expect(result.diagnostics.agreedWordCount == 1)
        #expect(result.diagnostics.unagreedWordCount == 1)
    }

    @Test("reuse measures separate unsupported runs without counting intervening agreed speech")
    func reuseSeparateUnsupportedRuns() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let revised = samples.count > 8 * 16_000
            let first = revised ? "new" : "old"
            let last = revised ? "end" : "ending"
            return .init(text: "\(first) stable \(last)", words: [
                .init(text: first, start: 0.1, end: 0.5, confidence: 0.99),
                .init(text: "stable", start: 3, end: 3.5, confidence: 0.3),
                .init(text: last, start: 7, end: 7.5, confidence: 0.99)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 8 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        _ = await updates.next()
        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.diagnostics.maximumUnagreedSpan == 0.5)
        #expect(result.diagnostics.agreedWordCount == 1)
    }

    @Test("reuse agreement cannot choose ambiguous repeats or reuse a split token", arguments: [false, true])
    func reuseAmbiguousOrSplitWords(split: Bool) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let initial = samples.count <= 32_000
            let words: [BufferedTranscriptionWord]
            if split {
                words = initial ? [.init(text: "cannot", start: 0.1, end: 0.5, confidence: 0.3)] : [
                    .init(text: "can", start: 0.1, end: 0.3, confidence: 0.3),
                    .init(text: "not", start: 0.3, end: 0.5, confidence: 0.3)]
            } else {
                words = initial ? [
                    .init(text: "go", start: 0.1, end: 0.2, confidence: 0.3),
                    .init(text: "go", start: 0.3, end: 0.4, confidence: 0.3)] : [
                    .init(text: "go", start: 0.2, end: 0.3, confidence: 0.3)]
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        _ = await updates.next()
        let result = await session.finishForReuse()
        #expect(result.completed && result.canReuse)
        #expect(result.fallbackReason == nil)
        #expect(result.diagnostics.qualityConcern == .lowConfidence)
        #expect(result.diagnostics.agreedWordCount == 0)
    }

    @Test("unsupported confidence context accumulates across separate forced commitment batches")
    func reuseUnsupportedRunAcrossBatches() async {
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 6 * 16_000
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: config, decode: { samples in
            let base = Double(samples[0]) / 16_000
            let end = base + Double(samples.count) / 16_000
            // Each nonfinal window reveals only its mature words. Thus each
            // small forced batch is strong but has no earlier agreeing tail.
            let visibleEnd = end >= 12 ? end : end - 3
            let words: [BufferedTranscriptionWord] = (0..<12).compactMap { index in
                let start = Double(index) + 0.1
                let finish = Double(index) + 0.3
                guard start >= base, finish <= visibleEnd else { return nil }
                return .init(text: "word\(index)", start: start - base, end: finish - base, confidence: 0.99)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        session.enqueue((0..<(12 * 16_000)).map(Float.init))
        let result = await session.finishForReuse()
        #expect(result.completed && result.canReuse)
        #expect(result.fallbackReason == nil)
        #expect(result.diagnostics.qualityConcern == .unagreedContextTooLong)
        #expect(result.diagnostics.maximumUnagreedSpan > 4)
        #expect(result.diagnostics.lowConfidenceCount == 0)
        #expect(result.diagnostics.agreedWordCount == 0)
        #expect(output.values.count > 2)
    }

    @Test("reuse agreement recognizes punctuation and case revisions without weakening live commitment")
    func reuseCaseAndPunctuationAgreement() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let word = samples.count <= 32_000 ? "hello" : "Hello!"
            return .init(text: word, words: [.init(text: word, start: 0.1, end: 0.5, confidence: 0.3)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        _ = await updates.next()
        #expect(output.values.last?.committedText == "")
        let result = await session.finishForReuse()
        #expect(result.canReuse)
        #expect(result.text == "Hello!")
        #expect(result.diagnostics.agreedWordCount == 1)
    }

    @Test("reuse quality tolerates trailing silence extension but not a new timed occurrence", arguments: ["extension", "shifted", "disjoint"])
    func reuseOnsetEvidence(kind: String) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let initial = samples.count <= 32_000
            let start = initial ? 0.5 : kind == "shifted" ? 0.9 : kind == "disjoint" ? 0.7 : 0.5
            let end = initial ? 0.6 : kind == "extension" ? 0.92 : 1.1
            return .init(text: initial ? "out?" : "out.", words: [
                .init(text: initial ? "out?" : "out.", start: start, end: end, confidence: 0.424)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        _ = await updates.next()
        let result = await session.finishForReuse()
        #expect(result.completed)
        #expect(result.canReuse)
        #expect(result.fallbackReason == nil)
        #expect(result.diagnostics.qualityConcern == (kind == "extension" ? nil : .lowConfidence))
        #expect(result.diagnostics.agreedWordCount == (kind == "extension" ? 1 : 0))
    }

    @Test("empty recognition preserves quality telemetry while decoder failure remains structural", arguments: [false, true])
    func structuralFailureAfterQualityConcern(decoderFailure: Bool) async {
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 6 * 16_000
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: config, decode: { samples in
            if samples.first == 0 {
                return .init(text: "hello", words: [.init(text: "hello", start: 0.1, end: 0.5, confidence: 0.01)])
            }
            if decoderFailure { throw BufferedTranscriptionSession.Failure.invalidTimings }
            return .init(text: "", words: [])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(6 * 16_000)).map(Float.init))
        _ = await updates.next()
        #expect(session.knownReuseFallbackReason == nil)
        #expect(session.reuseDiagnostics.qualityConcern == .lowConfidence)
        #expect(session.currentTranscript == "hello")
        let result = await session.finishForReuse()
        #expect(result.canReuse == !decoderFailure)
        #expect(result.completed == !decoderFailure)
        #expect(result.fallbackReason == (decoderFailure ? .transcriptionFailed : nil))
        #expect(result.diagnostics.qualityConcern == .lowConfidence)
        #expect(result.text == "hello")
        #expect(result.receivedSamples == 96_000)
    }

    @Test("cancelled completion retains the latest raw tail for explicit recovery")
    func cancelledCompletionRetainsRawText() async {
        var config = BufferedTranscriptionSession.Configuration()
        config.smoothWhisperPreviews = true
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(configuration: config, decode: { _ in
            .init(text: "one two three four", words: [
                .init(text: "one", start: 0.1, end: 0.3),
                .init(text: "two", start: 0.4, end: 0.6),
                .init(text: "three", start: 0.7, end: 0.9),
                .init(text: "four", start: 1.0, end: 1.2)])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await updates.next()
        #expect(session.currentTranscript == "one two three four")
        session.cancel()
        let result = await session.finishForReuse()
        #expect(result.text == "one two three four")
        #expect(session.currentTranscript == result.text)
        #expect(!result.completed && !result.canReuse)
        #expect(result.fallbackReason == .cancelled)
    }

    @Test("a long nonzero microphone noise pause drains completely without requiring retranscription")
    func nonzeroLowAmplitudePauseCanComplete() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { _ in
            Issue.record("Sub-threshold microphone noise should retain the existing silence behavior")
            return .init(text: "", words: [])
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.00001, count: 32_000))
        _ = await updates.next()
        for _ in 2..<65 {
            session.enqueue(Array(repeating: 0.00001, count: 16_000))
            _ = await updates.next()
        }
        let result = await session.finishForReuse()
        #expect(result.completed && result.canReuse)
        #expect(result.fallbackReason == nil)
        #expect(result.diagnostics.qualityConcern == .unverifiedEmptyAudio)
        #expect(result.text.isEmpty)
        #expect(result.receivedSamples == 65 * 16_000)
        #expect(result.decodedThroughSample == result.receivedSamples)
        #expect(result.diagnostics.discardedSamples > 45 * 16_000)
        #expect(session.diagnostics.decodeCount == 0)
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

    @Test("closing a session cancels queued model work before its permit is granted", arguments: [false, true])
    func closeCancelsQueuedInference(overrun: Bool) async {
        let decoder = BufferedHeldDecoder(checkCancellationAfterPermit: true)
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { try await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var calls = decoder.started.stream.makeAsyncIterator()
        var completions = decoder.completed.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 32_000))
        _ = await calls.next()
        if overrun {
            session.enqueue(Array(repeating: 0.2, count: 720_001))
        } else {
            session.cancel()
        }
        // Finish must return before the permit is released, even though the
        // decoder's continuation itself cannot be cancelled.
        let result = await session.finishForReuse()
        #expect(!result.completed && !result.canReuse)
        #expect(result.fallbackReason == (overrun ? .transcriptionFailed : .cancelled))
        await decoder.release()
        _ = await completions.next()
        #expect(await decoder.inferenceCount == 0)
        #expect(output.values.isEmpty)
        #expect(output.failures == (overrun ? 1 : 0))
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
        session.enqueue(Array(repeating: 0.2, count: 720_001))
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

    @Test("surrounding punctuation and spaces do not change an owned word's identity", arguments: ["- Hey,", "— « Hey, »", "... Hey,"])
    func adornedOwnedAnchorKeepsExactTimedOccurrence(adorned: String) async {
        func window(_ first: String) -> BufferedTranscriptionWindow {
            let words: [BufferedTranscriptionWord] = [
                .init(text: first, start: 2.7, end: 3.68),
                .init(text: "before", start: 3.68, end: 4.32),
                .init(text: "Hey,", start: 5.2, end: 5.6)
            ]
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window(adorned), window(adorned), window("Hey,")])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 6 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == adorned)
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == adorned + " before")
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.committedText == adorned + " before Hey,")
        #expect(!output.diagnostics.contains { $0.contains("ownership_recovery:") })
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("internal punctuation and punctuation-only tokens remain distinct anchor identities", arguments: [false, true])
    func anchorIdentityPreservesInternalPunctuation(punctuationOnly: Bool) async {
        let original = punctuationOnly ? "-" : "can't"
        let revised = punctuationOnly ? "," : "cant"
        func window(_ first: String) -> BufferedTranscriptionWindow {
            let words: [BufferedTranscriptionWord] = [
                .init(text: first, start: 2.7, end: 3.68),
                .init(text: "before", start: 3.68, end: 4.32)
            ]
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window(original), window(original), window(revised)])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 6 * 16_000))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let stable = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == stable?.committedText)
        #expect(output.diagnostics.contains { $0.contains("changed_anchor_waiting") })
        await session.finish()
        #expect(output.failures == 1)
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
        await session.finish() // No new audio can resolve the ambiguous occurrence.
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

    @Test("a pause rollover retires owned words whose onset left the retained PCM", arguments: [12.1, 15.1])
    func pauseRolloverRetiresStraddlingAnchor(resumeAt: Double) async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let base = Double(samples[0]) / 16_000
            let end = base + Double(samples.count) / 16_000
            let events: [(String, Double, Double)] = [("go", 0.1, 0.5), ("go", resumeAt, resumeAt + 0.4), ("again", 16.1, 16.5)]
            let words: [BufferedTranscriptionWord] = events.compactMap { text, start, finish in
                guard start >= base, finish <= end else { return nil }
                // An already-owned word can acquire a trailing-silence duration.
                // At 15s this creates an anchor at 0.1–14.8s, then crops to 11s.
                let revisedEnd = start == 0.1 && samples.count == 240_000 ? 14.8 : finish
                return .init(text: text, start: start - base, end: revisedEnd - base)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(2 * 16_000)).map(Float.init))
        _ = await updates.next()
        for second in 3...24 {
            session.enqueue((((second - 1) * 16_000)..<(second * 16_000)).map(Float.init))
            guard await updates.next() != nil else { break }
        }
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.text == "go go again")
        #expect(!output.diagnostics.contains { $0.contains("missing_anchor") })
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("five minutes of pauses and repeated resumed words retain every occurrence")
    func fiveMinutePauseResumeKeepsRepeatedSpeech() async {
        let output = BufferedPreviewOutput()
        let events: [(String, Double, Double)] = (0..<7).flatMap { cycle in
            let base = Double(cycle * 50)
            return [("go", base + 0.1, base + 0.5), ("go", base + 15.1, base + 15.5),
                    ("again.", base + 16.1, base + 16.5)]
        }
        let session = BufferedTranscriptionSession(decode: { samples in
            let base = BufferedTimedAudio.origin(samples)
            let end = base + Double(samples.count) / 16_000
            var words: [BufferedTranscriptionWord] = events.compactMap { text, start, finish in
                guard start >= base, finish <= end else { return nil }
                return .init(text: text, start: start - base, end: finish - base)
            }
            if samples.count == 240_000, let last = words.last,
               last.end + 5 < Double(samples.count) / 16_000 {
                // The final owned token's onset stays fixed while its duration
                // absorbs a long pause, reproducing the same seam repeatedly.
                words[words.count - 1] = .init(text: last.text, start: last.start, end: 14.8)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(BufferedTimedAudio.samples(0..<(2 * 16_000), speech: events.map { $0.1..<$0.2 }))
        _ = await updates.next()
        var lastSecond = 2
        for second in 3...330 {
            session.enqueue(BufferedTimedAudio.samples(((second - 1) * 16_000)..<(second * 16_000), speech: events.map { $0.1..<$0.2 }))
            guard await updates.next() != nil else { break }
            lastSecond = second
        }
        await session.finish()
        #expect(lastSecond == 330)
        #expect(output.failures == 0)
        #expect(output.values.last?.text == events.map { $0.0 }.joined(separator: " "))
        #expect(!output.diagnostics.contains { $0.contains("missing_anchor") })
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("rollover preserves preceding context for an owned onset expanding across a pause")
    func rolloverRetainsPrecedingAnchorForPauseExpansion() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let base = Double(samples[0]) / 16_000
            let shifted = base > 0
            // Public-fixture seam: last owned "prior" at 11.82–11.92 becomes
            // "prior" at 11.46–11.92; next "to" at 11.92–12.16 remains exact.
            // Cropping to 10.82 clips preceding "complete" at 10.72–11.52;
            // retaining its onset lets the existing two-sided rule prove this seam.
            let events: [(String, Double, Double)] = [
                ("we", 10.14, 10.44), ("should", 10.44, 10.72),
                ("complete", max(10.72, base > 10.72 ? base + 0.24 : 10.72), shifted ? 11.46 : 11.52),
                ("prior", shifted ? 11.46 : 11.82, 11.92),
                ("to", 11.92, 12.16), ("cutting", 12.16, 12.46),
                ("a", 12.46, 12.62), ("release.", 12.62, 13.22)
            ]
            let words: [BufferedTranscriptionWord] = events.compactMap { text, start, end in
                guard start >= base, end <= base + Double(samples.count) / 16_000 else { return nil }
                return .init(text: text, start: start - base, end: end - base)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(15 * 16_000)).map(Float.init))
        #expect(await updates.next()?.committedText == "we should complete prior")
        session.enqueue(((15 * 16_000)..<(16 * 16_000)).map(Float.init))
        _ = await updates.next()
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.committedText == "we should complete prior to cutting a release.")
        #expect(!output.diagnostics.contains { $0.contains("changed_boundary") })
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("preceding-anchor context cannot pin a rolling window at its origin")
    func precedingAnchorRetentionFallsBackForLongSpan() async {
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let base = Double(samples[0]) / 16_000
            let end = base + Double(samples.count) / 16_000
            let events: [(String, Double, Double)] = [
                ("long", 0.2, 10.8), ("word", 11.0, 11.5), ("resumed", 12.5, 13.0)
            ]
            let words: [BufferedTranscriptionWord] = events.compactMap { text, start, finish in
                guard start >= base, finish <= end else { return nil }
                return .init(text: text, start: start - base, end: finish - base)
            }
            return .init(text: words.map(\.text).joined(separator: " "), words: words)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue((0..<(15 * 16_000)).map(Float.init))
        #expect(await updates.next()?.committedText == "long word")
        session.enqueue(((15 * 16_000)..<(16 * 16_000)).map(Float.init))
        _ = await updates.next()
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.committedText == "long word resumed")
        #expect(!output.diagnostics.contains { $0.contains("no_roll_progress") })
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

    @Test("a pause may move between adjacent owned words while the surrounding seam stays fixed")
    func adjacentOwnedWordsRedistributePause() async {
        let initial: [BufferedTranscriptionWord] = [
            .init(text: "environment", start: 1, end: 3.26),
            .init(text: "just", start: 3.26, end: 3.38),
            .init(text: "in", start: 3.38, end: 4.08),
            .init(text: "our", start: 4.08, end: 4.32),
            .init(text: "review", start: 5.1, end: 5.3)
        ]
        var revised = initial
        revised[0] = .init(text: "environment", start: 1, end: 1.94)
        revised[1] = .init(text: "just", start: 1.94, end: 3.38)
        func window(_ words: [BufferedTranscriptionWord]) -> BufferedTranscriptionWindow {
            .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window(initial), window(initial), window(revised)])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 86_400)) // 5.4 seconds
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "environment just")
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == "environment just in our")
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.committedText == "environment just in our review")
        #expect(!output.diagnostics.contains { $0.contains("ownership_recovery:") })
        assertMonotonicCommittedPrefixes(output.values)
    }

    @Test("pause redistribution still requires current adjacency and both surrounding anchors",
          arguments: ["overlapping_previous", "moved_previous", "changed_previous", "changed_following", "inserted_repeat", "split_owned_word"])
    func redistributedPauseRequiresUnchangedSurroundingSeam(change: String) async {
        let initial: [BufferedTranscriptionWord] = [
            .init(text: "environment", start: 1, end: 3.26),
            .init(text: change == "split_owned_word" ? "cannot" : "just", start: 3.26, end: 3.38),
            .init(text: "in", start: 3.38, end: 4.08),
            .init(text: "our", start: 4.08, end: 4.32)
        ]
        var revised = initial
        revised[0] = .init(text: change == "changed_previous" ? "code" : "environment",
                           start: change == "moved_previous" ? 0.6 : 1,
                           end: change == "overlapping_previous" ? 2.4 : 1.94)
        revised[1] = .init(text: "just", start: 1.94, end: 3.38)
        if change == "changed_following" { revised[2] = .init(text: "and", start: 3.38, end: 4.08) }
        if change == "inserted_repeat" || change == "split_owned_word" {
            revised[1] = .init(text: change == "split_owned_word" ? "can" : "just", start: 1.94, end: 3.0)
            revised.insert(.init(text: change == "split_owned_word" ? "not" : "just", start: 3.0, end: 3.38), at: 2)
        }
        func window(_ words: [BufferedTranscriptionWord]) -> BufferedTranscriptionWindow {
            .init(text: words.map(\.text).joined(separator: " "), words: words)
        }
        let output = BufferedPreviewOutput()
        let decoder = BufferedWindowSequence([window(initial), window(initial), window(revised)])
        let session = BufferedTranscriptionSession(decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 86_400))
        _ = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        let stable = await updates.next()
        session.enqueue(Array(repeating: 0.2, count: 16_000))
        #expect(await updates.next()?.committedText == stable?.committedText)
        #expect(output.diagnostics.contains { $0.contains("ownership_recovery:") })
        session.cancel()
    }

    @Test("Whisper collapsed timing retries cannot poison the committed prefix")
    func collapsedWhisperPreviewRetainsDraftAndRecovers() async {
        let clean: [BufferedTranscriptionWord] = [
            .init(text: "Diff", start: 2.98, end: 3.68),
            .init(text: "means", start: 3.68, end: 4.16),
            .init(text: "comparing", start: 5.86, end: 6.42)
        ]
        let poison: [BufferedTranscriptionWord] = [
            .init(text: "What", start: 2.6, end: 3.44),
            .init(text: "is", start: 3.44, end: 3.44),
            .init(text: "the", start: 3.44, end: 3.44),
            .init(text: "difference?", start: 3.44, end: 3.44),
            .init(text: "Diff", start: 3.44, end: 3.62),
            .init(text: "means", start: 3.62, end: 3.94),
            .init(text: "comparing", start: 3.94, end: 6.42)
        ]
        let output = BufferedPreviewOutput()
        let session = BufferedTranscriptionSession(decode: { samples in
            let words = (8...10).contains(samples.count / 16_000) ? poison : clean
            return try WhisperKitTranscriber.previewWindow(text: words.map(\.text).joined(separator: " "),
                words: words, sampleCount: samples.count)
        }, onUpdate: { output.update($0) }, onFailure: { output.fail($0) }, onDiagnostic: { output.diagnostic($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        session.enqueue(Array(repeating: 0.2, count: 7 * 16_000))
        #expect(await updates.next()?.text == "Diff means comparing")
        for _ in 8...12 {
            session.enqueue(Array(repeating: 0.2, count: 16_000))
            #expect(await updates.next()?.text == "Diff means comparing")
        }
        await session.finish()
        #expect(output.failures == 0)
        #expect(output.values.last?.committedText == "Diff means comparing")
        #expect(output.diagnostics.filter { $0 == "preview_deferred:collapsed_word_timings" }.count == 3)
        #expect(session.diagnostics.receivedSamples == 12 * 16_000)
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
        let speech: [Range<Double>] = [0.1..<0.5, 1..<1.5, 4..<4.5]
        let decoder = BufferedRecoveryOracle(recoverAt: 10, holdAt: 10 * 16_000)
        var config = BufferedTranscriptionSession.Configuration()
        config.windowSamples = 8 * 16_000
        config.maximumRecoveryWindowSamples = 10 * 16_000
        config.maximumBufferedSamples = 16 * 16_000
        let session = BufferedTranscriptionSession(configuration: config, decode: { await decoder.decode($0) },
            onUpdate: { output.update($0) }, onFailure: { output.fail($0) })
        var updates = output.updates.stream.makeAsyncIterator()
        var starts = decoder.started.stream.makeAsyncIterator()
        session.enqueue(BufferedTimedAudio.samples(0..<(5 * 16_000), speech: speech))
        _ = await starts.next()
        _ = await updates.next()
        for end in 6...9 {
            session.enqueue(BufferedTimedAudio.samples(((end - 1) * 16_000)..<(end * 16_000), speech: speech))
            _ = await starts.next()
            _ = await updates.next()
        }
        session.enqueue(BufferedTimedAudio.samples((9 * 16_000)..<(10 * 16_000), speech: speech))
        #expect(await starts.next() == 10 * 16_000)
        session.enqueue(BufferedTimedAudio.samples((10 * 16_000)..<(15 * 16_000), speech: speech))
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
          arguments: [BufferedTranscriptionPreviewDeferral.missingWordTimings, .textAlignmentMismatch, .invalidWordTimings, .collapsedWordTimings])
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
        await session.finish()
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
    private(set) var inferenceCount = 0
    private let checkCancellationAfterPermit: Bool
    init(checkCancellationAfterPermit: Bool = false) {
        self.checkCancellationAfterPermit = checkCancellationAfterPermit
    }
    func decode(_ samples: [Float]) async throws -> BufferedTranscriptionWindow {
        callCount += 1
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        started.continuation.yield(samples.count)
        defer {
            inFlight -= 1
            completed.continuation.yield(())
        }
        if !released { await withCheckedContinuation { permit = $0 } }
        if checkCancellationAfterPermit { try Task.checkCancellation() }
        inferenceCount += 1
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
        let base = BufferedTimedAudio.origin(samples)
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

/// Preserve absolute-time fixture metadata without making pauses acoustically loud.
private enum BufferedTimedAudio {
    static func samples(_ range: Range<Int>, speech: [Range<Double>]) -> [Float] {
        var result = range.map { Float($0) / 1e12 }
        for span in speech {
            let start = max(range.lowerBound, Int(span.lowerBound * 16_000))
            let end = min(range.upperBound, Int(span.upperBound * 16_000))
            guard start < end else { continue }
            for sample in start..<end { result[sample - range.lowerBound] = Float(sample) }
        }
        return result
    }

    static func origin(_ samples: [Float]) -> Double {
        let first = Double(samples[0])
        return (first < 0.0001 ? first * 1e12 : first) / 16_000
    }
}
