import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Buffered live transcription eligibility and settings")
struct BufferedLiveTranscriptionPolicyTests {
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
