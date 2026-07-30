import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("SpeakerEnrollmentPolicy")
struct SpeakerEnrollmentPolicyTests {

    private func speaker(_ label: String, _ id: String, _ embedding: [Float] = [0.1, 0.2]) -> MeetingSpeakerRecord {
        MeetingSpeakerRecord(label: label, speakerID: id, embedding: embedding)
    }

    @Test("named speakers are enrolled under their name")
    func namedSpeakersAreEnrolled() {
        let plan = SpeakerEnrollmentPolicy.plan(
            speakers: [speaker("Speaker 1", "spk-a")],
            names: ["Speaker 1": "Priya"]
        )

        #expect(plan.enroll.map(\.id) == ["spk-a"])
        #expect(plan.enroll.map(\.name) == ["Priya"])
        #expect(plan.enroll.first?.embedding == [0.1, 0.2])
        #expect(plan.forget.isEmpty)
    }

    @Test("unnamed speakers are forgotten")
    func unnamedSpeakersAreForgotten() {
        let plan = SpeakerEnrollmentPolicy.plan(
            speakers: [speaker("Speaker 1", "spk-a"), speaker("Speaker 2", "spk-b")],
            names: ["Speaker 2": "Sam"]
        )

        #expect(plan.forget == ["spk-a"])
        #expect(plan.enroll.map(\.id) == ["spk-b"])
    }

    @Test("clearing a name forgets the voice rather than keeping it")
    func clearedNameForgetsVoice() {
        let plan = SpeakerEnrollmentPolicy.plan(
            speakers: [speaker("Speaker 1", "spk-a")],
            names: ["Speaker 1": "   "]
        )

        #expect(plan.enroll.isEmpty)
        #expect(plan.forget == ["spk-a"])
    }

    @Test("names are trimmed before enrolling")
    func namesAreTrimmed() {
        let plan = SpeakerEnrollmentPolicy.plan(
            speakers: [speaker("Speaker 1", "spk-a")],
            names: ["Speaker 1": "  Priya  "]
        )

        #expect(plan.enroll.map(\.name) == ["Priya"])
    }

    @Test("clusters without an embedding are skipped entirely")
    func clustersWithoutEmbeddingAreSkipped() {
        let plan = SpeakerEnrollmentPolicy.plan(
            speakers: [speaker("Speaker 1", "spk-a", [])],
            names: ["Speaker 1": "Priya"]
        )

        #expect(plan == SpeakerEnrollmentPolicy.Plan())
    }
}
