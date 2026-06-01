import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Speaker name substitution")
struct SpeakerNameSubstitutionTests {
    private func speaker(
        _ label: String,
        name: String?,
        state: SpeakerMatchState
    ) -> MeetingSpeaker {
        MeetingSpeaker(
            id: 1, meetingID: 1, speakerLabel: label, embedding: [0.1],
            profileID: name == nil ? nil : "p", displayName: name, matchDistance: nil, matchState: state
        )
    }

    private func map(_ speakers: [MeetingSpeaker]) -> [String: MeetingSpeaker] {
        SpeakerNameResolver.speakerMap(from: speakers)
    }

    @Test("replaces Speaker N and You labels, preserving timestamps and text")
    func replacesLabels() {
        let transcript = "[10:00:00] Speaker 1: Hello there\n[10:00:05] You: Hi"
        let speakers = map([speaker("Speaker 1", name: "Bob", state: .confirmed)])
        let out = SpeakerNameSubstitution.substitute(transcript: transcript, speakers: speakers, userName: "Spencer")
        #expect(out == "[10:00:00] Bob: Hello there\n[10:00:05] Spencer: Hi")
    }

    // Covers R10.
    @Test("named speakers appear in the summarizer input")
    func namesInInput() {
        let transcript = "[10:00:00] Speaker 1: pricing question"
        let speakers = map([speaker("Speaker 1", name: "Bob", state: .auto)])
        let out = SpeakerNameSubstitution.substitute(transcript: transcript, speakers: speakers, userName: "Me")
        #expect(out.contains("Bob:"))
        #expect(!out.contains("Speaker 1:"))
    }

    @Test("unmatched and suggested labels stay Speaker N")
    func unmatchedStays() {
        let transcript = "[10:00:00] Speaker 1: a\n[10:00:05] Speaker 2: b"
        let speakers = map([
            speaker("Speaker 1", name: nil, state: .unmatched),
            speaker("Speaker 2", name: "Bob", state: .suggested),
        ])
        let out = SpeakerNameSubstitution.substitute(transcript: transcript, speakers: speakers, userName: "Me")
        #expect(out == "[10:00:00] Speaker 1: a\n[10:00:05] Speaker 2: b")
    }

    @Test("You substitutes to the user name, or stays You when unset")
    func userNameSubstitution() {
        let transcript = "[10:00:00] You: hello"
        let named = SpeakerNameSubstitution.substitute(transcript: transcript, speakers: [:], userName: "Spencer")
        #expect(named == "[10:00:00] Spencer: hello")
        let unset = SpeakerNameSubstitution.substitute(transcript: transcript, speakers: [:], userName: "")
        #expect(unset == "[10:00:00] You: hello")
    }

    @Test("Others is left untouched")
    func othersUntouched() {
        let transcript = "[10:00:00] Others: muffled audio"
        let out = SpeakerNameSubstitution.substitute(transcript: transcript, speakers: [:], userName: "Me")
        #expect(out == transcript)
    }

    @Test("text containing colons is not mistaken for a speaker label")
    func colonInBody() {
        let transcript = "[10:00:00] Speaker 1: the ratio was 3:1 today"
        let speakers = map([speaker("Speaker 1", name: "Bob", state: .confirmed)])
        let out = SpeakerNameSubstitution.substitute(transcript: transcript, speakers: speakers, userName: "Me")
        #expect(out == "[10:00:00] Bob: the ratio was 3:1 today")
    }

    @Test("lines without a recognized label pass through unchanged")
    func nonLabelLines() {
        let transcript = "## Summary\nSome free-form note: with a colon"
        let out = SpeakerNameSubstitution.substitute(transcript: transcript, speakers: [:], userName: "Me")
        #expect(out == transcript)
    }

    @Test("labels without a timestamp prefix are also substituted")
    func noTimestampPrefix() {
        let transcript = "Speaker 1: hello"
        let speakers = map([speaker("Speaker 1", name: "Bob", state: .confirmed)])
        let out = SpeakerNameSubstitution.substitute(transcript: transcript, speakers: speakers, userName: "Me")
        #expect(out == "Bob: hello")
    }
}
