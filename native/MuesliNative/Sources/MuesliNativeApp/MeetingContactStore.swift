import Contacts
import Foundation

struct SavedMeetingContact: Equatable, Sendable {
    let identifier: String
    let displayName: String
}

enum MeetingContactStoreError: LocalizedError, Equatable {
    case missingEmailOrPhone
    case accessDenied
    case duplicateContact(displayName: String)

    var errorDescription: String? {
        switch self {
        case .missingEmailOrPhone:
            return "Add an email address or phone number before saving this contact."
        case .accessDenied:
            return "\(AppIdentity.displayName) does not have permission to add contacts. "
                + "Enable Contacts access in System Settings."
        case .duplicateContact(let displayName):
            return "\(displayName) is already in your Contacts. "
                + "Use \"Add person\" to attach them to this meeting."
        }
    }
}

/// Seam over the parts of `CNContactStore` this feature uses, so the save flow can
/// be exercised in tests without touching the machine's real address book.
protocol MeetingContactWriting {
    func requestContactsAccess() async throws -> Bool
    func fetchContacts(matching predicate: NSPredicate, keysToFetch keys: [CNKeyDescriptor]) throws -> [CNContact]
    func saveContact(_ request: CNSaveRequest) throws
}

extension CNContactStore: MeetingContactWriting {
    func requestContactsAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func fetchContacts(matching predicate: NSPredicate, keysToFetch keys: [CNKeyDescriptor]) throws -> [CNContact] {
        try unifiedContacts(matching: predicate, keysToFetch: keys)
    }

    func saveContact(_ request: CNSaveRequest) throws {
        try execute(request)
    }
}

struct MeetingContactStore {
    /// Every key `MeetingContactIdentity.displayName(for:)` can fall back to. Fetching
    /// only the name would silently degrade an email-or-phone-only contact — the exact
    /// shape this app's own contact form allows — to "Unnamed contact".
    private static let displayNameKeys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]

    private let store: any MeetingContactWriting
    private let authorizationStatus: () -> CNAuthorizationStatus

    init(
        store: any MeetingContactWriting = CNContactStore(),
        authorizationStatus: @escaping () -> CNAuthorizationStatus = {
            CNContactStore.authorizationStatus(for: .contacts)
        }
    ) {
        self.store = store
        self.authorizationStatus = authorizationStatus
    }

    func save(_ draft: NewMeetingContactDraft) async throws -> SavedMeetingContact {
        guard let contact = draft.makeContact() else {
            throw MeetingContactStoreError.missingEmailOrPhone
        }
        guard try await requestAccess() else {
            throw MeetingContactStoreError.accessDenied
        }

        if let existing = try await findExistingContact(for: draft) {
            throw MeetingContactStoreError.duplicateContact(
                displayName: MeetingContactIdentity.displayName(for: existing)
            )
        }

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)

        // CNContactStore is documented thread-safe, and `execute` is a synchronous
        // XPC round-trip to contactsd. Running it on the main actor freezes the UI
        // whenever contactsd is slow (large address book, first iCloud sync).
        try await performOffMainActor { store in
            try store.saveContact(request)
        }

        return SavedMeetingContact(
            identifier: contact.identifier,
            displayName: MeetingContactIdentity.displayName(for: contact)
        )
    }

    /// Derives a display name for a picker-vended contact.
    ///
    /// `CNContactPicker` is an out-of-process remote view service, so the contact it
    /// hands back only carries the keys that service fetched. When the name keys are
    /// missing, `MeetingContactIdentity` would silently degrade to "Unnamed contact",
    /// so re-fetch by identifier instead. Note `displayedKeys` cannot be used to force
    /// the key set: per CNContactPicker.h, providing keys switches the picker to
    /// selecting *values* rather than contacts.
    ///
    /// The re-fetch is deliberately skipped unless access is already granted — a
    /// permission prompt must never fire merely to render a name.
    func resolveDisplayName(for contact: CNContact) async -> String {
        let nameDescriptor = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        if contact.areKeysAvailable([nameDescriptor]) {
            return MeetingContactIdentity.displayName(for: contact)
        }
        guard authorizationStatus() == .authorized,
              !contact.identifier.isEmpty else {
            return MeetingContactIdentity.displayName(for: contact)
        }

        let identifier = contact.identifier
        let keys = Self.displayNameKeys
        let refetched = try? await performOffMainActor { store -> CNContact? in
            try store.fetchContacts(
                matching: CNContact.predicateForContacts(withIdentifiers: [identifier]),
                keysToFetch: keys
            ).first
        }
        guard let refetched else {
            return MeetingContactIdentity.displayName(for: contact)
        }
        return MeetingContactIdentity.displayName(for: refetched)
    }

    /// Avoids writing a second copy of somebody already in the user's address book.
    /// A failed lookup is not fatal — worst case the user gets the duplicate they
    /// would have got anyway, which beats blocking the save on a transient error.
    private func findExistingContact(for draft: NewMeetingContactDraft) async throws -> CNContact? {
        var predicates: [NSPredicate] = []
        if !draft.normalizedEmailAddress.isEmpty {
            predicates.append(CNContact.predicateForContacts(matchingEmailAddress: draft.normalizedEmailAddress))
        }
        if !draft.normalizedPhoneNumber.isEmpty {
            predicates.append(CNContact.predicateForContacts(
                matching: CNPhoneNumber(stringValue: draft.normalizedPhoneNumber)
            ))
        }
        guard !predicates.isEmpty else { return nil }

        let keys = Self.displayNameKeys
        return try? await performOffMainActor { store -> CNContact? in
            for predicate in predicates {
                if let match = try store.fetchContacts(matching: predicate, keysToFetch: keys).first {
                    return match
                }
            }
            return nil
        }
    }

    private func performOffMainActor<T>(
        _ work: @escaping (any MeetingContactWriting) throws -> T
    ) async throws -> T {
        let store = self.store
        return try await Task.detached(priority: .userInitiated) {
            try work(store)
        }.value
    }

    private func requestAccess() async throws -> Bool {
        if isAccessDenied {
            throw MeetingContactStoreError.accessDenied
        }

        do {
            return try await store.requestContactsAccess()
        } catch {
            if isAccessDenied {
                throw MeetingContactStoreError.accessDenied
            }
            throw error
        }
    }

    private var isAccessDenied: Bool {
        switch authorizationStatus() {
        case .denied, .restricted:
            return true
        default:
            return false
        }
    }
}
