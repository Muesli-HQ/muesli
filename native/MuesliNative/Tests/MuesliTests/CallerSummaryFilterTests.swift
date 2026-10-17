import Foundation
import MuesliCore
@testable import MuesliNativeApp
import Testing

@Suite("Caller summary filter")
struct CallerSummaryFilterTests {
    private func participant(_ identifier: String, _ name: String) -> MeetingParticipant {
        MeetingParticipant(
            meetingID: 1,
            participantIdentifier: identifier,
            displayName: name,
            emailAddress: nil,
            insertionOrder: 0
        )
    }

    @Test("Identified callers never reach summary prompts")
    func summaryNamesExcludeCallers() {
        let names = MuesliController.summaryParticipantNames(from: [
            participant("contact:1", "Bob"),
            participant("call-person:086aa82b-2ca7-5f63-b6b9-9a94cc45b53c", "Ann Lee"),
            participant("calendar:x", "Cy"),
        ])
        #expect(names == ["Bob", "Cy"])
    }
}
