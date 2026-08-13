import FluidAudio
import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("TranscriptFormatter")
struct TranscriptFormatterTests {

    @Test("merges mic and system segments sorted by time")
    func mergesSortedByTime() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let mic = [
            SpeechSegment(start: 0.0, end: 2.0, text: "Hello from mic"),
            SpeechSegment(start: 5.0, end: 7.0, text: "More from mic"),
        ]
        let system = [
            SpeechSegment(start: 3.0, end: 4.5, text: "Hello from system"),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: mic, systemSegments: system, meetingStart: meetingStart
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines[0].contains("You: Hello from mic"))
        #expect(lines[1].contains("Others: Hello from system"))
        #expect(lines[2].contains("You: More from mic"))
    }

    @Test("includes timestamp in HH:mm:ss format")
    func timestampFormat() {
        var components = DateComponents()
        components.year = 2025; components.month = 1; components.day = 1
        components.hour = 14; components.minute = 30; components.second = 0
        let meetingStart = Calendar.current.date(from: components)!
        let mic = [SpeechSegment(start: 65.0, end: 67.0, text: "Test")]
        let result = TranscriptFormatter.merge(
            micSegments: mic, systemSegments: [], meetingStart: meetingStart
        )
        #expect(result.contains("[14:31:05]"))
    }

    @Test("handles empty segments")
    func emptySegments() {
        let result = TranscriptFormatter.merge(
            micSegments: [], systemSegments: [], meetingStart: Date()
        )
        #expect(result.isEmpty)
    }

    @Test("handles mic-only meeting")
    func micOnly() {
        let mic = [SpeechSegment(start: 0.0, end: 1.0, text: "Solo speaker")]
        let result = TranscriptFormatter.merge(
            micSegments: mic, systemSegments: [], meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(result.contains("You: Solo speaker"))
        #expect(!result.contains("Others"))
    }

    @Test("handles system-only meeting")
    func systemOnly() {
        let system = [SpeechSegment(start: 0.0, end: 1.0, text: "Remote speaker")]
        let result = TranscriptFormatter.merge(
            micSegments: [], systemSegments: system, meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(result.contains("Others: Remote speaker"))
        #expect(!result.contains("You"))
    }

    // MARK: - Token Consolidation

    @Test("consolidates consecutive tokens from same speaker")
    func consolidatesTokens() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        // Simulate token-level segments like Parakeet produces
        let system = [
            SpeechSegment(start: 1.0, end: 1.1, text: "Hel"),
            SpeechSegment(start: 1.1, end: 1.2, text: "lo"),
            SpeechSegment(start: 1.2, end: 1.4, text: " world"),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: [], systemSegments: system, meetingStart: meetingStart
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        #expect(lines[0].contains("Others: Hello world"))
    }

    @Test("consolidation splits on speaker change")
    func consolidationSplitsOnSpeakerChange() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let mic = [
            SpeechSegment(start: 0.0, end: 1.0, text: "I said"),
        ]
        let system = [
            SpeechSegment(start: 2.0, end: 2.5, text: "They said"),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: mic, systemSegments: system, meetingStart: meetingStart
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines[0].contains("You:"))
        #expect(lines[1].contains("Others:"))
    }

    @Test("consolidation inserts spacing between same-speaker chunk text")
    func consolidationPreservesChunkSpacing() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let system = [
            SpeechSegment(start: 0.0, end: 2.0, text: "This is the first sentence."),
            SpeechSegment(start: 2.1, end: 4.0, text: "This is the second sentence."),
        ]

        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            meetingStart: meetingStart
        )

        #expect(result.contains("Others: This is the first sentence. This is the second sentence."))
    }

    @Test("formatter preserves overlapping sources after reconciliation has happened upstream")
    func preservesOverlappingSources() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let mic = [
            SpeechSegment(start: 1.0, end: 2.0, text: "wait hold on"),
        ]
        let system = [
            SpeechSegment(start: 0.8, end: 2.2, text: "can you hear me okay"),
        ]

        let result = TranscriptFormatter.merge(
            micSegments: mic,
            systemSegments: system,
            meetingStart: meetingStart
        )

        #expect(result.contains("You: wait hold on"))
        #expect(result.contains("Others: can you hear me okay"))
    }

    @Test("formatter passes through mic segments without text-based bleed filtering")
    func passesThoughMicSegmentsWithoutBleedFiltering() {
        // Capture/transcription owns source validity. The formatter passes all
        // mic segments through without text-based filtering.
        let meetingStart = Date(timeIntervalSince1970: 0)
        let mic = [
            SpeechSegment(start: 1.0, end: 3.0, text: "can you hear me okay"),
        ]
        let system = [
            SpeechSegment(start: 1.05, end: 3.0, text: "can you hear me okay"),
        ]

        let result = TranscriptFormatter.merge(
            micSegments: mic,
            systemSegments: system,
            meetingStart: meetingStart
        )

        // Both mic and system segments appear — no text-based filtering
        #expect(result.contains("You: can you hear me okay"))
        #expect(result.contains("Others: can you hear me okay"))
    }

    @Test("preserves short meeting replies after consolidation")
    func preservesShortMeetingReplies() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let system = [
            SpeechSegment(start: 0.0, end: 0.15, text: "I"),
            SpeechSegment(start: 0.16, end: 2.0, text: "mean to be honest this is working"),
        ]
        let diarization = [
            makeDiarSeg(speakerId: "spk_0", start: 0.0, end: 0.15),
            makeDiarSeg(speakerId: "spk_1", start: 0.16, end: 2.0),
        ]

        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            diarizationSegments: diarization,
            meetingStart: meetingStart
        )

        #expect(result.contains("Speaker 1: I"))
        #expect(result.contains("Speaker 2: mean to be honest this is working"))
    }

    @Test("keeps isolated short replies when they are not artifact-like")
    func keepsIsolatedShortReplies() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let mic = [
            SpeechSegment(start: 0.0, end: 0.8, text: "No"),
        ]
        let system = [
            SpeechSegment(start: 2.0, end: 4.0, text: "that is a separate point"),
        ]

        let result = TranscriptFormatter.merge(
            micSegments: mic,
            systemSegments: system,
            meetingStart: meetingStart
        )

        #expect(result.contains("You: No"))
        #expect(result.contains("Others: that is a separate point"))
    }

    @Test("single segment not affected by consolidation")
    func singleSegmentConsolidation() {
        let result = TranscriptFormatter.merge(
            micSegments: [SpeechSegment(start: 0.0, end: 1.0, text: "Hello")],
            systemSegments: [],
            meetingStart: Date(timeIntervalSince1970: 0)
        )
        #expect(result.contains("You: Hello"))
    }

    // MARK: - Speaker Diarization

    @Test("diarization assigns speaker labels from diarization segments")
    func diarizationAssignsSpeakers() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let system = [
            SpeechSegment(start: 0.0, end: 5.0, text: "First person talking"),
            SpeechSegment(start: 6.0, end: 10.0, text: "Second person talking"),
        ]
        let diarization = [
            makeDiarSeg(speakerId: "spk_0", start: 0.0, end: 5.5),
            makeDiarSeg(speakerId: "spk_1", start: 5.5, end: 11.0),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            diarizationSegments: diarization,
            meetingStart: meetingStart
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines[0].contains("Speaker 1: First person talking"))
        #expect(lines[1].contains("Speaker 2: Second person talking"))
    }

    @Test("diarization labels ordered by first appearance")
    func diarizationLabelOrder() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let system = [
            SpeechSegment(start: 0.0, end: 3.0, text: "B speaks first"),
            SpeechSegment(start: 4.0, end: 7.0, text: "A speaks second"),
        ]
        // spk_B appears first chronologically
        let diarization = [
            makeDiarSeg(speakerId: "spk_B", start: 0.0, end: 3.5),
            makeDiarSeg(speakerId: "spk_A", start: 3.5, end: 8.0),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            diarizationSegments: diarization,
            meetingStart: meetingStart
        )
        // spk_B should be "Speaker 1" since it appears first
        #expect(result.contains("Speaker 1: B speaks first"))
        #expect(result.contains("Speaker 2: A speaks second"))
    }

    @Test("single-speaker diarization labels all system segments consistently")
    func singleSpeakerDiarizationFallback() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let system = [
            SpeechSegment(start: 0.0, end: 1.0, text: "First chunk"),
            SpeechSegment(start: 3.0, end: 4.0, text: "Second chunk"),
        ]
        let diarization = [
            makeDiarSeg(speakerId: "spk_0", start: 0.2, end: 0.8),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            diarizationSegments: diarization,
            meetingStart: meetingStart
        )
        #expect(result.contains("Speaker 1: First chunk Second chunk"))
        #expect(!result.contains("Others:"))
    }

    @Test("nil diarization segments falls back to Others labels")
    func nilDiarizationFallback() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let system = [SpeechSegment(start: 0.0, end: 1.0, text: "Test")]
        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            diarizationSegments: nil,
            meetingStart: meetingStart
        )
        #expect(result.contains("Others: Test"))
    }

    @Test("empty diarization segments falls back to Others labels")
    func emptyDiarizationFallback() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let system = [SpeechSegment(start: 0.0, end: 1.0, text: "Test")]
        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            diarizationSegments: [],
            meetingStart: meetingStart
        )
        #expect(result.contains("Others: Test"))
    }

    @Test("diarization picks best overlap when multiple speakers overlap")
    func diarizationBestOverlap() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        // ASR segment 2.0-8.0 overlaps with spk_A (0-4, overlap=2) and spk_B (3-10, overlap=5)
        let system = [
            SpeechSegment(start: 2.0, end: 8.0, text: "Who said this?"),
        ]
        let diarization = [
            makeDiarSeg(speakerId: "spk_A", start: 0.0, end: 4.0),
            makeDiarSeg(speakerId: "spk_B", start: 3.0, end: 10.0),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            diarizationSegments: diarization,
            meetingStart: meetingStart
        )
        // spk_B has more overlap (5s vs 2s)
        #expect(result.contains("Speaker 2: Who said this?"))
    }

    @Test("diarization with mic segments interleaves correctly")
    func diarizationWithMicInterleave() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let mic = [SpeechSegment(start: 5.0, end: 8.0, text: "My response")]
        let system = [
            SpeechSegment(start: 0.0, end: 4.0, text: "Remote question"),
            SpeechSegment(start: 10.0, end: 14.0, text: "Remote follow-up"),
        ]
        let diarization = [
            makeDiarSeg(speakerId: "spk_0", start: 0.0, end: 4.5),
            makeDiarSeg(speakerId: "spk_0", start: 9.0, end: 15.0),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: mic,
            systemSegments: system,
            diarizationSegments: diarization,
            meetingStart: meetingStart
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines[0].contains("Speaker 1:"))
        #expect(lines[1].contains("You:"))
        #expect(lines[2].contains("Speaker 1:"))
    }

    @Test("diarization consolidates consecutive diarized tokens from same speaker")
    func diarizationConsolidatesTokens() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        // Token-level segments all within same diarization speaker
        let system = [
            SpeechSegment(start: 1.0, end: 1.1, text: "Hel"),
            SpeechSegment(start: 1.1, end: 1.2, text: "lo"),
            SpeechSegment(start: 1.2, end: 1.3, text: " wor"),
            SpeechSegment(start: 1.3, end: 1.4, text: "ld"),
        ]
        let diarization = [
            makeDiarSeg(speakerId: "spk_0", start: 0.0, end: 5.0),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            diarizationSegments: diarization,
            meetingStart: meetingStart
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 1)
        #expect(lines[0].contains("Speaker 1: Hello world"))
    }

    @Test("three speakers identified correctly")
    func threeSpeakers() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let system = [
            SpeechSegment(start: 0.0, end: 3.0, text: "Alice talks"),
            SpeechSegment(start: 4.0, end: 7.0, text: "Bob talks"),
            SpeechSegment(start: 8.0, end: 11.0, text: "Charlie talks"),
        ]
        let diarization = [
            makeDiarSeg(speakerId: "alice", start: 0.0, end: 3.5),
            makeDiarSeg(speakerId: "bob", start: 3.5, end: 7.5),
            makeDiarSeg(speakerId: "charlie", start: 7.5, end: 12.0),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            diarizationSegments: diarization,
            meetingStart: meetingStart
        )
        #expect(result.contains("Speaker 1: Alice talks"))
        #expect(result.contains("Speaker 2: Bob talks"))
        #expect(result.contains("Speaker 3: Charlie talks"))
    }

    // MARK: - Source Attribution (Issue #97)

    @Test("system audio segments are never labelled as You")
    func systemAudioNeverLabelledAsYou() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let system = [
            SpeechSegment(start: 0.0, end: 2.0, text: "Can everyone hear me?"),
            SpeechSegment(start: 3.0, end: 5.0, text: "Let's discuss the agenda"),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: [], systemSegments: system, meetingStart: meetingStart
        )
        // System audio must be labelled "Others", never "You"
        #expect(!result.contains("You:"))
        #expect(result.contains("Others: Can everyone hear me?"))
        #expect(result.contains("Let's discuss the agenda"))
    }

    @Test("mic and system audio maintain correct labels when interleaved")
    func micAndSystemMaintainCorrectLabels() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let mic = [
            SpeechSegment(start: 0.0, end: 1.0, text: "Hello"),
            SpeechSegment(start: 4.0, end: 5.0, text: "Goodbye"),
        ]
        let system = [
            SpeechSegment(start: 2.0, end: 3.0, text: "Hi there"),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: mic, systemSegments: system, meetingStart: meetingStart
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 3)
        #expect(lines[0].contains("You: Hello"))
        #expect(lines[1].contains("Others: Hi there"))
        #expect(lines[2].contains("You: Goodbye"))
        // No system segment should be labelled as "You"
        for line in lines where line.contains("Hi there") {
            #expect(line.contains("Others:"), "System audio segment mislabeled: \(line)")
        }
    }

    @Test("system audio with diarization never falls back to You label")
    func systemAudioWithDiarizationNeverYou() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let system = [
            SpeechSegment(start: 0.0, end: 3.0, text: "Remote speaker talking"),
        ]
        let diarization = [
            makeDiarSeg(speakerId: "spk_0", start: 0.0, end: 3.5),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: [],
            systemSegments: system,
            diarizationSegments: diarization,
            meetingStart: meetingStart
        )
        // Must use diarized speaker label, not "You"
        #expect(!result.contains("You:"))
        #expect(result.contains("Speaker 1: Remote speaker talking"))
    }

    @Test("all system segments labelled as Others when no diarization available")
    func allSystemSegmentsLabelledOthers() {
        let meetingStart = Date(timeIntervalSince1970: 0)
        // Simulate a meeting with only system audio (e.g., listening to a call)
        let system = [
            SpeechSegment(start: 0.0, end: 2.0, text: "First point"),
            SpeechSegment(start: 2.5, end: 4.0, text: "Second point"),
            SpeechSegment(start: 5.0, end: 7.0, text: "Third point"),
        ]
        let result = TranscriptFormatter.merge(
            micSegments: [], systemSegments: system, meetingStart: meetingStart
        )
        let lines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        for line in lines {
            #expect(!line.contains("You:"), "System audio should never be labelled as You: \(line)")
        }
        #expect(lines.allSatisfy { $0.contains("Others:") })
    }

    // MARK: - Helpers

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
