import Contacts
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Meeting contact creation flow")
struct MeetingContactCreationFlowTests {
    private var person: MeetingParticipantDraft {
        MeetingParticipantDraft(participantIdentifier: "contact:test-card", displayName: "Example Person")
    }
    private var draft: NewMeetingContactDraft {
        var input = NewMeetingContactDraft()
        input.givenName = "Example"
        return input
    }

    @Test @MainActor func retryAttachNeverCreatesAnotherCard() async {
        var saves = 0
        var attached: [MeetingParticipantDraft] = []
        let person = person
        let flow = MeetingContactCreationFlow(draft: draft, create: { _ in
            saves += 1
            return person
        }, attach: { participant in
            attached.append(participant)
            if attached.count == 1 { throw CocoaError(.fileWriteUnknown) }
        })
        await flow.saveAndAttach()
        #expect(flow.savedParticipant == person)
        #expect(flow.failureStage == .attachment)
        #expect(!flow.isComplete)
        await flow.saveAndAttach()
        #expect(saves == 1)
        #expect(attached == [person, person])
        #expect(flow.isComplete)
        #expect(flow.errorMessage == nil)
        await flow.saveAndAttach()
        #expect(attached.count == 2)
    }

    @Test @MainActor func saveFailurePreservesDraftAndNeverAttaches() async {
        var attaches = 0
        let input = draft
        let flow = MeetingContactCreationFlow(draft: input, create: { _ in
            throw MeetingContactCreatorError.accessDenied
        }, attach: { _ in attaches += 1 })
        await flow.saveAndAttach()
        #expect(flow.draft == input)
        #expect(flow.savedParticipant == nil)
        #expect(flow.failureStage == .contacts)
        #expect(flow.isAccessDenied)
        #expect(attaches == 0)
    }

    @Test @MainActor func missingSavedIdentifierCannotCreateADuplicate() async {
        var saves = 0
        var attaches = 0
        let flow = MeetingContactCreationFlow(draft: draft, create: { _ in
            saves += 1
            throw MeetingContactCreatorError.missingIdentifier
        }, attach: { _ in attaches += 1 })
        await flow.saveAndAttach()
        await flow.saveAndAttach()
        #expect(flow.hasSavedContact)
        #expect(flow.savedParticipant == nil)
        #expect(flow.failureStage == .contactSaved)
        #expect(saves == 1)
        #expect(attaches == 0)
    }

    @Test @MainActor func permissionRequestErrorKeepsDraftAndSettingsRecovery() async {
        let store = FakeMeetingContactWriter(accessRequest: {
            throw NSError(domain: CNErrorDomain, code: CNError.Code.authorizationDenied.rawValue)
        })
        store.configure { $0.status = .notDetermined }
        let creator = MeetingContactCreator(store: store)
        var attaches = 0
        let input = draft
        let flow = MeetingContactCreationFlow(draft: input, create: {
            try await creator.create($0)
        }, attach: { _ in attaches += 1 })
        await flow.saveAndAttach()
        #expect(flow.isAccessDenied)
        #expect(flow.draft == input)
        #expect(flow.savedParticipant == nil)
        #expect(store.snapshot.destinations.isEmpty)
        #expect(attaches == 0)
    }

    @Test @MainActor func concurrentSaveIsIgnored() async {
        var saves = 0
        var attaches = 0
        var pending: CheckedContinuation<MeetingParticipantDraft, Never>?
        let (started, signal) = AsyncStream<Void>.makeStream()
        let flow = MeetingContactCreationFlow(draft: draft, create: { _ in
            saves += 1
            return await withCheckedContinuation {
                pending = $0
                signal.yield(())
            }
        }, attach: { _ in attaches += 1 })
        let first = Task { await flow.saveAndAttach() }
        for await _ in started { break }
        #expect(pending != nil)
        #expect(flow.isWorking)
        await flow.saveAndAttach()
        pending?.resume(returning: person)
        await first.value
        #expect(saves == 1)
        #expect(attaches == 1)
        #expect(flow.isComplete)
        #expect(!flow.isWorking)
    }

    @Test @MainActor func retryUsesTheSavedIdentityEvenIfDraftChanges() async {
        let person = person
        var createdDrafts: [NewMeetingContactDraft] = []
        var attached: [MeetingParticipantDraft] = []
        let flow = MeetingContactCreationFlow(draft: draft, create: { input in
            createdDrafts.append(input)
            return person
        }, attach: { participant in
            attached.append(participant)
            if attached.count == 1 { throw CocoaError(.fileWriteUnknown) }
        })
        await flow.saveAndAttach()
        flow.draft.emailAddress = "different@example.test"
        await flow.saveAndAttach()
        #expect(createdDrafts.count == 1)
        #expect(attached == [person, person])
    }

    @Test @MainActor func cancellingAfterAttachFailureKeepsSavedCard() async {
        let person = person
        var saves = 0
        var attaches = 0
        let flow = MeetingContactCreationFlow(draft: draft, create: { _ in
            saves += 1
            return person
        }, attach: { _ in
            attaches += 1
            throw CocoaError(.fileWriteUnknown)
        })
        await flow.saveAndAttach()
        flow.cancel()
        await flow.saveAndAttach()
        #expect(flow.savedParticipant == person)
        #expect(saves == 1)
        #expect(attaches == 1)
    }

    @Test @MainActor func meetingPresentationRetriesSavedIdentityForOriginalMeeting() async {
        var saves = 0
        var meetingIDs: [Int64] = []
        var people: [MeetingParticipantDraft] = []
        let person = person
        let request = MeetingContactCreationRequest(meetingID: 42, create: { _ in
            saves += 1
            return person
        }, attach: { meetingID, participant in
            meetingIDs.append(meetingID)
            people.append(participant)
            if people.count == 1 { throw CocoaError(.fileWriteUnknown) }
        })
        request.flow.draft = draft
        await request.flow.saveAndAttach()
        let retainedPresentation = request
        await retainedPresentation.flow.saveAndAttach()
        #expect(saves == 1)
        #expect(meetingIDs == [42, 42])
        #expect(people == [person, person])
        #expect(retainedPresentation.flow.isComplete)
    }

    @Test @MainActor func appStateRetainsContactRequestAcrossDocumentNavigation() async {
        let appState = AppState()
        var saves = 0
        var meetingIDs: [Int64] = []
        var people: [MeetingParticipantDraft] = []
        let person = person
        let request = MeetingContactCreationRequest(meetingID: 42, create: { _ in
            saves += 1
            return person
        }, attach: { meetingID, participant in
            meetingIDs.append(meetingID)
            people.append(participant)
            if people.count == 1 { throw CocoaError(.fileWriteUnknown) }
        })
        request.flow.draft = draft
        appState.meetingContactCreationRequest = request
        appState.meetingsNavigationState = .document(42)
        appState.selectedMeetingID = 42

        await request.flow.saveAndAttach()

        appState.selectedTab = .timeline
        appState.meetingsNavigationState = .browser
        appState.selectedMeetingID = nil
        appState.selectedTab = .meetings
        appState.meetingsNavigationState = .document(99)
        appState.selectedMeetingID = 99
        #expect(appState.meetingContactCreationRequest?.flow === request.flow)
        await appState.meetingContactCreationRequest?.flow.saveAndAttach()

        #expect(saves == 1)
        #expect(meetingIDs == [42, 42])
        #expect(people == [person, person])
        #expect(appState.meetingContactCreationRequest?.flow.isComplete == true)
    }

    @Test @MainActor func cancelBeforeSaveDoesNotCreateOrAttach() async {
        var saves = 0
        var attaches = 0
        let person = person
        let flow = MeetingContactCreationFlow(draft: draft, create: { _ in
            saves += 1
            return person
        }, attach: { _ in attaches += 1 })
        flow.cancel()
        await flow.saveAndAttach()
        #expect(saves == 0)
        #expect(attaches == 0)
        #expect(flow.savedParticipant == nil)
    }
}
