import FluidAudio
import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("TranscriptReconciler")
struct TranscriptReconcilerTests {

    @Test("keeps overlapping mic turns when preserving local speech is safer")
    func keepsOverlappingMicTurn() {
        let mic = [
            SpeechSegment(start: 0.0, end: 0.8, text: "barking first")
        ]
        let system = [
            SpeechSegment(start: 0.0, end: 1.2, text: "barking first, but")
        ]

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: mic,
            systemSegments: system,
            diarizationSegments: nil
        )

        #expect(reconciled.micSegments.count == 1)
        #expect(reconciled.micSegments[0].text == "barking first")
        #expect(reconciled.systemSegments.count == 1)
    }

    @Test("keeps substantive mic interruptions over system audio")
    func keepsSubstantiveMicInterruption() {
        let mic = [
            SpeechSegment(start: 1.0, end: 2.0, text: "wait hold on a second")
        ]
        let system = [
            SpeechSegment(start: 0.8, end: 2.2, text: "can you hear me okay"),
            SpeechSegment(start: 1.05, end: 1.15, text: "can")
        ]

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: mic,
            systemSegments: system,
            diarizationSegments: [makeDiarSeg(speakerId: "spk_0", start: 0.5, end: 2.5)]
        )

        #expect(reconciled.micSegments.count == 1)
        #expect(reconciled.micSegments[0].text == "wait hold on a second")
        #expect(reconciled.systemSegments.count == 1)
        #expect(reconciled.systemSegments[0].text == "can you hear me okay")
    }

    @Test("keeps ambiguous long mic turns when overlap cannot be resolved confidently")
    func keepsAmbiguousLongMicTurn() {
        let mic = [
            SpeechSegment(
                start: 10.0,
                end: 14.0,
                text: "Nice to meet you everyone and thanks for joining the creative team"
            )
        ]
        let system = [
            SpeechSegment(start: 10.1, end: 11.0, text: "Nice to meet you Timothy"),
            SpeechSegment(start: 11.1, end: 12.2, text: "I am the digital content executive director"),
            SpeechSegment(start: 12.3, end: 13.7, text: "Happy to be here and thanks for having me")
        ]

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: mic,
            systemSegments: system,
            diarizationSegments: nil
        )

        #expect(reconciled.micSegments.count == 1)
        #expect(reconciled.micSegments[0].text.contains("Nice to meet you everyone"))
        #expect(reconciled.systemSegments.count == 3)
    }

    @Test("keeps Devanagari system turns")
    func keepsDevanagariSystemTurns() {
        let system = [
            SpeechSegment(start: 2.0, end: 4.0, text: "रिश्ते में संवाद जरूरी है")
        ]

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: [],
            systemSegments: system,
            diarizationSegments: nil
        )

        #expect(reconciled.systemSegments.count == 1)
        #expect(reconciled.systemSegments[0].text == "रिश्ते में संवाद जरूरी है")
    }

    @Test("preserves Indic combining marks while deduplicating short overlaps")
    func preservesIndicCombiningMarksDuringDeduplication() {
        let system = [
            SpeechSegment(start: 0.0, end: 0.8, text: "कि"),
            SpeechSegment(start: 0.1, end: 0.7, text: "क")
        ]

        let reconciled = TranscriptReconciler.reconcile(
            micTurns: [],
            systemSegments: system,
            diarizationSegments: nil
        )

        #expect(reconciled.systemSegments.map(\.text) == ["कि", "क"])
    }

    // MARK: - Microphone diarization

    private var greetingSentences: [SpeechSegment] {
        [
            SpeechSegment(start: 0.0, end: 2.0, text: "Ahoj, paní Václavková."),
            SpeechSegment(start: 2.0, end: 4.0, text: "Ahoj, pane Václavku."),
        ]
    }

    @Test("contiguous mic sentences still merge without mic diarization")
    func contiguousMicSentencesMergeWithoutMicDiarization() {
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: greetingSentences,
            systemSegments: [],
            diarizationSegments: nil
        )

        #expect(reconciled.micSegments.map(\.text) == ["Ahoj, paní Václavková. Ahoj, pane Václavku."])
    }

    @Test("contiguous mic sentences from different local speakers stay separate")
    func contiguousMicSentencesFromDifferentSpeakersStaySeparate() {
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: greetingSentences,
            systemSegments: [],
            diarizationSegments: nil,
            micDiarizationSegments: significant([
                makeDiarSeg(speakerId: "room_a", start: 0.0, end: 2.1),
                makeDiarSeg(speakerId: "room_b", start: 2.1, end: 4.0),
            ])
        )

        #expect(reconciled.micSegments.map(\.text) == ["Ahoj, paní Václavková.", "Ahoj, pane Václavku."])
    }

    @Test("contiguous mic sentences from the same local speaker still merge")
    func contiguousMicSentencesFromSameSpeakerMerge() {
        let mic = greetingSentences + [SpeechSegment(start: 4.0, end: 6.0, text: "Jak se máte?")]
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: mic,
            systemSegments: [],
            diarizationSegments: nil,
            micDiarizationSegments: significant([
                makeDiarSeg(speakerId: "room_a", start: 0.0, end: 2.0),
                makeDiarSeg(speakerId: "room_b", start: 2.0, end: 6.0),
            ])
        )

        #expect(reconciled.micSegments.map(\.text) == ["Ahoj, paní Václavková.", "Ahoj, pane Václavku. Jak se máte?"])
    }

    @Test("single-speaker mic diarization keeps the existing merge")
    func singleSpeakerMicDiarizationKeepsExistingMerge() {
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: greetingSentences,
            systemSegments: [],
            diarizationSegments: nil,
            micDiarizationSegments: [makeDiarSeg(speakerId: "room_a", start: 0.0, end: 4.0)]
        )

        #expect(reconciled.micSegments.count == 1)
    }

    @Test("split mic turns get separate local speaker labels in the transcript")
    func splitMicTurnsGetSeparateLabels() {
        let micDiarization = significant([
            makeDiarSeg(speakerId: "room_a", start: 0.0, end: 2.1),
            makeDiarSeg(speakerId: "room_b", start: 2.1, end: 4.0),
        ])
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: greetingSentences,
            systemSegments: [],
            diarizationSegments: nil,
            micDiarizationSegments: micDiarization
        )
        let transcript = TranscriptFormatter.merge(
            micSegments: reconciled.micSegments,
            systemSegments: reconciled.systemSegments,
            diarizationSegments: nil,
            micDiarizationSegments: micDiarization,
            meetingStart: Date(timeIntervalSince1970: 0)
        )
        let lines = transcript.components(separatedBy: "\n")

        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("Local speaker 1: Ahoj, paní Václavková."))
        #expect(lines[1].hasSuffix("Local speaker 2: Ahoj, pane Václavku."))
    }

    private func localTranscript(
        micTurns: [SpeechSegment],
        micDiarization: [TimedSpeakerSegment]
    ) -> [String] {
        let micDiarization = significant(micDiarization)
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: micTurns,
            systemSegments: [],
            diarizationSegments: nil,
            micDiarizationSegments: micDiarization
        )
        return TranscriptFormatter.merge(
            micSegments: reconciled.micSegments,
            systemSegments: [],
            diarizationSegments: nil,
            micDiarizationSegments: micDiarization,
            meetingStart: Date(timeIntervalSince1970: 0)
        ).components(separatedBy: "\n")
    }

    @Test("finalized streaming chunk with two local speakers is split by sentence")
    func finalizedStreamingChunkIsSplitBySentence() {
        let timing = MeetingChunkTimingSnapshot(startSampleIndex: 0, sampleCount: 64_000)
        let micTurns = MeetingSession.segmentsFromFinalizedText(
            "Ahoj, paní Václavková. Ahoj, pane Václavku.",
            timing: timing
        )
        #expect(micTurns.count == 1)

        let lines = localTranscript(micTurns: micTurns, micDiarization: [
            makeDiarSeg(speakerId: "room_a", start: 0.0, end: 2.1),
            makeDiarSeg(speakerId: "room_b", start: 2.1, end: 4.0),
        ])

        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("Local speaker 1: Ahoj, paní Václavková."))
        #expect(lines[1].hasSuffix("Local speaker 2: Ahoj, pane Václavku."))
    }

    @Test("timed backend segments merged by the normalizer are split by sentence")
    func normalizerMergedTimedSegmentsAreSplitBySentence() {
        let result = SpeechTranscriptionResult(
            text: "Ahoj, paní Václavková. Ahoj, pane Václavku.",
            segments: [
                SpeechSegment(start: 0.0, end: 1.9, text: "Ahoj, paní Václavková."),
                SpeechSegment(start: 2.0, end: 3.9, text: "Ahoj, pane Václavku."),
            ]
        )
        let micTurns = MicTurnNormalizer.normalize(result: result, startTime: 0, endTime: 4)
        #expect(micTurns.count == 1)

        let lines = localTranscript(micTurns: micTurns, micDiarization: [
            makeDiarSeg(speakerId: "room_a", start: 0.0, end: 2.0),
            makeDiarSeg(speakerId: "room_b", start: 2.0, end: 3.9),
        ])

        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("Local speaker 1: Ahoj, paní Václavková."))
        #expect(lines[1].hasSuffix("Local speaker 2: Ahoj, pane Václavku."))
    }

    @Test("merging mic turns never changes their resolved local speaker")
    func mergingMicTurnsKeepsResolvedSpeaker() {
        let micTurns = [
            SpeechSegment(start: 0, end: 3, text: "First."),
            SpeechSegment(start: 3, end: 6, text: "Second."),
            SpeechSegment(start: 6, end: 9, text: "Third."),
        ]

        let lines = localTranscript(micTurns: micTurns, micDiarization: [
            makeDiarSeg(speakerId: "room_a", start: 0.0, end: 1.8),
            makeDiarSeg(speakerId: "room_b", start: 1.8, end: 4.2),
            makeDiarSeg(speakerId: "room_a", start: 4.2, end: 6.0),
            makeDiarSeg(speakerId: "room_b", start: 6.0, end: 9.0),
        ])

        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix("Local speaker 1: First. Second."))
        #expect(lines[1].hasSuffix("Local speaker 2: Third."))
    }

    @Test("a brief extra mic diarizer speaker does not split the mic channel")
    func briefExtraMicSpeakerDoesNotSplit() {
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: greetingSentences,
            systemSegments: [],
            diarizationSegments: nil,
            micDiarizationSegments: [
                makeDiarSeg(speakerId: "room_a", start: 0.0, end: 2.0),
                makeDiarSeg(speakerId: "room_b", start: 2.0, end: 2.4),
                makeDiarSeg(speakerId: "room_a", start: 2.4, end: 60.0),
            ]
        )

        #expect(reconciled.micSegments.count == 1)
        #expect(reconciled.micDiarizationSegments == nil)
    }

    @Test("reconciled inputs carry only the significant local speakers")
    func reconciledInputsCarryOnlySignificantLocalSpeakers() {
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: greetingSentences,
            systemSegments: [],
            diarizationSegments: nil,
            micDiarizationSegments: significant([
                makeDiarSeg(speakerId: "room_a", start: 0.0, end: 2.1),
                makeDiarSeg(speakerId: "room_b", start: 2.1, end: 4.0),
            ]) + [makeDiarSeg(speakerId: "cough", start: 4.0, end: 4.3)]
        )

        #expect(Set(reconciled.micDiarizationSegments?.map(\.speakerId) ?? []) == ["room_a", "room_b"])
    }

    @Test("consecutive mic turns without diarization coverage still merge")
    func consecutiveUncoveredMicTurnsMerge() {
        let reconciled = TranscriptReconciler.reconcile(
            micTurns: [
                SpeechSegment(start: 30.0, end: 32.0, text: "Far away."),
                SpeechSegment(start: 32.0, end: 34.0, text: "Still far."),
            ],
            systemSegments: [],
            diarizationSegments: nil,
            micDiarizationSegments: significant([
                makeDiarSeg(speakerId: "room_a", start: 0.0, end: 2.0),
                makeDiarSeg(speakerId: "room_b", start: 2.0, end: 4.0),
            ])
        )

        // Both resolve to no speaker (nil == nil), so they read as one unattributed turn.
        #expect(reconciled.micSegments.map(\.text) == ["Far away. Still far."])
    }

    /// Adds far-away speech so every speaker passes the significance filter
    /// without changing who the tested turns resolve to.
    private func significant(_ segments: [TimedSpeakerSegment]) -> [TimedSpeakerSegment] {
        let speakerIDs = Set(segments.map(\.speakerId)).sorted()
        return segments + speakerIDs.enumerated().map { index, speakerID in
            makeDiarSeg(speakerId: speakerID, start: 1_000 + Float(index) * 10, end: 1_010 + Float(index) * 10)
        }
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
