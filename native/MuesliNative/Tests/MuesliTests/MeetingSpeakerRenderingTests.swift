import Foundation
import FluidAudio
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting speaker rendering")
struct MeetingSpeakerRenderingTests {
    @Test("known long Unicode and colon names render without parsing arbitrary prose")
    func knownNames() {
        let name = "Example 名前: a very long speaker display name"
        let messages = TranscriptChatMessage.messages(from: "[00:00:01] \(name): Hello\nReminder: bring a notebook", knownSpeakers: [name: "stable-a"])
        #expect(messages.count == 2)
        #expect(messages[0].speaker == name)
        #expect(messages[0].speakerKey == "stable-a")
        #expect(messages[0].text == "Hello")
        #expect(messages[1].speaker == nil)
        #expect(messages[1].text == "Reminder: bring a notebook")
    }

    @Test("enrolled microphone speech without verification stays generic")
    func enrolledMicAbstains() {
        let state = TranscriptFormatter.structured(micSegments: [SpeechSegment(start: 1, end: 2, text: "Hello")], systemSegments: [], diarizationSegments: [], micDiarizationSegments: [], meetingStart: Date(timeIntervalSince1970: 0), session: UUID(), enrollmentEnabled: true)
        #expect(!state.renderedTranscript().contains("You:"))
        #expect(state.segments.count == 1)
        #expect(state.segments[0].text == "Hello")
    }

    @Test("recording adapter keeps finite embedding evidence across clipping")
    func retainedEvidence() {
        var vector = [Float](repeating: 0, count: 256)
        vector[0] = 1
        let segments = RecordedAudioDiarizationSession.clippedSegments([TimedSpeakerSegment(speakerId: "a", embedding: vector, startTimeSeconds: 0, endTimeSeconds: 5, qualityScore: 1)], start: 1, end: 4)
        #expect(segments.count == 1)
        #expect(segments[0].embedding == vector)
        #expect(segments[0].startTimeSeconds == 1)
    }
    @Test("provisional enrolled microphone copies without a premature owner label")
    func provisionalCopy() {
        #expect(LiveTranscriptCopyContent.text(transcript: "", partialYou: "Unverified words", partialOthers: "", microphoneLabel: "Microphone") == "Microphone: Unverified words")
        #expect(TranscriptChatMessage.messages(from: "Microphone: Unverified words").first?.isUser == false)
    }

    @Test("missing enrollment preserves established split-source fallback only")
    func sourceFallback() {
        let state = TranscriptFormatter.structured(micSegments: [SpeechSegment(start: 1, end: 2, text: "Hello")], systemSegments: [], diarizationSegments: [], micDiarizationSegments: [], meetingStart: Date(timeIntervalSince1970: 0), session: UUID(), enrollmentEnabled: false)
        #expect(state.renderedTranscript().contains("You: Hello"))
        let imported = TranscriptFormatter.structured(micSegments: [], systemSegments: [SpeechSegment(start: 1, end: 2, text: "Hello")], diarizationSegments: [], micDiarizationSegments: [], meetingStart: Date(timeIntervalSince1970: 0), session: UUID(), enrollmentEnabled: false, systemSource: .mixed)
        #expect(!imported.renderedTranscript().contains("You:"))
    }

    @Test("overlapping matching mic and system speech abstains from naming the system cluster")
    func matchingEchoAbstainsFromOneToOneIdentity() throws {
        let meetingStart = Date(timeIntervalSince1970: 0)
        let diarization = [TimedSpeakerSegment(speakerId: "single", embedding: [], startTimeSeconds: 1, endTimeSeconds: 3, qualityScore: 1)]
        let echoed = TranscriptFormatter.structured(
            micSegments: [SpeechSegment(start: 1, end: 3, text: "Can you hear me okay?")],
            systemSegments: [SpeechSegment(start: 1.05, end: 3, text: "Can you hear me okay?")],
            diarizationSegments: diarization,
            micDiarizationSegments: [],
            meetingStart: meetingStart,
            session: UUID(),
            enrollmentEnabled: false
        )
        let systemKey = try #require(echoed.candidates.first(where: { $0.key.source == .system })?.key)
        #expect(echoed.candidates.first(where: { $0.key == systemKey })?.evidence == .unknown)
        #expect(echoed.segments.count == 2)

        let distinctSpeech = TranscriptFormatter.structured(
            micSegments: [SpeechSegment(start: 1, end: 3, text: "Can you hear me okay?")],
            systemSegments: [SpeechSegment(start: 1.05, end: 3, text: "Yes, the meeting is clear.")],
            diarizationSegments: diarization,
            micDiarizationSegments: [],
            meetingStart: meetingStart,
            session: UUID(),
            enrollmentEnabled: false
        )
        #expect(distinctSpeech.candidates.first(where: { $0.key.source == .system })?.evidence == .supportedNonOwner)
    }

}
