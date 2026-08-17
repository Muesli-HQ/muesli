import Contacts
import MuesliCore

enum MeetingContactNameResolver {
    static func enrich(_ participants: [MeetingParticipant]) async -> [MeetingParticipant] {
        let unresolvedEmails = participants.compactMap { participant -> String? in
            guard MeetingContactIdentity.isEmailFallback(
                participant.displayName,
                emailAddress: participant.emailAddress
            ) else { return nil }
            return participant.emailAddress
        }
        guard !unresolvedEmails.isEmpty,
              canPassivelyReadContacts(
                  authorizationStatus: CNContactStore.authorizationStatus(for: .contacts)
              ) else {
            return participants
        }

        let resolvedNames = await Task.detached(priority: .userInitiated) {
            namesByEmail(for: unresolvedEmails)
        }.value
        guard !resolvedNames.isEmpty else { return participants }

        return participants.map { participant in
            guard let email = participant.emailAddress?.lowercased(),
                  let name = resolvedNames[email] else {
                return participant
            }
            return MeetingParticipant(
                meetingID: participant.meetingID,
                participantIdentifier: participant.participantIdentifier,
                displayName: name,
                emailAddress: participant.emailAddress,
                insertionOrder: participant.insertionOrder
            )
        }
    }

    static func canPassivelyReadContacts(authorizationStatus: CNAuthorizationStatus) -> Bool {
        authorizationStatus == .authorized
    }

    private static func namesByEmail(for emails: [String]) -> [String: String] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        var names: [String: String] = [:]

        for email in Set(emails.map { $0.lowercased() }) {
            let predicate = CNContact.predicateForContacts(matchingEmailAddress: email)
            guard let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first else {
                continue
            }
            let name = MeetingContactIdentity.displayName(for: contact)
            guard !MeetingContactIdentity.isEmailFallback(name, emailAddress: email) else {
                continue
            }
            names[email] = name
        }
        return names
    }
}
