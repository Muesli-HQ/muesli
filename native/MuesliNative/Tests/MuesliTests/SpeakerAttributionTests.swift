import FluidAudio
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("SpeakerAttribution")
struct SpeakerAttributionTests {
    @Test("total overlap per speaker wins over the single longest stretch")
    func summedOverlapWins() {
        let segment = SpeechSegment(start: 0, end: 6, text: "x")
        let speaker = SpeakerAttribution.speakerID(for: segment, in: [
            makeDiarSeg(speakerId: "a", start: 0.0, end: 1.8),
            makeDiarSeg(speakerId: "b", start: 1.8, end: 4.2),
            makeDiarSeg(speakerId: "a", start: 4.2, end: 6.0),
        ])
        #expect(speaker == "a")
    }

    @Test("equal overlap breaks ties by speaker ID")
    func equalOverlapTieIsDeterministic() {
        let segment = SpeechSegment(start: 0, end: 2, text: "x")
        let diarization = [
            makeDiarSeg(speakerId: "b", start: 0.0, end: 1.0),
            makeDiarSeg(speakerId: "a", start: 1.0, end: 2.0),
        ]
        #expect(SpeakerAttribution.speakerID(for: segment, in: diarization) == "a")
        #expect(SpeakerAttribution.speakerID(for: segment, in: diarization.reversed()) == "a")
    }

    @Test("zero-duration segment is widened so it can still overlap")
    func zeroDurationSegmentIsClamped() {
        let segment = SpeechSegment(start: 5, end: 5, text: "x")
        let speaker = SpeakerAttribution.speakerID(for: segment, in: [
            makeDiarSeg(speakerId: "a", start: 4.0, end: 5.02),
            makeDiarSeg(speakerId: "b", start: 5.02, end: 6.0),
        ])
        #expect(speaker == "b")
    }

    @Test("nearest speaker fallback accepts a gap of exactly the maximum")
    func nearestSpeakerGapBoundary() {
        // Segment midpoint 10.0; diarized speech ends at 8.0 → gap 2.0.
        let atLimit = SpeakerAttribution.speakerID(
            for: SpeechSegment(start: 9.5, end: 10.5, text: "x"),
            in: [makeDiarSeg(speakerId: "a", start: 0.0, end: 8.0)]
        )
        #expect(atLimit == "a")

        let beyondLimit = SpeakerAttribution.speakerID(
            for: SpeechSegment(start: 9.6, end: 10.6, text: "x"),
            in: [makeDiarSeg(speakerId: "a", start: 0.0, end: 8.0)]
        )
        #expect(beyondLimit == nil)
    }

    @Test("brief extra speakers are not significant")
    func briefSpeakersAreNotSignificant() {
        let ids = SpeakerAttribution.significantSpeakerIDs(in: [
            makeDiarSeg(speakerId: "a", start: 0, end: 60),
            makeDiarSeg(speakerId: "cough", start: 60, end: 60.4),
            makeDiarSeg(speakerId: "b", start: 60.4, end: 80),
        ])
        #expect(ids == ["a", "b"])
    }

    @Test("a speaker under the minimum share is not significant even past the minimum duration")
    func minimumShareFiltersLongMeetings() {
        // 6 s of 600 s is 1 %: AEC residue accumulated over a long call.
        let ids = SpeakerAttribution.significantSpeakerIDs(in: [
            makeDiarSeg(speakerId: "a", start: 0, end: 594),
            makeDiarSeg(speakerId: "residue", start: 594, end: 600),
        ])
        #expect(ids == ["a"])
    }

    @Test("local diarization is nil unless several significant voices remain")
    func localDiarizationRequiresSeveralVoices() {
        #expect(SpeakerAttribution.localDiarization(from: nil) == nil)
        #expect(SpeakerAttribution.localDiarization(from: []) == nil)
        #expect(SpeakerAttribution.localDiarization(from: [
            makeDiarSeg(speakerId: "a", start: 0, end: 60),
            makeDiarSeg(speakerId: "cough", start: 60, end: 60.4),
        ]) == nil)

        let local = SpeakerAttribution.localDiarization(from: [
            makeDiarSeg(speakerId: "a", start: 0, end: 30),
            makeDiarSeg(speakerId: "cough", start: 30, end: 30.4),
            makeDiarSeg(speakerId: "b", start: 30.4, end: 60),
        ])
        #expect(local?.map(\.speakerId) == ["a", "b"])
    }

    @Test("filtering local diarization is idempotent")
    func localDiarizationIsIdempotent() {
        let local = SpeakerAttribution.localDiarization(from: [
            makeDiarSeg(speakerId: "a", start: 0, end: 30),
            makeDiarSeg(speakerId: "cough", start: 30, end: 30.4),
            makeDiarSeg(speakerId: "b", start: 30.4, end: 60),
        ])
        let refiltered = SpeakerAttribution.localDiarization(from: local)
        #expect(refiltered?.map(\.speakerId) == local?.map(\.speakerId))
    }

    @Test("diagnostics count a single significant mic speaker as one")
    func diagnosticsCountSingleSignificantSpeaker() {
        let stats = MeetingSessionDiagnostics.MicDiarizationStats(rawSegments: [
            makeDiarSeg(speakerId: "a", start: 0, end: 60),
            makeDiarSeg(speakerId: "cough", start: 60, end: 60.4),
        ], error: nil)
        #expect(stats.speakers == 2)
        #expect(stats.localSpeakers == 1)
    }

    private func makeDiarSeg(speakerId: String, start: Float, end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1.0
        )
    }
}
