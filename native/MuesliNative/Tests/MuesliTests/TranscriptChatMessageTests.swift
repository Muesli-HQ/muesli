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
}

extension TranscriptChatMessageTests {
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
}
