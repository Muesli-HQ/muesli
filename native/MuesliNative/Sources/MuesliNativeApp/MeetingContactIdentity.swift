import Contacts
import Foundation

enum MeetingContactIdentity {
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
        return "Unnamed contact"
    }
}

struct NewMeetingContactDraft: Equatable {
    var givenName = ""
    var familyName = ""
    var emailAddress = ""
    var phoneNumber = ""

    var normalizedGivenName: String {
        givenName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedFamilyName: String {
        familyName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedEmailAddress: String {
        emailAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedPhoneNumber: String {
        phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSave: Bool {
        !normalizedEmailAddress.isEmpty || !normalizedPhoneNumber.isEmpty
    }

    func makeContact() -> CNMutableContact? {
        guard canSave else { return nil }

        let contact = CNMutableContact()
        contact.givenName = normalizedGivenName
        contact.familyName = normalizedFamilyName
        if !normalizedEmailAddress.isEmpty {
            contact.emailAddresses = [
                CNLabeledValue(label: CNLabelWork, value: normalizedEmailAddress as NSString),
            ]
        }
        if !normalizedPhoneNumber.isEmpty {
            contact.phoneNumbers = [
                CNLabeledValue(
                    label: CNLabelPhoneNumberMobile,
                    value: CNPhoneNumber(stringValue: normalizedPhoneNumber)
                ),
            ]
        }
        return contact
    }
}
