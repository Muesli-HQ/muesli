import Contacts
import Foundation
import MuesliCore

struct NewMeetingContactDraft: Equatable, Sendable {
    var givenName = ""
    var familyName = ""
    var emailAddress = ""

    var canSave: Bool {
        !normalizedGivenName.isEmpty || !normalizedFamilyName.isEmpty
    }

    var normalizedGivenName: String {
        givenName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedFamilyName: String {
        familyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedEmailAddress: String {
        emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MeetingContactCreatorError: LocalizedError, Equatable {
    case nameRequired
    case accessDenied
    case missingIdentifier

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            return "Add a first or last name before saving this contact."
        case .accessDenied:
            return "Muesli does not have permission to add contacts. Enable Contacts access in System Settings."
        case .missingIdentifier:
            return "Apple Contacts saved the person without returning an identifier. Try choosing them from Contacts instead."
        }
    }
}

enum MeetingContactCreator {
    static func create(_ draft: NewMeetingContactDraft) async throws -> MeetingParticipantDraft {
        guard draft.canSave else {
            throw MeetingContactCreatorError.nameRequired
        }

        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .denied, .restricted:
            throw MeetingContactCreatorError.accessDenied
        default:
            guard try await requestAccess(using: store) else {
                throw MeetingContactCreatorError.accessDenied
            }
        }

        return try await Task.detached(priority: .userInitiated) {
            let contact = CNMutableContact()
            contact.givenName = draft.normalizedGivenName
            contact.familyName = draft.normalizedFamilyName
            if !draft.normalizedEmailAddress.isEmpty {
                contact.emailAddresses = [
                    CNLabeledValue(label: CNLabelWork, value: draft.normalizedEmailAddress as NSString),
                ]
            }

            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            try CNContactStore().execute(request)

            guard !contact.identifier.isEmpty else {
                throw MeetingContactCreatorError.missingIdentifier
            }
            return MeetingContactIdentity.participant(for: contact)
        }.value
    }

    private static func requestAccess(using store: CNContactStore) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
