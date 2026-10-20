import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Transcript chat message parsing")
struct TranscriptChatMessageTests {
    @Test("uncertain recorded-audio speakers retain their explicit labels")
    func uncertainSpeakers() {
        let messages = TranscriptChatMessage.messages(from: "[00:00:01] Multiple speakers: Hello\n[00:00:06] Unknown speaker: Goodbye")
        #expect(messages.map(\.speaker) == ["Multiple speakers", "Unknown speaker"])
        #expect(messages.map(\.text) == ["Hello", "Goodbye"])
        #expect(messages.allSatisfy { !$0.isUser })
    }

    @Test("in-room microphone speakers keep their local labels")
    func localSpeakers() {
        let messages = TranscriptChatMessage.messages(from: """
        [10:00:00] Local speaker 1: Ahoj.
        [10:00:02] Local speaker 12: Dobrý den.
        [10:00:05] Local speaker: Ano.
        """)
        #expect(messages.map(\.speaker) == ["Local speaker 1", "Local speaker 12", "Local speaker"])
        #expect(messages.map(\.text) == ["Ahoj.", "Dobrý den.", "Ano."])
        #expect(messages.allSatisfy { !$0.isUser })
    }

    @Test("timestamped speaker lines become chat messages")
    func timestampedSpeakerLinesBecomeChatMessages() {
        let messages = TranscriptChatMessage.messages(from: """
        [10:00:00] You: Hello there.
        [10:00:04] Speaker 1: Hi back.
        """)

        #expect(messages.count == 2)
        #expect(messages[0].timestamp == "10:00:00")
        #expect(messages[0].speaker == "You")
        #expect(messages[0].text == "Hello there.")
        #expect(messages[0].isUser)
        #expect(messages[1].speaker == "Speaker 1")
        #expect(messages[1].text == "Hi back.")
        #expect(!messages[1].isUser)
    }

    @Test("timestamped custom speaker labels survive without structured state")
    func timestampedCustomSpeakerLabels() {
        let messages = TranscriptChatMessage.messages(from: "[00:00:01] Alice: Hello there.")

        #expect(messages.count == 1)
        #expect(messages[0].speaker == "Alice")
        #expect(messages[0].text == "Hello there.")
    }

    @Test("plain transcript lines are preserved")
    func plainTranscriptLinesArePreserved() {
        let messages = TranscriptChatMessage.messages(from: """
        Product: launch timeline changed.

        This line has no speaker.
        """)

        #expect(messages.count == 2)
        #expect(messages[0].speaker == nil)
        #expect(messages[0].text == "Product: launch timeline changed.")
        #expect(messages[1].text == "This line has no speaker.")
    }

    @Test("live microphone headings are parsed as speaker labels")
    func microphoneHeading() {
        let messages = TranscriptChatMessage.messages(from: "[10:30:00] Microphone: Still verifying who spoke.")

        #expect(messages.count == 1)
        #expect(messages[0].timestamp == "10:30:00")
        #expect(messages[0].speaker == "Microphone")
        #expect(messages[0].text == "Still verifying who spoke.")
        #expect(!messages[0].isUser)
    }

    @Test("legacy custom headings preserve literal backslashes before colons")
    func legacyCustomHeadingPreservesBackslashBeforeColon() {
        let messages = TranscriptChatMessage.messages(from: "[10:00:00] Team\\: Room: Words")

        #expect(messages.count == 1)
        #expect(messages[0].speaker == "Team\\: Room")
        #expect(messages[0].text == "Words")
    }

    @Test("structured resumed state still displays the prior transcript prefix")
    func structuredResumeDisplaysPriorText() {
        let epoch = UUID()
        let current = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "current")
        var state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: current, rank: 1, fallbackLabel: "Microphone")],
            turns: [.init(speaker: current, timestamp: "10:30:00", start: 0, end: 2, text: "New words")])
        state.renderedPrefix = "[10:00:00] Speaker 1: Prior words\n\n— Resumed —\n\n"
        state.renderedPrefixSpeakerLabels = ["Speaker 1"]

        let messages = TranscriptChatMessage.messages(from: state.render(), speakerState: state)

        #expect(messages.map(\.speaker) == ["Speaker 1", nil, "Microphone"])
        #expect(messages.map(\.text) == ["Prior words", "— Resumed —", "New words"])
    }

    @Test("structured resume parses an exact manually assigned long speaker name")
    func structuredResumeParsesLongManualSpeakerName() {
        let epoch = UUID()
        let priorKey = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "prior")
        let currentKey = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "current")
        let longName = "Dr. Alexandra Montgomery-Wellington, Chief Negotiator"
        let priorState = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: priorKey, rank: 1, fallbackLabel: "Speaker 1",
                             assignment: .init(name: longName, provenance: .manual))],
            turns: [.init(speaker: priorKey, timestamp: "10:00:00", start: 0, end: 2, text: "Prior words")])
        let prior = MeetingResumePolicy.transcriptForResume(priorState.render(), speakerState: priorState)
        var currentState = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: currentKey, rank: 1, fallbackLabel: "Microphone")],
            turns: [.init(speaker: currentKey, timestamp: "10:30:00", start: 0, end: 2, text: "New words")])
        currentState.renderedPrefix = nil
        let resumed = MeetingResumePolicy.speakerStateForResume(
            priorTranscript: prior.text,
            currentTranscript: currentState.render(),
            currentState: currentState,
            priorSpeakerLabels: prior.speakerLabels
        )!

        let messages = TranscriptChatMessage.messages(from: resumed.render(), speakerState: resumed)
        #expect(messages.map(\.speaker) == [longName, nil, "Microphone"])
        #expect(messages.map(\.text) == ["Prior words", "— Resumed —", "New words"])
    }

    @Test("structured resume parses a manual speaker name containing a colon")
    func structuredResumeParsesColonManualSpeakerName() {
        let epoch = UUID()
        let priorKey = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "prior")
        let currentKey = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "current")
        let priorState = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: priorKey, rank: 1, fallbackLabel: "Speaker 1",
                             assignment: .init(name: "Team: Example", provenance: .manual))],
            turns: [.init(speaker: priorKey, timestamp: "10:00:00", start: 0, end: 2, text: "Prior words")])
        let prior = MeetingResumePolicy.transcriptForResume(priorState.render(), speakerState: priorState)
        let currentState = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: currentKey, rank: 1, fallbackLabel: "Microphone")],
            turns: [.init(speaker: currentKey, timestamp: "10:30:00", start: 0, end: 2, text: "New words")])
        let resumed = MeetingResumePolicy.speakerStateForResume(
            priorTranscript: prior.text,
            currentTranscript: currentState.render(),
            currentState: currentState,
            priorSpeakerLabels: prior.speakerLabels
        )!

        let messages = TranscriptChatMessage.messages(from: resumed.render(), speakerState: resumed)
        #expect(messages.map(\.speaker) == ["Team: Example", nil, "Microphone"])
        #expect(messages.map(\.text) == ["Prior words", "— Resumed —", "New words"])
    }

    @Test("legacy escaped resumed speaker labels remain distinct")
    func structuredResumeDisambiguatesEscapedManualNames() {
        let epoch = UUID()
        let currentKey = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "current")
        let priorTranscript = #"""
        [10:00:00] A\:q: First person's words
        [10:00:02] A\\\:q: Second person's words
        """#
        let currentState = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: currentKey, rank: 1, fallbackLabel: "Microphone")],
            turns: [.init(speaker: currentKey, timestamp: "10:30:00", start: 0, end: 2, text: "New words")])
        let resumed = MeetingResumePolicy.speakerStateForResume(
            priorTranscript: priorTranscript,
            currentTranscript: currentState.render(),
            currentState: currentState,
            priorSpeakerLabels: ["A:q", #"A\:q"#]
        )!

        let messages = TranscriptChatMessage.messages(from: resumed.render(), speakerState: resumed)

        #expect(messages.map(\.speaker) == ["A:q", #"A\:q"#, nil, "Microphone"])
        #expect(messages.map(\.text) == ["First person's words", "Second person's words", "— Resumed —", "New words"])
    }
}

extension TranscriptChatMessageTests {
    @Test func multilineStructuredTurnsKeepCitationIdentity() throws {
        let epoch = UUID()
        let first = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "first")
        let second = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "second")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: first, rank: 1, fallbackLabel: "Speaker 1"),
                       .init(key: second, rank: 2, fallbackLabel: "Speaker 2")],
            turns: [.init(speaker: first, timestamp: "00:00:01", start: 1, end: 2, text: "First line\ncontinued first line"),
                    .init(speaker: second, timestamp: "00:00:03", start: 3, end: 4, text: "Second turn")])
        let transcript = state.render()
        let messages = TranscriptChatMessage.messages(from: transcript, speakerState: state)
        let continued = (transcript as NSString).range(of: "continued first line")
        let secondTurn = (transcript as NSString).range(of: "Second turn")

        #expect(MeetingChatDocumentTarget.transcriptMessageID(
            in: transcript, range: continued, speakerState: state
        ) == 0)
        #expect(MeetingChatDocumentTarget.transcriptMessageID(
            in: transcript, range: secondTurn, speakerState: state
        ) == 1)
    }

    @Test func transcriptCitationScrollTargetWaitsForRowsToLoad() throws {
        let transcript = """
        [00:00:01] Speaker 1: First sentence.

        [00:00:03] Speaker 2: Cited sentence.
        """
        let range = (transcript as NSString).range(of: "Cited sentence")
        let expectedID = try #require(MeetingChatDocumentTarget.transcriptMessageID(in: transcript, range: range))
        let messages = TranscriptChatMessage.messages(from: transcript)

        #expect(MeetingChatDocumentTarget.loadedTranscriptScrollTarget(
            messages: [], highlightedMessageID: expectedID
        ) == nil)
        #expect(MeetingChatDocumentTarget.loadedTranscriptScrollTarget(
            messages: messages, highlightedMessageID: expectedID
        ) == expectedID)
    }

    @Test func structuredMessagesKeepIdentityAndColonNames() {
        let epoch = UUID()
        let a = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "a")
        let b = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "b")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: a, rank: 1, fallbackLabel: "Speaker 1", assignment: .init(name: "Team: Example", provenance: .manual)),
                       .init(key: b, rank: 2, fallbackLabel: "Speaker 2", assignment: .init(name: "You", provenance: .manual))],
            turns: [.init(speaker: a, timestamp: "00:00:01", start: 1, end: 2, text: "Product: unchanged"),
                    .init(speaker: b, timestamp: "00:00:03", start: 3, end: 4, text: "Second")])
        let messages = TranscriptChatMessage.messages(from: state.render(), speakerState: state)
        #expect(messages[0].speaker == "Team: Example")
        #expect(messages[0].text == "Product: unchanged")
        #expect(messages[0].speakerKey == a)
        #expect(messages[1].speakerKey == b)
        #expect(!messages[1].isUser)
        #expect(TranscriptChatMessage.messages(from: "Edited text", speakerState: state)[0].speakerKey == nil)
    }

    @Test func savedColonNamesRemainDistinctFromSpeechWithoutSpeakerState() {
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "colon-name")
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1",
                assignment: .init(name: "Team: Example\\Host", provenance: .manual))],
            turns: [.init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Product: unchanged")])

        let messages = TranscriptChatMessage.messages(from: state.render())

        #expect(messages.count == 1)
        #expect(messages[0].speaker == "Team: Example\\Host")
        #expect(messages[0].text == "Product: unchanged")
    }

    @Test func savedLongNamesRemainSpeakerLabelsWithoutSpeakerState() {
        let epoch = UUID()
        let key = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "long-name")
        let name = String(repeating: "L", count: 180)
        let state = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: key, rank: 1, fallbackLabel: "Speaker 1",
                assignment: .init(name: name, provenance: .manual))],
            turns: [.init(speaker: key, timestamp: "00:00:01", start: 1, end: 2, text: "Still speech")])

        let messages = TranscriptChatMessage.messages(from: state.render())

        #expect(messages.count == 1)
        #expect(messages[0].speaker == name)
        #expect(messages[0].text == "Still speech")
    }
}
