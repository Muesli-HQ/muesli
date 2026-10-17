import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("SpeechSegment")
struct SpeechSegmentTests {

    @Test("stores start, end, text")
    func basicConstruction() {
        let segment = SpeechSegment(start: 1.5, end: 3.0, text: "Hello world")
        #expect(segment.start == 1.5)
        #expect(segment.end == 3.0)
        #expect(segment.text == "Hello world")
    }
}

@Suite("SpeechTranscriptionResult")
struct SpeechTranscriptionResultTests {

    @Test("stores text and segments")
    func basicConstruction() {
        let result = SpeechTranscriptionResult(
            text: "Full text",
            segments: [
                SpeechSegment(start: 0, end: 1, text: "Full"),
                SpeechSegment(start: 1, end: 2, text: "text"),
            ]
        )
        #expect(result.text == "Full text")
        #expect(result.segments.count == 2)
    }

    @Test("Traditional output preserves native glyphs and converts mixed ASR phrases")
    func traditionalChineseOutput() {
        for (input, expected) in [
            ("头发发展，后台软件，干杯。", "頭髮發展，後台軟件，乾杯。"),
            ("頭发", "頭髮"), ("头髮", "頭髮"), ("發展软件", "發展軟件"),
            ("剃髮", "剃髮"), ("他們了解這件事", "他們了解這件事"),
            ("Hello, world. 日本語の発表です。", "Hello, world. 日本語の発表です。"),
            ("  开会\nOK ✅", "  開會\nOK ✅"), ("", ""),
        ] {
            let output = ChineseTranscriptionOutput.apply(input, language: "zh-TW")
            #expect(output == expected)
            #expect(ChineseTranscriptionOutput.apply(output, language: "zh-TW") == output)
        }
    }

    @Test("mixed Han probes preserve native Traditional glyphs across a contextual run")
    func mixedHanRunPreservesTraditionalGlyphs() {
        #expect(ChineseTranscriptionOutput.apply("了解头发", language: "zh-TW") == "了解頭髮")
        #expect(ChineseTranscriptionOutput.apply("頭发剃髮發展软件", language: "zh-TW") == "頭髮剃髮發展軟件")
        #expect(ChineseTranscriptionOutput.apply("他們了解這件事头发剃髮", language: "zh-TW") == "他們了解這件事頭髮剃髮")
    }

    @Test("output conversion is opt-in for every generated Unicode string")
    func otherLanguagesAreIdentity() {
        // Deterministic generated coverage across the Unicode scalar domain; no new dependency.
        var seed: UInt64 = 0x17_10_2026
        for _ in 0..<256 {
            var input = ""
            for _ in 0..<32 {
                seed = seed &* 6364136223846793005 &+ 1
                if let scalar = Unicode.Scalar(UInt32(seed % 0x110000)) { input.unicodeScalars.append(scalar) }
            }
            let codes: [String?] = [nil, "auto", "zh", "en", "ja", "zh-CN"]
            for code in codes {
                #expect(ChineseTranscriptionOutput.apply(input, language: code) == input)
            }
        }
    }

    @Test("foreign words do not disable conversion of separate Chinese phrases")
    func mixedChineseAndForeignWords() {
        for suffix in ["カ", "한글", "日本語の発表です", "👩🏽‍💻", "e\u{301}", "\0", "\u{20000}"] {
            let input = "头发，" + suffix
            #expect(ChineseTranscriptionOutput.apply(input, language: "zh-TW") == "頭髮，" + suffix)
        }
    }

    @Test("Traditional replay joins an adjacent Han boundary without spaces")
    func joinsHanBoundary() {
        #expect(ChineseTranscriptionOutput.joinsHanBoundary(previous: "头", next: "发"))
        #expect(!ChineseTranscriptionOutput.joinsHanBoundary(previous: "Hello", next: "world"))
        #expect(!ChineseTranscriptionOutput.joinsHanBoundary(previous: "头", next: "かな"))
    }

    @Test("generated mixed Chinese phrases are stable after one conversion")
    func generatedChineseIdempotence() {
        let phrases = ["头发", "頭髮", "發展软件", "後臺", "剃髮", "他們了解這件事", "，", " ", "OK"]
        var seed: UInt64 = 771
        for _ in 0..<128 {
            let input = (0..<12).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return phrases[Int(seed % UInt64(phrases.count))]
            }.joined()
            let once = ChineseTranscriptionOutput.apply(input, language: "zh-TW")
            #expect(ChineseTranscriptionOutput.apply(once, language: "zh-TW") == once)
        }
    }

    @Test("segment partitioning does not change contextual conversion")
    func allSegmentPartitions() {
        let text = "头发，頭发 OK ✅"
        let scalars = Array(text.unicodeScalars)
        for split in 0...scalars.count {
            let left = String(String.UnicodeScalarView(scalars[..<split]))
            let right = String(String.UnicodeScalarView(scalars[split...]))
            let result = SpeechTranscriptionResult(text: text, segments: [
                SpeechSegment(start: -0.0, end: 2, text: left),
                SpeechSegment(start: 2, end: 3, text: right),
            ]).convertingChineseOutput(language: "zh-TW")
            #expect(result.segments.map(\.text).joined() == result.text)
            #expect(result.segments[0].start.bitPattern == (-0.0 as Double).bitPattern)
        }
    }

    @Test("Traditional output preserves artifact cleanup spacing and paste spacing")
    func traditionalFiltersAndSpacing() {
        let cleaned = FillerWordFilter.apply(TranscriptionEngineArtifactsFilter.apply("头发<|zh|>发展。"))
        let output = ChineseTranscriptionOutput.apply(cleaned, language: "zh-TW")
        #expect(cleaned == "头发 发展。")
        #expect(output == "頭髮 發展。")
        #expect(DictationPasteSpacing.trailingSeparator(after: output) == "")
        #expect(ChineseTranscriptionOutput.apply(cleaned, language: "zh") == "头发 发展。")
    }

    @Test("live-caption conversion work stays bounded as the meeting grows")
    func captionConversionDoesNotRescanHistory() {
        var captions = ChineseCaptionOutput(language: "zh-TW")
        var processed = 0
        var output = ""
        let chunk = String(repeating: "开", count: 20)
        for _ in 0..<500 {
            output = captions.append(chunk, convert: { text, _ in
                processed += text.unicodeScalars.count
                return text
            })
        }
        #expect(output == String(repeating: chunk, count: 500))
        #expect(processed < 16 * output.unicodeScalars.count)
    }

    @Test("existing caption languages keep their append-only path")
    func existingCaptionLanguages() {
        let languages: [String?] = [nil, "auto", "zh", "en"]
        for language in languages {
            var captions = ChineseCaptionOutput(language: language)
            for chunk in ["汉字", " カ", " ✅"] {
                _ = captions.append(chunk, convert: { text, _ in
                    Issue.record("Existing caption languages must bypass conversion")
                    return text
                })
            }
            #expect(captions.append("") == "汉字 カ ✅")
        }
    }

    @Test("caption output is independent of generated Unicode append partitions")
    func generatedCaptionPartitions() {
        var seed: UInt64 = 649
        let alphabet = Array("x头髮，✅👩🏽‍💻e\u{301}\u{20000}".unicodeScalars)
        for _ in 0..<32 {
            let scalars = (0..<400).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return alphabet[Int(seed % UInt64(alphabet.count))]
            }
            let input = String(String.UnicodeScalarView(scalars))
            var captions = ChineseCaptionOutput(language: "zh-TW")
            var output = ""
            var offset = 0
            while offset < scalars.count {
                seed = seed &* 6364136223846793005 &+ 1
                let end = min(offset + 1 + Int(seed % 73), scalars.count)
                let chunk = String(String.UnicodeScalarView(scalars[offset..<end]))
                output = captions.append(chunk, convert: { text, _ in text.replacingOccurrences(of: "x", with: "y") })
                offset = end
            }
            #expect(output == input.replacingOccurrences(of: "x", with: "y"))
        }
    }

    @Test("length-changing caption fallback does not duplicate committed context")
    func captionLengthChangingFallback() {
        var captions = ChineseCaptionOutput(language: "zh-TW")
        let prefix = String(repeating: "頭，", count: 200)
        _ = captions.append(prefix)
        let expand: (String, String?) -> String = { text, _ in text.replacingOccurrences(of: "x", with: "xx") }
        #expect(captions.append("x", convert: expand) == prefix + "xx")
        #expect(captions.append("y✅", convert: expand) == prefix + "xxy✅")
        #expect(captions.append("x", convert: expand) == prefix + "xxy✅xx")
    }

    @Test("live-caption window retains cross-update phrase context and resets")
    func captionConversionContext() {
        var captions = ChineseCaptionOutput(language: "zh-TW")
        let prefix = String(repeating: "开会。", count: 100)
        _ = captions.append(prefix + "头")
        #expect(captions.append("发，カ") == ChineseTranscriptionOutput.apply(prefix + "头发，カ", language: "zh-TW"))
        captions.reset()
        #expect(captions.append("头发") == "頭髮")
    }

    @Test("Traditional conversion uses context across segments and retains timing")
    func traditionalSegments() {
        let result = SpeechTranscriptionResult(text: "头发", segments: [
            SpeechSegment(start: 1, end: 2, text: "头"),
            SpeechSegment(start: 2, end: 3, text: "发"),
        ]).convertingChineseOutput(language: "zh-TW")
        #expect(result.text == "頭髮")
        #expect(result.segments.map(\.text) == ["頭", "髮"])
        #expect(result.segments.map(\.start) == [1, 2])
        #expect(result.segments.map(\.end) == [2, 3])

        let repairedBoundary = SpeechTranscriptionResult(text: "发型", segments: [
            SpeechSegment(start: 3, end: 4, text: "发"),
            SpeechSegment(start: 4, end: 5, text: "型"),
        ]).convertingChineseOutput(language: "zh-TW")
        #expect(repairedBoundary.text == "髮型")
        #expect(repairedBoundary.segments.map(\.text) == ["髮", "型"])
    }

    @Test("empty result")
    func emptyResult() {
        let result = SpeechTranscriptionResult(text: "", segments: [])
        #expect(result.text.isEmpty)
        #expect(result.segments.isEmpty)
    }
}

@Suite("Inference serialization gate")
struct InferenceGateTests {

    @Test("cancelled waiter is removed before next slot")
    func cancelledWaiterDoesNotConsumeSlot() async throws {
        let gate = InferenceGate()
        try await gate.acquire()

        let cancelled = Task {
            try await gate.acquire()
            await gate.release()
            return true
        }

        try await Task.sleep(for: .milliseconds(10))
        #expect(await gate.queuedWaiterCount() == 1)

        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(await gate.queuedWaiterCount() == 0)

        let next = Task {
            try await gate.acquire()
            await gate.release()
            return true
        }

        try await Task.sleep(for: .milliseconds(10))
        await gate.release()
        #expect(try await next.value)

        do {
            _ = try await cancelled.value
            Issue.record("Cancelled waiter unexpectedly acquired the inference slot")
        } catch is CancellationError {
            // Expected path.
        } catch {
            Issue.record("Cancelled waiter failed with unexpected error: \(error)")
        }
    }
}

@Suite("TranscriptionCoordinator routing")
struct TranscriptionCoordinatorTests {

    @Test("coordinator initializes without crash")
    func initDoesNotCrash() {
        let _ = TranscriptionCoordinator()
    }

    @Test("backend routing covers all known backends")
    func allBackendsCovered() {
        var backends = Set(BackendOption.all.map(\.backend))
        backends.insert(BackendOption.appleSpeechAnalyzer.backend)
        #expect(backends == TranscriptionCoordinator.explicitlyRoutedBackendIdentifiers.union(["fluidaudio"]))
    }

    @Test("Chinese output conversion uses the request language selection")
    func chineseOutputLanguageUsesExplicitSelections() {
        let qwen = BackendOption.all.first { $0.backend == "qwen" }!
        let nemotron = BackendOption.all.first { $0.backend == "nemotron35" }!

        #expect(TranscriptionCoordinator.chineseOutputLanguage(
            backend: qwen,
            whisper: .defaultLanguage,
            qwen: .chineseTraditional,
            cohere: .defaultLanguage,
            nemotron: .chinese
        ) == "zh-TW")
        #expect(TranscriptionCoordinator.chineseOutputLanguage(
            backend: nemotron,
            whisper: .defaultLanguage,
            qwen: .auto,
            cohere: .defaultLanguage,
            nemotron: .chineseTraditional
        ) == "zh-TW")
        #expect(TranscriptionCoordinator.chineseOutputLanguage(
            backend: nemotron,
            whisper: .defaultLanguage,
            qwen: .auto,
            cohere: .defaultLanguage,
            nemotron: .chinese
        ) == "zh")
    }

    @Test("Apple Speech cleanup waits for an active use")
    func appleSpeechCleanupWaitsForActiveUse() async {
        let lifecycle = AppleSpeechUseLifecycle()
        let cleanupCount = TranscriptionLifecycleTestCounter()

        await lifecycle.beginUse()
        await lifecycle.requestCleanup {
            await cleanupCount.increment()
        }

        #expect(await lifecycle.snapshot() == .init(
            activeUseCount: 1,
            hasDeferredCleanup: true,
            isCleaningUp: false
        ))
        #expect(await cleanupCount.value == 0)

        await lifecycle.endUse()
        #expect(await cleanupCount.value == 1)
    }

    @Test("Apple Speech cleanup waits for dictation and meeting uses")
    func appleSpeechCleanupWaitsForCombinedUses() async {
        let lifecycle = AppleSpeechUseLifecycle()
        let cleanupCount = TranscriptionLifecycleTestCounter()

        await lifecycle.beginUse()
        await lifecycle.beginUse()
        await lifecycle.requestCleanup {
            await cleanupCount.increment()
        }

        await lifecycle.endUse()
        #expect(await cleanupCount.value == 0)
        await lifecycle.endUse()
        #expect(await cleanupCount.value == 1)
    }

    @Test("a newer Apple Speech use cancels a deferred stale cleanup")
    func newerAppleSpeechUseCancelsDeferredCleanup() async {
        let lifecycle = AppleSpeechUseLifecycle()
        let cleanupCount = TranscriptionLifecycleTestCounter()

        await lifecycle.beginUse()
        await lifecycle.requestCleanup {
            await cleanupCount.increment()
        }
        await lifecycle.beginUse()

        await lifecycle.endUse()
        await lifecycle.endUse()

        #expect(await cleanupCount.value == 0)
        #expect(await lifecycle.snapshot() == .init(
            activeUseCount: 0,
            hasDeferredCleanup: false,
            isCleaningUp: false
        ))
    }

    @Test("a new Apple Speech use waits for in-flight cleanup")
    func appleSpeechUseWaitsForCleanup() async {
        let lifecycle = AppleSpeechUseLifecycle()
        let cleanupStarted = TranscriptionLifecycleTestLatch()
        let allowCleanup = TranscriptionLifecycleTestLatch()
        let useStarted = TranscriptionLifecycleTestCounter()

        let cleanupTask = Task {
            await lifecycle.requestCleanup {
                await cleanupStarted.signal()
                await allowCleanup.wait()
            }
        }
        await cleanupStarted.wait()

        let useTask = Task {
            await lifecycle.beginUse()
            await useStarted.increment()
        }
        for _ in 0..<100 {
            if (await lifecycle.snapshot()).activeUseCount > 0 { break }
            await Task.yield()
        }

        #expect((await lifecycle.snapshot()).activeUseCount == 1)
        #expect(await useStarted.value == 0)
        #expect((await lifecycle.snapshot()).isCleaningUp)

        await allowCleanup.signal()
        await cleanupTask.value
        await useTask.value

        #expect(await useStarted.value == 1)
        await lifecycle.endUse()
    }

    @Test("a newer cleanup request survives an older in-flight cleanup")
    func newerAppleSpeechCleanupIsNotDropped() async {
        let lifecycle = AppleSpeechUseLifecycle()
        let firstCleanupStarted = TranscriptionLifecycleTestLatch()
        let allowFirstCleanup = TranscriptionLifecycleTestLatch()
        let secondCleanupCount = TranscriptionLifecycleTestCounter()

        let firstCleanupTask = Task {
            await lifecycle.requestCleanup {
                await firstCleanupStarted.signal()
                await allowFirstCleanup.wait()
            }
        }
        await firstCleanupStarted.wait()

        let useTask = Task {
            await lifecycle.beginUse()
        }
        for _ in 0..<100 {
            if (await lifecycle.snapshot()).activeUseCount > 0 { break }
            await Task.yield()
        }
        #expect((await lifecycle.snapshot()).activeUseCount == 1)

        let secondCleanupTask = Task {
            await lifecycle.requestCleanup {
                await secondCleanupCount.increment()
            }
        }
        for _ in 0..<100 {
            if (await lifecycle.snapshot()).hasDeferredCleanup { break }
            await Task.yield()
        }
        #expect((await lifecycle.snapshot()).hasDeferredCleanup)

        await allowFirstCleanup.signal()
        await firstCleanupTask.value
        await useTask.value
        await secondCleanupTask.value

        #expect(await secondCleanupCount.value == 0)
        #expect((await lifecycle.snapshot()).hasDeferredCleanup)

        await lifecycle.endUse()
        #expect(await secondCleanupCount.value == 1)
    }
}

private actor TranscriptionLifecycleTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor TranscriptionLifecycleTestLatch {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

@Suite("CohereTranscribeLanguage")
struct CohereTranscribeLanguageTests {

    @Test("english prompt ids match the current default prompt")
    func englishPromptIds() {
        #expect(
            CohereTranscribeLanguage.english.promptIds == [13764, 7, 4, 16, 62, 62, 5, 9, 11, 13]
        )
    }

    @Test("german prompt ids swap in the german language token")
    func germanPromptIds() {
        #expect(
            CohereTranscribeLanguage.german.promptIds == [13764, 7, 4, 16, 76, 76, 5, 9, 11, 13]
        )
    }

    @Test("unset and unsupported codes fall back to english")
    func resolvedFallbacks() {
        #expect(CohereTranscribeLanguage.resolved(nil) == .english)
        #expect(CohereTranscribeLanguage.resolved("xx") == .english)
    }
}

@Suite("CohereTranscribeUtils")
struct CohereTranscribeUtilsTests {

    @Test("single transcript returns unchanged")
    func singleTranscript() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts(["Hello world"])
        #expect(result == "Hello world")
    }

    @Test("empty list returns empty string")
    func emptyList() {
        #expect(CohereTranscribeUtils.mergeOverlappingTranscripts([]) == "")
    }

    @Test("no overlap joins with space")
    func noOverlap() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "The quick brown fox",
            "jumped over the lazy dog",
        ])
        #expect(result == "The quick brown fox jumped over the lazy dog")
    }

    @Test("exact trigram overlap deduplicates")
    func exactOverlap() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "I went to the store and bought some milk",
            "and bought some milk then came home",
        ])
        #expect(result == "I went to the store and bought some milk then came home")
    }

    @Test("case-insensitive trigram matching")
    func caseInsensitive() {
        let result = CohereTranscribeUtils.mergeOverlappingTranscripts([
            "The Model Works well",
            "the model works well on device",
        ])
        #expect(result == "The Model Works well on device")
    }

    @Test("cleanTranscript strips endoftext token")
    func stripsEndOfText() {
        let result = CohereTranscribeUtils.cleanTranscript("Hello world<|endoftext|>garbage after")
        #expect(result == "Hello world")
    }

    @Test("cleanTranscript strips special tokens")
    func stripsSpecialTokens() {
        let result = CohereTranscribeUtils.cleanTranscript("Hello<|nospeech|> world<|pnc|>")
        #expect(result == "Hello world")
    }

    @Test("cleanTranscript trims repeated suffix")
    func trimsRepeatedSuffix() {
        // Split on ". " produces: ["First", "Second", "Third", "Fourth", "Second", "more"]
        // Position 4 "Second" matches position 1 "Second", i-j=3 ≤ 3 → truncate at position 4
        let result = CohereTranscribeUtils.cleanTranscript(
            "First. Second. Third. Fourth. Second. more text"
        )
        #expect(result == "First. Second. Third. Fourth.")
    }

    @Test("cleanTranscript passes normal text unchanged")
    func normalTextUnchanged() {
        #expect(CohereTranscribeUtils.cleanTranscript("Normal transcription text.") == "Normal transcription text.")
    }
}

@Suite("TranscriptionEngineArtifactsFilter")
struct TranscriptionEngineArtifactsFilterTests {

    @Test("returns empty string for known artifact")
    func blankAudioArtifact() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[blank_audio]") == "")
    }

    @Test("matching is case-insensitive")
    func caseInsensitive() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[BLANK_AUDIO]") == "")
    }

    @Test("trims surrounding whitespace before matching")
    func trailingWhitespace() {
        #expect(TranscriptionEngineArtifactsFilter.apply("  [blank_audio]  \n") == "")
    }

    @Test("passes through normal transcription unchanged")
    func normalTextUnchanged() {
        #expect(TranscriptionEngineArtifactsFilter.apply("Hello world") == "Hello world")
    }

    @Test("passes through empty string unchanged")
    func emptyTextUnchanged() {
        #expect(TranscriptionEngineArtifactsFilter.apply("") == "")
    }

    @Test("strips artifact when it appears mid-sentence")
    func midSentenceArtifact() {
        let text = "Hello [blank_audio] world"
        #expect(TranscriptionEngineArtifactsFilter.apply(text) == "Hello world")
    }

    @Test("strips decorated streaming blank-audio artifact")
    func decoratedStreamingArtifact() {
        #expect(TranscriptionEngineArtifactsFilter.apply(">> [BLANK_AUDIO]") == "")
        #expect(TranscriptionEngineArtifactsFilter.apply(">> [BLANK_AUDIO] Hello") == "Hello")
        #expect(TranscriptionEngineArtifactsFilter.apply(">> Hello") == ">> Hello")
    }

    @Test("strips model control tokens and non-speech annotations")
    func controlTokens() {
        #expect(
            TranscriptionEngineArtifactsFilter.apply("<EOU> Hello <EOB> [silence]") ==
                "Hello"
        )
    }

    @Test("strips foreign-language placeholders without removing ordinary sentences")
    func foreignLanguagePlaceholder() {
        #expect(TranscriptionEngineArtifactsFilter.apply("[SPEAKING IN FOREIGN LANGUAGE]") == "")
        #expect(
            TranscriptionEngineArtifactsFilter.apply("Speaking in a foreign language.") ==
                "Speaking in a foreign language."
        )
        #expect(TranscriptionEngineArtifactsFilter.apply("Hello [speaking in foreign language] world") == "Hello world")
        #expect(TranscriptionEngineArtifactsFilter.apply("[screaming]") == "")
        #expect(
            TranscriptionEngineArtifactsFilter.apply("We discussed speaking in foreign language classes.") ==
                "We discussed speaking in foreign language classes."
        )
    }

    @Test("strips any Whisper control token such as nocaptions")
    func whisperControlTokens() {
        #expect(TranscriptionEngineArtifactsFilter.apply("<|nocaptions|>") == "")
        #expect(TranscriptionEngineArtifactsFilter.apply("Det er <|nocaptions|> viktig") == "Det er viktig")
        #expect(TranscriptionEngineArtifactsFilter.apply("<|no|><|transcribe|>Hei") == "Hei")
        #expect(TranscriptionEngineArtifactsFilter.apply("a < b | c > d") == "a < b | c > d")
    }

    @Test("cleans segment text and drops segments left empty")
    func cleansSegments() {
        let segments = [
            SpeechSegment(start: 0, end: 1, text: "<|nocaptions|>"),
            SpeechSegment(start: 1, end: 2, text: "Hei <|nospeech|> alle"),
            SpeechSegment(start: 2, end: 3, text: "Det er bra"),
        ]
        let cleaned = TranscriptionEngineArtifactsFilter.apply(to: segments)
        #expect(cleaned.map(\.text) == ["Hei alle", "Det er bra"])
        #expect(cleaned.map(\.start) == [1, 2])
        #expect(cleaned.map(\.end) == [2, 3])
        #expect(TranscriptionEngineArtifactsFilter.apply(to: [segments[0]]).isEmpty)
    }

    @Test("strips leaked prompt suffix from transcript")
    func stripsLeakedPromptSuffix() {
        let text = """
        I'm testing local dictation. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription.
        """
        #expect(
            TranscriptionEngineArtifactsFilter.apply(text) ==
                "I'm testing local dictation."
        )
    }

    @Test("strips leaked prompt prefix from transcript")
    func stripsLeakedPromptPrefix() {
        let text = "Transcribe the spoken audio accurately. Testing whether this works or not."
        #expect(
            TranscriptionEngineArtifactsFilter.apply(text) ==
                "Testing whether this works or not."
        )
    }

    @Test("removes pure prompt leakage entirely")
    func removesPurePromptLeakage() {
        let text = """
        Transcribe the spoken audio accurately. If a word is unclear, use the most likely word that fits well within the context of the overall sentence transcription.
        """
        #expect(TranscriptionEngineArtifactsFilter.apply(text) == "")
    }
}

@Suite("Qwen3 post-processing output cleanup")
struct Qwen3PostProcessingOutputCleanerTests {

    @Test("removes think tags")
    func stripsThinkTags() {
        let raw = "<think>reasoning</think>Clean transcript"
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "Clean transcript")
    }

    @Test("removes chat markup")
    func stripsChatMarkup() {
        let raw = "<|im_start|>assistant Hello world <|im_end|>"
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "assistant Hello world")
    }

    @Test("removes leaked list-formatting instruction")
    func stripsLeakedPromptInstruction() {
        let raw = """
        If the speaker is dictating a list, such as saying "first point", "second point", or "bullet point", format each item on its own line.
        First point is ship it
        """
        #expect(Qwen3PostProcessorOutputCleaner.clean(raw) == "First point is ship it")
    }

    @Test("rejects assistant-style analysis output")
    func rejectsAssistantStyleAnalysisOutput() {
        let cleaned = """
        The user is asking about the system prompt.

        Analysis:
        This is a question.

        Action Plan:
        1. Answer the question.
        """
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "What is the system prompt?"
        ))
    }

    @Test("rejects runaway output")
    func rejectsRunawayOutput() {
        let cleaned = String(repeating: "Remove the filler word like. ", count: 40)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "What is the system prompt?"
        ))
    }

    @Test("rejects oversized cleanup output")
    func rejectsOversizedCleanupOutput() {
        let input = String(repeating: "Please ship this note. ", count: 10)
        let cleaned = String(repeating: "Please ship this note with unrelated additions. ", count: 12)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: input
        ))
    }

    @Test("rejects short-input hallucination expansion")
    func rejectsShortInputHallucinationExpansion() {
        let cleaned = String(repeating: "This unrelated response should not replace a short dictation. ", count: 3)
        #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: "um yeah"
        ))
    }

    @Test("rejects placeholder punctuation cleanup output")
    func rejectsPlaceholderPunctuationCleanupOutput() {
        for cleaned in ["...", ". . .", "---", "??"] {
            #expect(Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
                cleaned: cleaned,
                input: "Please send the update to Priyanka."
            ))
        }
    }

    @Test("recognizes LLM.swift's empty-generation placeholder for S1-mini")
    func recognizesS1MiniEmptyOutput() {
        #expect(Qwen3PostProcessorOutputCleaner.isS1MiniEmptyOutput("..."))
        #expect(Qwen3PostProcessorOutputCleaner.isS1MiniEmptyOutput(". . ."))
        #expect(Qwen3PostProcessorOutputCleaner.isS1MiniEmptyOutput("…"))
        #expect(!Qwen3PostProcessorOutputCleaner.isS1MiniEmptyOutput("Okay."))
    }

    @available(macOS 15, *)
    @Test("local cleanup keeps the captured configuration across model switches")
    func localCleanupKeepsCapturedConfigurationAcrossModelSwitches() async {
        let configurableURL = URL(fileURLWithPath: "/tmp/muesli-configurable-cleanup-test.gguf")
        let s1MiniURL = URL(fileURLWithPath: "/tmp/muesli-s1-mini-cleanup-test.gguf")
        let configurable = Qwen3PostProcessor.Configuration(
            modelURL: configurableURL,
            systemPrompt: "Configurable prompt",
            inputFormat: .configurable
        )
        let s1Mini = Qwen3PostProcessor.Configuration(
            modelURL: s1MiniURL,
            systemPrompt: PostProcessorOption.s1MiniSystemPrompt,
            inputFormat: .s1Mini
        )
        let processor = Qwen3PostProcessor(
            modelURL: configurable.modelURL,
            systemPrompt: configurable.systemPrompt,
            inputFormat: configurable.inputFormat
        )

        // Configurable -> S1-mini: the active configuration changes, but the
        // already captured configurable request must still use its own model.
        await processor.reconfigure(
            modelURL: s1Mini.modelURL,
            systemPrompt: s1Mini.systemPrompt,
            inputFormat: s1Mini.inputFormat
        )
        await assertMissingModel(
            processor: processor,
            configuration: configurable,
            expectedPath: configurableURL.path
        )

        // S1-mini -> configurable follows the same rule in the other direction.
        await processor.reconfigure(
            modelURL: configurable.modelURL,
            systemPrompt: configurable.systemPrompt,
            inputFormat: configurable.inputFormat
        )
        await assertMissingModel(
            processor: processor,
            configuration: s1Mini,
            expectedPath: s1MiniURL.path
        )
    }

    @available(macOS 15, *)
    @Test("effective local generation configuration preserves the token budget")
    func effectiveConfigurationPreservesTokenBudget() {
        let configuration = Qwen3PostProcessor.Configuration(
            modelURL: URL(fileURLWithPath: "/tmp/muesli-quill-budget-test.gguf"),
            systemPrompt: QuilTransformationPrompt.system,
            inputFormat: .configurable,
            maxTokenCount: Qwen3PostProcessorConfig.quilMaxContextTokens
        )

        let effective = Qwen3PostProcessor.effectiveConfiguration(for: configuration)

        #expect(effective.maxTokenCount == Qwen3PostProcessorConfig.quilMaxContextTokens)
    }

    @available(macOS 15, *)
    private func assertMissingModel(
        processor: Qwen3PostProcessor,
        configuration: Qwen3PostProcessor.Configuration,
        expectedPath: String
    ) async {
        do {
            _ = try await processor.process("test", configuration: configuration)
            Issue.record("Expected the test-only missing cleanup model to fail loading")
        } catch {
            #expect(error.localizedDescription.contains(expectedPath))
        }
    }

    @Test("accepts short legitimate cleanup output")
    func acceptsShortLegitimateCleanupOutput() {
        for cleaned in ["OK.", "Sure.", "No."] {
            #expect(!Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
                cleaned: cleaned,
                input: "okay sounds good"
            ))
        }
    }

    @Test("hosted cleanup sanitizer preserves dictated labels and quotes")
    func hostedCleanupSanitizerPreservesLabelsAndQuotes() {
        let raw = """
        Subject: "Muesli launch notes"

        Body: Ask Priyanka to review the "AI Models" settings copy.
        """

        let cleaned = TranscriptCleanupClient.cleanOutput(raw)

        #expect(cleaned.contains(#"Subject: "Muesli launch notes""#))
        #expect(cleaned.contains(#"Body: Ask Priyanka to review the "AI Models" settings copy."#))
        #expect(!Qwen3PostProcessorOutputCleaner.shouldFallbackToInput(
            cleaned: cleaned,
            input: #"Subject quote Muesli launch notes body ask Priyanka to review the quote AI Models quote settings copy"#
        ))
    }
}
