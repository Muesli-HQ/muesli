import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Buffered live transcription eligibility and settings")
struct BufferedLiveTranscriptionPolicyTests {
    @Test("Only Parakeet v3 and catalog Whisper models opt into buffered previews")
    func supportedModels() {
        #expect(BackendOption.parakeetMultilingual.supportsBufferedLiveTranscription)
        for model in BackendOption.all where model.backend == "whisper" {
            #expect(model.supportsBufferedLiveTranscription)
            #expect(!model.isStreamingDictationBackend)
        }
        for model in [BackendOption.parakeetUnified, .parakeetRedux, .parakeetEnglish, .nemotron35Multilingual] {
            #expect(!model.supportsBufferedLiveTranscription)
        }
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
