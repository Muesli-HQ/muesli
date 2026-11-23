import FluidAudio
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Speaker identity pipeline")
struct SpeakerIdentityPipelineTests {
    private var meetingStart: Date {
        Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_800_000_000))!
    }

    private let mic = [SpeechSegment(start: 0, end: 2, text: "hello there")]
    private let system = [
        SpeechSegment(start: 3, end: 5, text: "hi from one"),
        SpeechSegment(start: 6, end: 8, text: "hi from two"),
        SpeechSegment(start: 9, end: 11, text: "back to one"),
    ]

    private func segment(_ id: String, _ start: Float, _ end: Float, _ embedding: [Float] = []) -> TimedSpeakerSegment {
        TimedSpeakerSegment(speakerId: id, embedding: embedding, startTimeSeconds: start, endTimeSeconds: end, qualityScore: 1)
    }

    private var diarization: [TimedSpeakerSegment] {
        [segment("a", 3, 5.5), segment("b", 6, 8.5), segment("a", 9, 11.5)]
    }

    private let golden = """
    [10:00:00] You: hello there
    [10:00:03] Speaker 1: hi from one
    [10:00:06] Speaker 2: hi from two
    [10:00:09] Speaker 1: back to one
    """

    @Test("formatter output is byte-identical to the pre-feature golden when no profile matches")
    func noProfilesGolden() {
        let plain = TranscriptFormatter.merge(
            micSegments: mic, systemSegments: system, diarizationSegments: diarization, meetingStart: meetingStart
        )
        #expect(plain == golden)
        let withEmptyNames = TranscriptFormatter.merge(
            micSegments: mic, systemSegments: system, diarizationSegments: diarization,
            meetingStart: meetingStart, speakerNames: [:]
        )
        #expect(withEmptyNames == golden)
    }

    @Test("matched speakers render by profile name; others keep Speaker N")
    func namesRendered() {
        let named = TranscriptFormatter.merge(
            micSegments: mic, systemSegments: system, diarizationSegments: diarization,
            meetingStart: meetingStart, speakerNames: ["Speaker 2": "Alex"]
        )
        #expect(named == golden.replacingOccurrences(of: "Speaker 2:", with: "Alex:"))
    }

    @Test("speaker labels follow first-appearance order")
    func labelOrder() {
        let labels = TranscriptFormatter.speakerLabels(for: [segment("z", 6, 7), segment("q", 1, 2), segment("z", 8, 9)])
        #expect(labels == ["q": "Speaker 1", "z": "Speaker 2"])
        #expect(TranscriptFormatter.speakerLabels(for: []).isEmpty)
    }

    // MARK: - Centroids

    @Test("centroid is the duration-weighted mean of normalized embeddings")
    func centroidWeighting() {
        let observations = SpeakerCentroidBuilder.observations(
            from: [
                segment("a", 0, 6, [2, 0]),   // 6 s along x (unnormalized input)
                segment("a", 6, 8, [0, 1]),   // 2 s along y
            ],
            minimumSeconds: 1
        )
        #expect(observations.count == 1)
        let centroid = observations[0].centroid!
        // weighted mean (0.75, 0.25) renormalized
        let norm = (0.75 * 0.75 + 0.25 * 0.25 as Float).squareRoot()
        #expect(abs(centroid[0] - 0.75 / norm) < 0.0001)
        #expect(abs(centroid[1] - 0.25 / norm) < 0.0001)
        #expect(observations[0].label == "Speaker 1")
        #expect(abs(observations[0].speechSeconds - 8) < 0.0001)
    }

    @Test("a speaker with too little audio gets no centroid but keeps a row")
    func tooLittleAudio() {
        let observations = SpeakerCentroidBuilder.observations(
            from: [segment("a", 0, 2, [1, 0]), segment("b", 3, 20, [0, 1])],
            minimumSeconds: SpeakerCentroidBuilder.minimumVoiceprintSeconds
        )
        #expect(observations.map(\.label) == ["Speaker 1", "Speaker 2"])
        #expect(observations[0].centroid == nil)
        #expect(observations[1].centroid != nil)
    }

    @Test("zero, one, and invalid-embedding speakers are handled")
    func degenerateInputs() {
        #expect(SpeakerCentroidBuilder.observations(from: [], minimumSeconds: 1).isEmpty)
        let one = SpeakerCentroidBuilder.observations(from: [segment("a", 0, 30, [0, 3])], minimumSeconds: 1)
        #expect(one.count == 1 && one[0].centroid == [0, 1])
        let invalid = SpeakerCentroidBuilder.observations(
            from: [segment("a", 0, 30, [.nan, 1]), segment("a", 30, 60, [0, 0]), segment("b", 60, 90, [])],
            minimumSeconds: 1
        )
        #expect(invalid.count == 2)
        #expect(invalid.allSatisfy { $0.centroid == nil })
    }

    @Test("mixed embedding dimensions within one speaker do not crash and use the majority dimension")
    func mixedDimensions() {
        let observations = SpeakerCentroidBuilder.observations(
            from: [segment("a", 0, 20, [1, 0]), segment("a", 20, 21, [0, 0, 1])],
            minimumSeconds: 1
        )
        #expect(observations.first?.centroid == [1, 0])
    }

    @Test("SpeakerCentroid observations recover centroids from speakerEmbeddings when segment embeddings are empty")
    func speakerCentroidFallbackFromStrippedSegments() throws {
        let segments = [
            segment("a", 0, 6),
            segment("a", 6, 11),
            segment("b", 12, 21.5),
            segment("c", 22, 35),
        ]
        let observations = SpeakerCentroidBuilder.observations(
            from: segments,
            speakerEmbeddings: [
                "a": [3, 4],
                "b": [1, 0],
                "c": [0, 0],
            ]
        )
        #expect(observations.map(\.label) == ["Speaker 1", "Speaker 2", "Speaker 3"])

        let speaker1Centroid = try #require(observations[0].centroid)
        #expect(SpeakerVoiceprintMatcher.isUsable(speaker1Centroid))
        #expect(abs(speaker1Centroid[0] - 0.6) < 0.0001)
        #expect(abs(speaker1Centroid[1] - 0.8) < 0.0001)
        #expect(abs(observations[0].speechSeconds - 11) < 0.0001)

        #expect(observations[1].centroid == nil)
        #expect(abs(observations[1].speechSeconds - 9.5) < 0.0001)
        #expect(observations[2].centroid == nil)
    }

    @Test("startingSpeakerNumber offsets both observations and formatted transcript for resumed meetings")
    func resumedSpeakerNumberOffsetPipeline() throws {
        let session2Diarization = [segment("x", 3, 5.5), segment("y", 6, 8.5)]
        let session2Labels = TranscriptFormatter.speakerLabels(for: session2Diarization, startingNumber: 3)
        #expect(session2Labels == ["x": "Speaker 3", "y": "Speaker 4"])

        let observations = SpeakerCentroidBuilder.observations(
            from: [segment("x", 0, 15, [1, 0]), segment("y", 15, 30, [0, 1])],
            startingNumber: 3
        )
        #expect(observations.map(\.label) == ["Speaker 3", "Speaker 4"])

        let formatted = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: [
                SpeechSegment(start: 3, end: 5, text: "resumed part one"),
                SpeechSegment(start: 6, end: 8, text: "resumed part two"),
            ],
            diarizationSegments: session2Diarization,
            meetingStart: meetingStart,
            speakerNames: ["Speaker 3": "Alex"],
            startingSpeakerNumber: 3
        )
        #expect(formatted == """
        [10:00:03] Alex: resumed part one
        [10:00:06] Speaker 4: resumed part two
        """)
    }
}
