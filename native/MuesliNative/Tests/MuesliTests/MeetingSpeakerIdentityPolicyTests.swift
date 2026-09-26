import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting speaker identity policy")
struct MeetingSpeakerIdentityPolicyTests {
    private let session = UUID()
    private func speaker(_ source: MeetingSpeakerSource, _ id: String, _ evidence: MeetingSpeakerEvidence) -> MeetingSpeakerCandidate {
        MeetingSpeakerCandidate(key: MeetingSpeakerKey(session: session, source: source, clusterID: id), evidence: evidence)
    }
    private func participant(_ role: MeetingParticipantRole) -> MeetingIdentityParticipant {
        MeetingIdentityParticipant(id: "contact:fixture", name: "Example Person", role: role)
    }

    @Test("two anonymous mixed voices never imply self plus one selected contact")
    func mixedWithoutSelf() {
        let decision = MeetingSpeakerIdentityPolicy.resolve(speakers: [speaker(.mixed, "a", .unknown), speaker(.mixed, "b", .unknown)], participants: [participant(.remote)])
        #expect(decision.values.allSatisfy { $0.participantID == nil })
    }

    @Test("unknown calendar roles are not remote candidates")
    func unknownCalendar() {
        let speakers = [speaker(.microphone, "self", .sourceFallback), speaker(.system, "a", .supportedNonOwner)]
        let decision = MeetingSpeakerIdentityPolicy.resolve(speakers: speakers, participants: [participant(.unknown)])
        #expect(decision.values.allSatisfy { $0.participantID == nil })
    }

    @Test("one accepted self and one supported remote allow one contact assignment")
    func oneToOne() {
        let speakers = [speaker(.microphone, "self", .voiceVerified), speaker(.system, "a", .supportedNonOwner)]
        let decision = MeetingSpeakerIdentityPolicy.resolve(speakers: speakers, participants: [participant(.remote)])
        #expect(decision[speakers[0].key]?.label == "You")
        #expect(decision[speakers[1].key]?.participantID == "contact:fixture")
    }

    @Test("unresolved enrolled mic speech prevents remote inference")
    func unresolvedMic() {
        let speakers = [speaker(.microphone, "self", .unknown), speaker(.system, "a", .supportedNonOwner)]
        let decision = MeetingSpeakerIdentityPolicy.resolve(speakers: speakers, participants: [participant(.remote)])
        #expect(decision.values.allSatisfy { $0.participantID == nil && $0.label != "You" })
    }

    @Test("extra competing voice keeps all automatic contact assignments anonymous")
    func extraVoice() {
        let speakers = [speaker(.microphone, "self", .voiceVerified), speaker(.system, "a", .supportedNonOwner), speaker(.system, "b", .unknown)]
        let decision = MeetingSpeakerIdentityPolicy.resolve(speakers: speakers, participants: [participant(.remote)])
        #expect(decision.values.allSatisfy { $0.participantID == nil })
    }

    @Test("display labels sanitize controls and disambiguate duplicate and reserved names")
    func labelAllocation() {
        let keys = [speaker(.system, "a", .unknown).key, speaker(.system, "b", .unknown).key, speaker(.system, "c", .unknown).key]
        let labels = MeetingSpeakerIdentityPolicy.safeLabels([keys[0]: "You", keys[1]: "Long Unicode 名前: Example\nPerson", keys[2]: "Long Unicode 名前: Example\nPerson"])
        #expect(Set(labels.values).count == 3)
        #expect(labels[keys[0]] != "You")
        #expect(labels.values.allSatisfy { !$0.contains("\n") })
        #expect(labels[keys[1]]?.contains("名前:") == true)
    }
    @Test("each resumed capture preserves one-to-one identity without merging session keys")
    func resumedEvidence() {
        let first = [speaker(.microphone, "self", .voiceVerified), speaker(.system, "other", .supportedNonOwner)]
        let later = UUID()
        let second = [MeetingSpeakerCandidate(key: .init(session: later, source: .microphone, clusterID: "self"), evidence: .voiceVerified),
                      MeetingSpeakerCandidate(key: .init(session: later, source: .system, clusterID: "other"), evidence: .supportedNonOwner)]
        let result = MeetingSpeakerIdentityPolicy.resolve(speakers: first + second, participants: [participant(.remote)])
        #expect(result[first[0].key]?.label == "You")
        #expect(result[second[0].key]?.label == "You")
        #expect(result[first[1].key]?.participantID == "contact:fixture")
        #expect(result[second[1].key]?.participantID == "contact:fixture")
    }

}
