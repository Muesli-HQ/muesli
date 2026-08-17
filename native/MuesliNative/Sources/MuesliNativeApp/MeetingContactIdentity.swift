import Contacts
import Foundation
import MuesliCore

enum MeetingContactIdentity {
    static let unnamedFallback = "Unnamed contact"

    static func displayName(for contact: CNContact) -> String {
        let nameDescriptor = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        let fullName = contact.areKeysAvailable([nameDescriptor])
            ? CNContactFormatter.string(from: contact, style: .fullName)
            : nil
        let nickname = contact.isKeyAvailable(CNContactNicknameKey) ? contact.nickname : nil
        let organization = contact.isKeyAvailable(CNContactOrganizationNameKey) ? contact.organizationName : nil
        let email = contact.isKeyAvailable(CNContactEmailAddressesKey)
            ? contact.emailAddresses.first?.value as String?
            : nil
        let phone = contact.isKeyAvailable(CNContactPhoneNumbersKey)
            ? contact.phoneNumbers.first?.value.stringValue
            : nil
        let candidates = [fullName, nickname, organization, email, phone]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return unnamedFallback
    }

    static func participant(for contact: CNContact) -> MeetingParticipantDraft {
        let emailAddress = contact.isKeyAvailable(CNContactEmailAddressesKey)
            ? contact.emailAddresses.first?.value as String?
            : nil
        return MeetingParticipantDraft(
            participantIdentifier: "contact:\(contact.identifier)",
            displayName: displayName(for: contact),
            emailAddress: emailAddress
        )
    }
}
