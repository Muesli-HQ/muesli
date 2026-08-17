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
        let normalizedEmail = emailAddress?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return MeetingParticipantDraft(
            participantIdentifier: normalizedEmail.flatMap { $0.isEmpty ? nil : "email:\($0)" }
                ?? "contact:\(contact.identifier)",
            displayName: displayName(for: contact),
            emailAddress: normalizedEmail
        )
    }

    static func isEmailFallback(_ displayName: String) -> Bool {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedName.contains("@")
    }

    static func compactDisplayName(_ displayName: String, emailAddress: String?) -> String {
        guard isEmailFallback(displayName) else {
            return displayName
        }
        let email = emailAddress ?? displayName
        return email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? displayName
    }
}
