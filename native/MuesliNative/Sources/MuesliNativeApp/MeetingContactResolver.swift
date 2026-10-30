import Contacts
import Foundation

protocol MeetingContactReading: Sendable {
    func requestContactsAccess() async throws -> Bool
    func unifiedContact(
        withIdentifier identifier: String,
        keysToFetch keys: [CNKeyDescriptor]
    ) throws -> CNContact
}

extension CNContactStore: @unchecked Sendable, MeetingContactReading {
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
}

struct MeetingContactResolver {
    private static let identityKeys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
    ]

    private let store: any MeetingContactReading
    private let authorizationStatus: @Sendable () -> CNAuthorizationStatus

    init(
        store: any MeetingContactReading = CNContactStore(),
        authorizationStatus: @escaping @Sendable () -> CNAuthorizationStatus = {
            CNContactStore.authorizationStatus(for: .contacts)
        }
    ) {
        self.store = store
        self.authorizationStatus = authorizationStatus
    }

    func resolve(_ contact: CNContact) async -> CNContact {
        guard !contact.identifier.isEmpty else {
            return contact
        }

        switch authorizationStatus() {
        case .notDetermined:
            do {
                guard try await store.requestContactsAccess() else {
                    return contact
                }
            } catch {
                return contact
            }
        case .denied, .restricted:
            return contact
        default:
            break
        }

        let store = store
        let identifier = contact.identifier
        let keys = Self.identityKeys
        return await Task.detached(priority: .userInitiated) {
            (try? store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)) ?? contact
        }.value
    }
}
