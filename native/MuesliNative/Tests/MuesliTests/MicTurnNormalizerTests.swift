import FluidAudio
import Testing
@testable import MuesliNativeApp

@Suite("MicTurnNormalizer")
struct MicTurnNormalizerTests {

    @Test("falls back to one chunk-level turn when backend timings are not meaningful")
    func fallbackChunkLevelTurn() {
        let result = SpeechTranscriptionResult(
            text: "hello world",
            segments: [SpeechSegment(start: 0, end: 0, text: "hello world")]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 4.0,
            endTime: 7.0
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 4.0)
        #expect(segments[0].end == 7.0)
        #expect(segments[0].text == "hello world")
    }

    @Test("preserves phrase-like timings after normalization")
    func preservesPhraseLikeTimings() {
        let result = SpeechTranscriptionResult(
            text: "hello world again",
            segments: [
                SpeechSegment(start: 0.8, end: 1.4, text: "hello world"),
                SpeechSegment(start: 2.0, end: 2.6, text: "again later")
            ]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 10.0,
            endTime: 14.0
        )

        #expect(segments.count == 2)
        #expect(segments[0].start == 10.8)
        #expect(segments[0].end == 11.4)
        #expect(segments[0].text == "hello world")
        #expect(segments[1].start == 12.0)
        #expect(segments[1].end == 12.6)
        #expect(segments[1].text == "again later")
    }

    @Test("speaker attribution preserves reliable backend phrase timings")
    func preservesReliableSpeakerTimings() {
        let result = SpeechTranscriptionResult(
            text: "Owner words. Guest reply.",
            segments: [
                SpeechSegment(start: 0, end: 2, text: "Owner words."),
                SpeechSegment(start: 2.5, end: 3, text: "Guest reply."),
            ]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 10,
            endTime: 14,
            preserveReliableSpeakerTimings: true
        )

        #expect(segments.map(\.start) == [10, 12.5])
        #expect(segments.map(\.end) == [12, 13])
        #expect(segments.map(\.text) == ["Owner words.", "Guest reply."])
    }

    @Test("speaker attribution keeps untimed ASR text in one coarse chunk")
    func keepsUntimedTextCoarseForSpeakerAttribution() {
        let text = "Owner words. Guest reply. Owner continues."
        let result = SpeechTranscriptionResult(
            text: text,
            segments: [SpeechSegment(start: 0, end: 0, text: text)]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 10,
            endTime: 14,
            preserveReliableSpeakerTimings: true
        )

        #expect(segments.count == 1)
        #expect(segments[0].start == 10)
        #expect(segments[0].end == 14)
        #expect(segments[0].text == text)
    }

    @Test("collapses fragmented backend shards into sentence-split segments")
    func collapsesFragmentedShards() {
        let result = SpeechTranscriptionResult(
            text: "this is actually one interruption",
            segments: [
                SpeechSegment(start: 0.10, end: 0.15, text: "th"),
                SpeechSegment(start: 0.16, end: 0.20, text: "is"),
                SpeechSegment(start: 0.30, end: 0.33, text: "is"),
                SpeechSegment(start: 0.40, end: 0.44, text: "ac"),
                SpeechSegment(start: 0.45, end: 0.50, text: "tual"),
                SpeechSegment(start: 0.70, end: 0.74, text: "ly")
            ]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 20.0,
            endTime: 21.0
        )

        // Single sentence — stays as one segment
        #expect(segments.count == 1)
        #expect(segments[0].start == 20.0)
        #expect(segments[0].end == 21.0)
        #expect(segments[0].text == "this is actually one interruption")
    }

    @Test("splits multi-sentence text into separate segments when backend has no timings")
    func splitsSentencesWithNoTimings() {
        let text = "The meeting started well. We discussed the roadmap. Then we reviewed action items."
        let result = SpeechTranscriptionResult(
            text: text,
            segments: [SpeechSegment(start: 0, end: 0, text: text)]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 10.0,
            endTime: 40.0
        )

        #expect(segments.count == 3)
        #expect(segments[0].text == "The meeting started well.")
        #expect(segments[1].text == "We discussed the roadmap.")
        #expect(segments[2].text == "Then we reviewed action items.")

        // Proportional timing: timestamps should span 10..40 and be ordered
        #expect(segments[0].start == 10.0)
        #expect(segments[1].start > segments[0].start)
        #expect(segments[2].start > segments[1].start)
        #expect(segments[2].end <= 40.0)
    }

    @Test("full-session fallback produces multiple segments for long text")
    func fullSessionFallbackSplitsLongText() {
        let sentences = (1...20).map { "This is sentence number \($0) of the meeting." }
        let text = sentences.joined(separator: " ")
        let result = SpeechTranscriptionResult(
            text: text,
            segments: [SpeechSegment(start: 0, end: 0, text: text)]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 0,
            endTime: 1440.0
        )

        #expect(segments.count == 20)
        #expect(segments[0].start == 0)
        #expect(segments[19].end <= 1440.0)

        // Verify all segments have non-empty text and ordered timestamps
        for i in 1..<segments.count {
            #expect(segments[i].start >= segments[i - 1].start)
            #expect(!segments[i].text.isEmpty)
        }
    }

    @Test("fragmented shards with multi-sentence text produce sentence-level segments")
    func fragmentedShardsMultiSentence() {
        let text = "First we talked about the project. Then the budget was reviewed. Finally we assigned tasks."
        let result = SpeechTranscriptionResult(
            text: text,
            segments: [
                SpeechSegment(start: 0.1, end: 0.15, text: "Fi"),
                SpeechSegment(start: 0.2, end: 0.23, text: "rst"),
                SpeechSegment(start: 0.3, end: 0.33, text: "we"),
                SpeechSegment(start: 0.4, end: 0.44, text: "ta"),
                SpeechSegment(start: 0.5, end: 0.52, text: "lk"),
                SpeechSegment(start: 0.6, end: 0.63, text: "ed")
            ]
        )

        let segments = MicTurnNormalizer.normalize(
            result: result,
            startTime: 5.0,
            endTime: 35.0
        )

        #expect(segments.count == 3)
        #expect(segments[0].text == "First we talked about the project.")
        #expect(segments[1].text == "Then the budget was reviewed.")
        #expect(segments[2].text == "Finally we assigned tasks.")
        #expect(segments[0].start == 5.0)
        #expect(segments[2].end <= 35.0)
    }
}
