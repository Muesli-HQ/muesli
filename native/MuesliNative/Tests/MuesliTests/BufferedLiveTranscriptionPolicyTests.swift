import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Buffered live transcription eligibility and settings")
struct BufferedLiveTranscriptionPolicyTests {
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

    @Test("Whisper carries real segment boundaries without trusting padded trim hints")
    func whisperPreviewSegmentBoundaries() throws {
        let window = try WhisperKitTranscriber.previewWindow(text: "one two", words: [
            .init(text: "one", start: 0.1, end: 0.5),
            .init(text: " two", start: 0.6, end: 1)
        ], sampleCount: 16_000, segmentEnds: [1, .nan, 30, -1, .infinity, 0.5])
        #expect(window.segmentEnds == [0.5, 1])
        #expect(window.text == "one two")
        #expect(window.words.count == 2)
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

    @Test("All four batch Parakeet models and catalog Whisper models support buffered previews")
    func supportedModels() {
        let supported = [BackendOption.parakeetMultilingual, .parakeetEnglish, .parakeetRedux, .parakeetUnified]
            + BackendOption.whisperFamily
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
