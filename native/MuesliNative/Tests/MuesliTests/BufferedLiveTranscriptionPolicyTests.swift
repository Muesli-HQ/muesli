import Foundation
import FluidAudio
import WhisperKit
import Testing
@testable import MuesliNativeApp

@Suite("Buffered live transcription eligibility and settings")
struct BufferedLiveTranscriptionPolicyTests {
    @Test("Parakeet reloads the requested dictation model after meeting preload for final and preview decoding")
    func parakeetRequestedModelAfterMeetingPreload() async throws {
        let loads = BufferedBackendLoadRecorder()
        let transcriber = FluidAudioTranscriber(modelLoader: { version, allowDownload, _, _ in
            let count = await loads.record(String(describing: version), allowDownload: allowDownload)
            // Empty managers keep this test entirely offline. The sentinel on
            // reload proves selection happens before touching either decoder.
            if count > 2 { throw BufferedBackendLoadRecorder.Failure.requestedReload }
            return AsrManager(config: .default)
        })
        try await transcriber.loadModels(version: .v3)
        try await transcriber.loadModels(version: .v3)
        try await transcriber.loadModels(version: .v2)
        await #expect(throws: BufferedBackendLoadRecorder.Failure.requestedReload) {
            _ = try await transcriber.transcribe(wavURL: URL(fileURLWithPath: "/unused.wav"), expectedVersion: .v3)
        }
        await #expect(throws: BufferedBackendLoadRecorder.Failure.requestedReload) {
            _ = try await transcriber.transcribePreview(samples: [0], expectedVersion: .v3)
        }
        #expect(await loads.values == ["v3", "v2", "v3", "v3"])
        #expect(await loads.downloadPermissions == [true, true, true, false])
        await transcriber.shutdown()
    }

    @Test("Whisper reloads the requested dictation model after meeting preload for final and preview decoding")
    func whisperRequestedModelAfterMeetingPreload() async throws {
        let loads = BufferedBackendLoadRecorder()
        let transcriber = WhisperKitTranscriber(modelLoader: { name, allowDownload, _, _ in
            let count = await loads.record(name, allowDownload: allowDownload)
            if count > 2 { throw BufferedBackendLoadRecorder.Failure.requestedReload }
            return try await WhisperKit(WhisperKitConfig(prewarm: false, load: false, download: false))
        })
        try await transcriber.loadModel(modelName: "tiny")
        try await transcriber.loadModel(modelName: "tiny")
        try await transcriber.loadModel(modelName: "large-v3")
        await #expect(throws: BufferedBackendLoadRecorder.Failure.requestedReload) {
            _ = try await transcriber.transcribe(wavURL: URL(fileURLWithPath: "/unused.wav"), expectedModel: "tiny")
        }
        await #expect(throws: BufferedBackendLoadRecorder.Failure.requestedReload) {
            _ = try await transcriber.transcribePreview(samples: [0], expectedModel: "tiny")
        }
        #expect(await loads.values == ["tiny", "large-v3", "tiny", "tiny"])
        #expect(await loads.downloadPermissions == [true, true, true, false])
        await transcriber.shutdown()
    }

    @Test("Cancelled preview requests do not reload models and release the decode permit")
    func cancelledPreviewsDoNotReload() async {
        let loads = BufferedBackendLoadRecorder()
        let parakeet = FluidAudioTranscriber(modelLoader: { version, allowDownload, _, _ in
            _ = await loads.record(String(describing: version), allowDownload: allowDownload)
            throw BufferedBackendLoadRecorder.Failure.requestedReload
        })
        let whisper = WhisperKitTranscriber(modelLoader: { name, allowDownload, _, _ in
            _ = await loads.record(name, allowDownload: allowDownload)
            throw BufferedBackendLoadRecorder.Failure.requestedReload
        })
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                _ = try await parakeet.transcribePreview(samples: [0], expectedVersion: .v3)
            }
            await #expect(throws: CancellationError.self) {
                _ = try await whisper.transcribePreview(samples: [0], expectedModel: "tiny")
            }
        }
        await cancelled.value
        #expect(await loads.values.isEmpty)
        // These calls must acquire the permits released by cancelled requests.
        await #expect(throws: BufferedBackendLoadRecorder.Failure.requestedReload) {
            _ = try await parakeet.transcribePreview(samples: [0], expectedVersion: .v3)
        }
        await #expect(throws: BufferedBackendLoadRecorder.Failure.requestedReload) {
            _ = try await whisper.transcribePreview(samples: [0], expectedModel: "tiny")
        }
        #expect(await loads.values == ["v3", "tiny"])
        #expect(await loads.downloadPermissions == [false, false])
    }

    @Test("Parakeet adapters defer text alignment mismatches without dropping recognized words", arguments: [false, true])
    func parakeetAlignmentDeferral(unified: Bool) throws {
        let align = unified ? ParakeetUnifiedTranscriber.previewWindow : FluidAudioTranscriber.previewWindow
        let words: [BufferedTranscriptionWord] = [.init(text: "hello", start: 0, end: 0.5, confidence: 0.9)]
        #expect(throws: BufferedTranscriptionPreviewDeferral.textAlignmentMismatch) {
            _ = try align("hello world", words)
        }
        #expect(throws: BufferedTranscriptionPreviewDeferral.textAlignmentMismatch) {
            _ = try align("hello", [])
        }
        let valid = try align("hello", words)
        #expect(valid.text == "hello")
        #expect(valid.words == words)
        let empty = try align("", [])
        #expect(empty.text.isEmpty)
        #expect(empty.words.isEmpty)
    }

    @Test("Whisper previews use one decode attempt while preserving language and final decode policy",
          arguments: [WhisperKitLanguage.auto, .tamil])
    func whisperPreviewDecodePolicy(language: WhisperKitLanguage) {
        for model in ["tiny", "tiny.en"] {
            let final = WhisperKitTranscriber.makeDecodeOptions(language: language, modelName: model)
            let preview = WhisperKitTranscriber.makePreviewDecodeOptions(language: language, modelName: model)
            #expect(preview.wordTimestamps)
            #expect(preview.temperatureFallbackCount == 0)
            #expect(preview.language == final.language)
            #expect(preview.detectLanguage == final.detectLanguage)
            #expect(final.temperatureFallbackCount == 5)
            #expect(!final.wordTimestamps)
        }
    }

    @Test("Whisper continuity decoding skips alignment without changing language or adding retries",
          arguments: [WhisperKitLanguage.auto, .tamil])
    func whisperContinuityDecodePolicy(language: WhisperKitLanguage) {
        for model in ["tiny", "tiny.en", "large-v3-v20240930_626MB"] {
            let timed = WhisperKitTranscriber.makePreviewDecodeOptions(language: language, modelName: model)
            let untimed = WhisperKitTranscriber.makePreviewDecodeOptions(
                language: language, modelName: model, requiresWordTimings: false)
            #expect(!untimed.wordTimestamps)
            #expect(untimed.temperatureFallbackCount == 0)
            #expect(untimed.language == timed.language)
            #expect(untimed.detectLanguage == timed.detectLanguage)
            if model.hasSuffix(".en") {
                #expect(untimed.language == nil && !untimed.detectLanguage)
            } else if language == .auto {
                #expect(untimed.detectLanguage)
            } else {
                #expect(untimed.language == "ta")
            }
        }
    }

    @Test("Whisper preview validation preserves timed Tamil, punctuation, and whitespace")
    func whisperPreviewPreservesValidScriptAndTiming() throws {
        let text = "வணக்கம் உலகம்."
        let words: [BufferedTranscriptionWord] = [
            .init(text: "வணக்கம்", start: 0.1, end: 0.5),
            .init(text: " உலகம்.", start: 0.6, end: 1)
        ]
        let window = try WhisperKitTranscriber.previewWindow(text: text, words: words, sampleCount: 16_000)
        #expect(window.text.utf16.elementsEqual(text.utf16))
        #expect(window.words.map(\.text).joined().utf16.elementsEqual(text.utf16))
        #expect(window.words.map(\.start) == [0.1, 0.6])
        #expect(window.words.map(\.end) == [0.5, 1])
        let empty = try WhisperKitTranscriber.previewWindow(text: "", words: [], sampleCount: 16_000)
        #expect(empty.text.isEmpty && empty.words.isEmpty)
    }

    @Test("Whisper missing words and text mismatch defer instead of inventing alignment")
    func whisperPreviewAlignmentDeferrals() {
        #expect(throws: BufferedTranscriptionPreviewDeferral.missingWordTimings) {
            try WhisperKitTranscriber.previewWindow(text: "keep every word", words: [], sampleCount: 16_000)
        }
        #expect(throws: BufferedTranscriptionPreviewDeferral.textAlignmentMismatch) {
            try WhisperKitTranscriber.previewWindow(text: "keep every word", words: [
                .init(text: "keep", start: 0, end: 0.5)
            ], sampleCount: 16_000)
        }
        #expect(throws: BufferedTranscriptionPreviewDeferral.textAlignmentMismatch) {
            try WhisperKitTranscriber.previewWindow(text: "Hello!", words: [
                .init(text: "Hello", start: 0, end: 0.5)
            ], sampleCount: 16_000)
        }
    }

    @Test("Whisper rejects padded thirty-second timestamps and nonfinite or reversed timing")
    func whisperPreviewNumericDeferrals() {
        let invalid: [(Double, Double)] = [(.nan, 1), (0, .infinity), (-0.01, 1), (1, 0.5), (0, 29.98)]
        for (start, end) in invalid {
            #expect(throws: BufferedTranscriptionPreviewDeferral.invalidWordTimings) {
                try WhisperKitTranscriber.previewWindow(text: "word", words: [
                    .init(text: "word", start: start, end: end)
                ], sampleCount: 16 * 16_000)
            }
        }
        #expect(throws: BufferedTranscriptionPreviewDeferral.invalidWordTimings) {
            try WhisperKitTranscriber.previewWindow(text: "first second", words: [
                .init(text: "first", start: 1, end: 1.5),
                .init(text: "second", start: 0.5, end: 1)
            ], sampleCount: 2 * 16_000)
        }
    }

    @Test("Whisper timing tolerance is bounded and does not clamp padded results")
    func whisperPreviewTimingTolerance() throws {
        let accepted = try WhisperKitTranscriber.previewWindow(text: "word", words: [
            .init(text: "word", start: 0, end: 1.25)
        ], sampleCount: 16_000)
        #expect(accepted.words.first?.end == 1.25)
        #expect(throws: BufferedTranscriptionPreviewDeferral.invalidWordTimings) {
            try WhisperKitTranscriber.previewWindow(text: "word", words: [
                .init(text: "word", start: 0, end: 1.251)
            ], sampleCount: 16_000)
        }
    }

    @Test("Whisper defers lexical runs collapsed onto one timestamp", arguments: [3, 6, 10])
    func whisperPreviewDefersCollapsedLexicalRun(zeroWords: Int) {
        var words: [BufferedTranscriptionWord] = [.init(text: "What", start: 2.6, end: 3.44)]
        let spellings = ["is", "the", "difference?"]
        for index in 0..<zeroWords {
            words.append(.init(text: spellings[index % spellings.count], start: 3.44, end: 3.44))
            // Punctuation has no independent acoustic support and cannot hide
            // a collapsed lexical run merely by becoming a separate token.
            if index == 1 { words.append(.init(text: ",", start: 3.44, end: 3.44)) }
        }
        words += [.init(text: "Diff", start: 3.44, end: 3.62),
                  .init(text: "means", start: 3.62, end: 3.94)]
        #expect(throws: BufferedTranscriptionPreviewDeferral.collapsedWordTimings) {
            try WhisperKitTranscriber.previewWindow(text: words.map(\.text).joined(separator: " "),
                words: words, sampleCount: 8 * 16_000)
        }
    }

    @Test("Whisper preserves isolated zero words, pairs, distinct times, and short positive multilingual timing")
    func whisperPreviewAcceptsNoncollapsedQuantizedWords() throws {
        let variants: [[BufferedTranscriptionWord]] = [
            [.init(text: "and", start: 0.1, end: 0.1), .init(text: "then", start: 0.1, end: 0.4)],
            [.init(text: "is", start: 0.1, end: 0.1), .init(text: "the", start: 0.1, end: 0.1), .init(text: "difference", start: 0.1, end: 0.5)],
            [.init(text: "one", start: 0.1, end: 0.1), .init(text: "two", start: 0.2, end: 0.2), .init(text: "three", start: 0.3, end: 0.3)],
            [.init(text: "வணக்கம்", start: 0.1, end: 0.1), .init(text: "உலகம்", start: 0.1, end: 0.12), .init(text: "இன்று", start: 0.12, end: 0.14)],
            [.init(text: "fast", start: 0.1, end: 0.12), .init(text: "spoken", start: 0.12, end: 0.14), .init(text: "words", start: 0.14, end: 0.16)],
            [.init(text: "-", start: 0.1, end: 0.1), .init(text: ",", start: 0.1, end: 0.1), .init(text: "!", start: 0.1, end: 0.1)]
        ]
        for words in variants {
            let text = words.map(\.text).joined(separator: " ")
            let window = try WhisperKitTranscriber.previewWindow(text: text, words: words, sampleCount: 16_000)
            #expect(window.text == text)
            #expect(window.words.map(\.start) == words.map(\.start))
            #expect(window.words.map(\.end) == words.map(\.end))
        }
    }

    @Test("Parakeet, Whisper, and Bodhan catalog models support buffered previews")
    func supportedModels() {
        let supported = [BackendOption.parakeetMultilingual, .parakeetEnglish, .parakeetRedux, .parakeetUnified]
            + BackendOption.whisperFamily + BackendOption.bodhanFamily
        for model in supported {
            #expect(model.supportsBufferedLiveTranscription)
            #expect(!model.isStreamingDictationBackend)
        }
        for model in BackendOption.all where !supported.contains(model) {
            #expect(!model.supportsBufferedLiveTranscription)
        }
    }

    @Test("Unified previews require loaded models and release their permit after cancellation")
    func unifiedPreviewPreconditions() async {
        let transcriber = ParakeetUnifiedTranscriber()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await transcriber.transcribePreview(samples: [0])
                Issue.record("Cancelled preview unexpectedly succeeded")
            } catch is CancellationError {
                // Cancellation is checked before touching Core ML.
            } catch {
                Issue.record("Expected cancellation, got \(error)")
            }
        }
        await cancelled.value
        do {
            _ = try await transcriber.transcribePreview(samples: [0])
            Issue.record("Unloaded preview unexpectedly succeeded")
        } catch ParakeetUnifiedTranscriber.TranscriberError.notLoaded {
            // This second call also proves the cancelled call released its permit.
        } catch {
            Issue.record("Expected notLoaded, got \(error)")
        }
        await transcriber.shutdown()
    }

    @Test("Old and malformed configurations do not enable live field mutation")
    func defaultOff() throws {
        #expect(!AppConfig().enableBufferedLiveDictation)
        for json in ["{}", #"{"enable_buffered_live_dictation":"true"}"#] {
            #expect(!(try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))).enableBufferedLiveDictation)
        }
    }

    @Test("Opt-in and meeting model persist independently")
    func persistence() throws {
        var config = AppConfig()
        config.enableBufferedLiveDictation = true
        config.enableLiveStreamingPartials = true
        config.meetingLiveCaptionBackend = MeetingLiveCaptionBackend.selectedModelBuffered.rawValue
        let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.enableBufferedLiveDictation)
        #expect(restored.enableLiveStreamingPartials)
        #expect(restored.resolvedMeetingLiveCaptionBackend == .selectedModelBuffered)
        #expect(!restored.resolvedMeetingLiveCaptionBackend.producesFinalTranscript)
        config.enableBufferedLiveDictation = false
        #expect(config.enableLiveStreamingPartials)
    }
}

private actor BufferedBackendLoadRecorder {
    enum Failure: Error, Equatable { case requestedReload }
    private(set) var values: [String] = []
    private(set) var downloadPermissions: [Bool] = []

    func record(_ value: String, allowDownload: Bool) -> Int {
        values.append(value)
        downloadPermissions.append(allowDownload)
        return values.count
    }
}
