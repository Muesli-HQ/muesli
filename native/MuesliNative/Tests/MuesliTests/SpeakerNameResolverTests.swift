import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("Speaker name resolver")
struct SpeakerNameResolverTests {
    private func speaker(
        _ label: String,
        name: String?,
        state: SpeakerMatchState,
        profileID: String? = "p1"
    ) -> MeetingSpeaker {
        MeetingSpeaker(
            id: 1,
            meetingID: 1,
            speakerLabel: label,
            embedding: [0.1],
            profileID: profileID,
            displayName: name,
            matchDistance: 0.2,
            matchState: state
        )
    }

    @Test("You resolves to the configured user name")
    func userNameResolved() {
        let r = SpeakerNameResolver.resolve(label: "You", speakers: [:], userName: "Spencer")
        #expect(r.display == "Spencer")
        #expect(r.isUser)
        #expect(!r.isAutoRecognized)
    }

    @Test("You falls back to 'You' when the user name is unset")
    func userNameFallback() {
        let r = SpeakerNameResolver.resolve(label: "You", speakers: [:], userName: "   ")
        #expect(r.display == "You")
        #expect(r.isUser)
    }

    @Test("confirmed Speaker N resolves to the name without an auto indicator")
    func confirmedResolved() {
        let map = ["Speaker 1": speaker("Speaker 1", name: "Bob", state: .confirmed)]
        let r = SpeakerNameResolver.resolve(label: "Speaker 1", speakers: map, userName: "Me")
        #expect(r.display == "Bob")
        #expect(!r.isAutoRecognized)
        #expect(!r.isUser)
    }

    @Test("auto Speaker N resolves to the name with the auto indicator")
    func autoResolved() {
        let map = ["Speaker 1": speaker("Speaker 1", name: "Bob", state: .auto)]
        let r = SpeakerNameResolver.resolve(label: "Speaker 1", speakers: map, userName: "Me")
        #expect(r.display == "Bob")
        #expect(r.isAutoRecognized)
    }

    @Test("suggested Speaker N renders the raw label (name not applied)")
    func suggestedNotApplied() {
        let map = ["Speaker 1": speaker("Speaker 1", name: "Bob", state: .suggested)]
        let r = SpeakerNameResolver.resolve(label: "Speaker 1", speakers: map, userName: "Me")
        #expect(r.display == "Speaker 1")
        #expect(!r.isAutoRecognized)
    }

    @Test("Speaker N with no map entry stays the raw label")
    func noEntry() {
        let r = SpeakerNameResolver.resolve(label: "Speaker 2", speakers: [:], userName: "Me")
        #expect(r.display == "Speaker 2")
    }

    @Test("empty map leaves all labels raw and does not crash")
    func emptyMap() {
        let others = SpeakerNameResolver.resolve(label: "Others", speakers: [:], userName: "Me")
        #expect(others.display == "Others")
        #expect(!others.isUser)
    }

    @Test("auto/confirmed entry with blank name falls back to the raw label")
    func blankNameFallback() {
        let map = ["Speaker 1": speaker("Speaker 1", name: "  ", state: .auto)]
        let r = SpeakerNameResolver.resolve(label: "Speaker 1", speakers: map, userName: "Me")
        #expect(r.display == "Speaker 1")
    }

    @Test("speakerMap builds a label-keyed lookup")
    func buildsLookup() {
        let speakers = [
            speaker("Speaker 1", name: "Bob", state: .confirmed),
            MeetingSpeaker(id: 2, meetingID: 1, speakerLabel: "Speaker 2", embedding: [0.2]),
        ]
        let map = SpeakerNameResolver.speakerMap(from: speakers)
        #expect(map["Speaker 1"]?.displayName == "Bob")
        #expect(map["Speaker 2"]?.matchState == .unmatched)
    }
}
