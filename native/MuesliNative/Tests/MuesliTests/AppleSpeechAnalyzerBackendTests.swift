import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Apple SpeechAnalyzer backend")
struct AppleSpeechAnalyzerBackendTests {
    @Test("volatile results do not duplicate finalized text")
    func accumulatorIgnoresVolatileResults() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.receive(text: "draft", isFinal: false, start: 0, end: 0.5)
        accumulator.receive(text: "Final words", isFinal: true, start: 0, end: 1.25)

        #expect(accumulator.text == "Final words")
        #expect(accumulator.segments.count == 1)
        #expect(accumulator.segments[0].start == 0)
        #expect(accumulator.segments[0].end == 1.25)
    }

    @Test("final segments are normalized and joined")
    func accumulatorBuildsTimestampedTranscript() {
        var accumulator = AppleSpeechTranscriptAccumulator()
        accumulator.receive(text: "  First segment  ", isFinal: true, start: -1, end: 1)
        accumulator.receive(text: "Second segment", isFinal: true, start: 1, end: .infinity)

        #expect(accumulator.text == "First segment Second segment")
        #expect(accumulator.segments.map(\.text) == ["First segment", "Second segment"])
        #expect(accumulator.segments[0].start == 0)
        #expect(accumulator.segments[1].end == 1)
    }

    @Test("backend is system managed and only catalogued when supported")
    func backendMetadata() {
        let option = BackendOption.appleSpeechAnalyzer

        #expect(option.backend == "apple-speech")
        #expect(option.isSystemManaged)
        #expect(option.supportsMeetingTranscription)
        #expect(!BackendOption.experimental.contains(option))
        if #available(macOS 26.0, *), AppleSpeechAnalyzerTranscriber.isSupportedOnCurrentSystem {
            #expect(BackendOption.systemManaged.contains(option))
            #expect(BackendOption.all.contains(option))
            #expect(BackendOption.onboardingDefault == option)
            #expect(BackendOption.onboarding.contains(option))
        } else {
            #expect(!BackendOption.systemManaged.contains(option))
            #expect(!BackendOption.all.contains(option))
            #expect(BackendOption.onboardingDefault == .parakeetMultilingual)
            #expect(!BackendOption.onboarding.contains(option))
        }
    }
}
