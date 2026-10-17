import Combine
import Foundation
import MuesliCore

/// AppState retains this request across document navigation and recording
/// control changes. Attachment stays bound to the meeting where creation began.
@MainActor
struct MeetingContactCreationRequest: Identifiable {
    let id: Int64
    let flow: MeetingContactCreationFlow

    init(
        meetingID: Int64,
        create: @escaping @MainActor (NewMeetingContactDraft) async throws -> MeetingParticipantDraft = {
            try await MeetingContactCreator.create($0)
        },
        attach: @escaping @MainActor (Int64, MeetingParticipantDraft) async throws -> Void
    ) {
        id = meetingID
        flow = MeetingContactCreationFlow(create: create, attach: { participant in
            try await attach(meetingID, participant)
        })
    }
}

/// Saving the Contacts card and attaching its snapshot are separate operations.
/// A roster failure must never turn a retry into another Contacts write.
@MainActor
final class MeetingContactCreationFlow: ObservableObject {
    enum FailureStage { case contacts, contactSaved, attachment }

    @Published var draft: NewMeetingContactDraft
    @Published private(set) var savedParticipant: MeetingParticipantDraft?
    @Published private(set) var hasSavedContact = false
    @Published private(set) var isWorking = false
    @Published private(set) var isComplete = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var failureStage: FailureStage?
    @Published private(set) var isAccessDenied = false

    private var isCancelled = false
    private let create: @MainActor (NewMeetingContactDraft) async throws -> MeetingParticipantDraft
    private let attach: @MainActor (MeetingParticipantDraft) async throws -> Void

    init(
        draft: NewMeetingContactDraft = NewMeetingContactDraft(),
        create: @escaping @MainActor (NewMeetingContactDraft) async throws -> MeetingParticipantDraft = {
            try await MeetingContactCreator.create($0)
        },
        attach: @escaping @MainActor (MeetingParticipantDraft) async throws -> Void
    ) {
        self.draft = draft
        self.create = create
        self.attach = attach
    }

    func saveAndAttach() async {
        guard !isWorking, !isComplete, !isCancelled, !Task.isCancelled else { return }
        guard savedParticipant != nil || (!hasSavedContact && draft.canSave) else { return }
        isWorking = true
        errorMessage = nil
        failureStage = nil
        isAccessDenied = false
        defer { isWorking = false }

        do {
            let participant: MeetingParticipantDraft
            if let savedParticipant {
                participant = savedParticipant
            } else {
                let input = draft
                participant = try await create(input)
                savedParticipant = participant
                hasSavedContact = true
            }
            try await attach(participant)
            isComplete = true
        } catch {
            let contactsError = error as? MeetingContactCreatorError
            if contactsError == .missingIdentifier {
                hasSavedContact = true
                failureStage = .contactSaved
            } else {
                failureStage = savedParticipant == nil ? .contacts : .attachment
            }
            isAccessDenied = contactsError == .accessDenied || contactsError == .accessUnavailable
            errorMessage = error.localizedDescription
        }
    }

    func clearError() { errorMessage = nil }

    func cancel() {
        // Cancel/Close is disabled once the write starts. There is no rollback
        // of a user's Contacts card after a successful save.
        guard !isWorking else { return }
        isCancelled = true
    }
}
