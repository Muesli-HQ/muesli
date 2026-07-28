import Contacts
import Testing
@testable import MuesliNativeApp

@Suite("Meeting contact identity")
struct MeetingContactIdentityTests {
    @Test("uses a conventional full name")
    func fullName() {
        let contact = CNMutableContact()
        contact.givenName = "Alice"
        contact.familyName = "Example"

        #expect(MeetingContactIdentity.displayName(for: contact) == "Alice Example")
    }

    @Test("falls back to nickname")
    func nickname() {
        let contact = CNMutableContact()
        contact.nickname = "Ace"

        #expect(MeetingContactIdentity.displayName(for: contact) == "Ace")
    }

    @Test("falls back to organization")
    func organization() {
        let contact = CNMutableContact()
        contact.organizationName = "Example Industries Ltd."

        #expect(MeetingContactIdentity.displayName(for: contact) == "Example Industries Ltd.")
    }

    @Test("falls back to email")
    func email() {
        let contact = CNMutableContact()
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "alice@example.test" as NSString),
        ]

        #expect(MeetingContactIdentity.displayName(for: contact) == "alice@example.test")
    }

    @Test("falls back to phone")
    func phone() {
        let contact = CNMutableContact()
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 555 0100")),
        ]

        #expect(MeetingContactIdentity.displayName(for: contact) == "+1 555 0100")
    }

    @Test("falls back to an unnamed label")
    func unnamed() {
        #expect(MeetingContactIdentity.displayName(for: CNMutableContact()) == "Unnamed contact")
    }

    @Test("prefers the strongest available identity")
    func precedenceChain() {
        let contact = CNMutableContact()
        contact.givenName = "Alice"
        contact.familyName = "Example"
        contact.nickname = "Ace"
        contact.organizationName = "Example Industries Ltd."
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "alice@example.test" as NSString),
        ]
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 555 0100")),
        ]

        // Peel the candidates off one at a time; each step pins the next rung down.
        #expect(MeetingContactIdentity.displayName(for: contact) == "Alice Example")
        contact.givenName = ""
        contact.familyName = ""
        #expect(MeetingContactIdentity.displayName(for: contact) == "Ace")
        contact.nickname = ""
        #expect(MeetingContactIdentity.displayName(for: contact) == "Example Industries Ltd.")
        contact.organizationName = ""
        #expect(MeetingContactIdentity.displayName(for: contact) == "alice@example.test")
        contact.emailAddresses = []
        #expect(MeetingContactIdentity.displayName(for: contact) == "+1 555 0100")
    }

    @Test("treats whitespace-only values as absent")
    func whitespaceOnlyNameFallsThrough() {
        let contact = CNMutableContact()
        contact.givenName = "   "
        contact.familyName = "\n"
        contact.nickname = "Fallback"

        #expect(MeetingContactIdentity.displayName(for: contact) == "Fallback")
    }

    @Test("handles a single-name contact")
    func singleName() {
        let contact = CNMutableContact()
        contact.givenName = "Nova"

        #expect(MeetingContactIdentity.displayName(for: contact) == "Nova")
    }

    @Test("draft normalizes values before building a contact")
    func makeContactNormalizes() {
        #expect(NewMeetingContactDraft(
            givenName: "A",
            familyName: "B",
            emailAddress: " ",
            phoneNumber: " "
        ).makeContact() == nil)

        let contact = NewMeetingContactDraft(
            givenName: "  Dana ",
            familyName: " Sample ",
            emailAddress: " dana@example.test ",
            phoneNumber: ""
        ).makeContact()

        #expect(contact?.givenName == "Dana")
        #expect(contact?.familyName == "Sample")
        #expect(contact?.emailAddresses.first?.value as String? == "dana@example.test")
        #expect(contact?.emailAddresses.first?.label == CNLabelWork)
        // A blank phone must not produce an empty labeled value.
        #expect(contact?.phoneNumbers.isEmpty == true)
    }

    @Test("new contacts require a normalized email or phone")
    func newContactValidation() {
        #expect(!NewMeetingContactDraft(
            givenName: "Name",
            familyName: "Only",
            emailAddress: "  ",
            phoneNumber: "\n"
        ).canSave)
        #expect(NewMeetingContactDraft(
            givenName: "Email",
            familyName: "Contact",
            emailAddress: " person@example.test ",
            phoneNumber: ""
        ).canSave)
        #expect(NewMeetingContactDraft(
            givenName: "Phone",
            familyName: "Contact",
            emailAddress: "",
            phoneNumber: " +1 555 0101 "
        ).canSave)
    }
}
