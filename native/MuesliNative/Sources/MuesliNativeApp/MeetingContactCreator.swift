import Contacts
import Foundation
import MuesliCore

struct NewMeetingContactDraft: Equatable, Sendable {
    var givenName = ""
    var familyName = ""
    var companyName = ""
    var phoneNumber = ""
    var emailAddress = ""

    var canSave: Bool {
        !normalizedGivenName.isEmpty || !normalizedFamilyName.isEmpty
    }

    var normalizedGivenName: String { givenName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedFamilyName: String { familyName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedCompanyName: String { companyName.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedPhoneNumber: String { phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedEmailAddress: String { emailAddress.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum MeetingContactCreatorError: LocalizedError, Equatable {
    case nameRequired
    case accessDenied
    case accessUnavailable
    case destinationUnavailable
    case missingIdentifier

    var errorDescription: String? {
        switch self {
        case .nameRequired:
            return "Add a first or last name before saving this contact."
        case .accessDenied:
            return "Muesli does not have permission to add contacts. Enable Contacts access in System Settings."
        case .accessUnavailable:
            return "Contacts access is unavailable. Check Contacts access in System Settings."
        case .destinationUnavailable:
            return "Your default Contacts account is unavailable. Check the default account in Contacts settings and try again."
        case .missingIdentifier:
            return "Apple Contacts saved the person without returning an identifier. Try choosing them from Contacts instead."
        }
    }
}

/// Contacts objects stay inside the creator's serial queue. Only the participant
/// snapshot crosses back to the UI; the adapter never chooses a fallback account.
protocol MeetingContactWriting: Sendable {
    func contactsAuthorizationStatus() -> CNAuthorizationStatus
    func requestContactsAccess() async throws -> Bool
    func defaultContainerIdentifier() -> String
    func save(_ contact: CNMutableContact, toContainerWithIdentifier identifier: String) throws
}

extension CNContactStore: MeetingContactWriting {
    func contactsAuthorizationStatus() -> CNAuthorizationStatus {
        Self.authorizationStatus(for: .contacts)
    }

    func save(_ contact: CNMutableContact, toContainerWithIdentifier identifier: String) throws {
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: identifier)
        try execute(request)
    }
}

private final class MeetingContactSaveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    func cancel() { lock.withLock { isCancelled = true } }
    func check() throws {
        if lock.withLock({ isCancelled }) { throw CancellationError() }
    }
}

struct MeetingContactCreator: Sendable {
    private let store: any MeetingContactWriting
    private let queue = DispatchQueue(label: "com.muesli.meeting-contact-save", qos: .userInitiated)

    init(store: any MeetingContactWriting = CNContactStore()) {
        self.store = store
    }

    static func create(_ draft: NewMeetingContactDraft) async throws -> MeetingParticipantDraft {
        try await Self().create(draft)
    }

    func create(_ draft: NewMeetingContactDraft) async throws -> MeetingParticipantDraft {
        guard draft.canSave else { throw MeetingContactCreatorError.nameRequired }
        try Task.checkCancellation()
        let store = store
        let status = try await onQueue { store.contactsAuthorizationStatus() }
        try Task.checkCancellation()
        switch status {
        case .authorized:
            break
        case .notDetermined:
            let granted: Bool
            do {
                granted = try await store.requestContactsAccess()
            } catch {
                throw Self.normalizedAccessError(error)
            }
            try Task.checkCancellation()
            guard granted else { throw MeetingContactCreatorError.accessDenied }
        case .denied, .restricted:
            throw MeetingContactCreatorError.accessDenied
        @unknown default:
            // Limited authorization is not a macOS API. Fail closed for future
            // states rather than referencing an unavailable enum case.
            throw MeetingContactCreatorError.accessUnavailable
        }

        let cancellation = MeetingContactSaveCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await onQueue {
                try cancellation.check()
                let contact = CNMutableContact()
                contact.givenName = draft.normalizedGivenName
                contact.familyName = draft.normalizedFamilyName
                contact.organizationName = draft.normalizedCompanyName
                if !draft.normalizedPhoneNumber.isEmpty {
                    contact.phoneNumbers = [
                        CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                       value: CNPhoneNumber(stringValue: draft.normalizedPhoneNumber)),
                    ]
                }
                if !draft.normalizedEmailAddress.isEmpty {
                    contact.emailAddresses = [
                        CNLabeledValue(label: CNLabelWork, value: draft.normalizedEmailAddress as NSString),
                    ]
                }

                // Resolve the user's live default immediately before the write.
                let identifier = store.defaultContainerIdentifier()
                guard !identifier.isEmpty else { throw MeetingContactCreatorError.destinationUnavailable }
                try cancellation.check()
                do {
                    try store.save(contact, toContainerWithIdentifier: identifier)
                } catch {
                    throw Self.normalizedAccessError(error)
                }
                // Once Contacts saved, always return its identity, even if the
                // calling task was cancelled during the synchronous write.
                guard !contact.identifier.isEmpty else { throw MeetingContactCreatorError.missingIdentifier }
                return MeetingContactIdentity.participant(for: contact)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func normalizedAccessError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == CNErrorDomain, nsError.code == CNError.Code.authorizationDenied.rawValue {
            return MeetingContactCreatorError.accessDenied
        }
        return error
    }

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
