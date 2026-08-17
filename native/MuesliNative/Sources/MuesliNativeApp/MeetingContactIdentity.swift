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

    static func isEmailFallback(_ displayName: String, emailAddress: String?) -> Bool {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedEmail = emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedName.contains("@") && (normalizedEmail == nil || normalizedName == normalizedEmail)
    }

    static func compactDisplayName(_ displayName: String, emailAddress: String?) -> String {
        guard isEmailFallback(displayName, emailAddress: emailAddress) else {
            return displayName
        }
        let email = emailAddress ?? displayName
        return email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? displayName
    }
}
