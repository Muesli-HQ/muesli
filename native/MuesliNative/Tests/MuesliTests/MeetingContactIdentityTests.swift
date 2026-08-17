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
        #expect(MeetingContactIdentity.displayName(for: CNMutableContact()) == MeetingContactIdentity.unnamedFallback)
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

    @Test("manual participant uses normalized email identity when available")
    func participantSnapshot() {
        let contact = CNMutableContact()
        contact.givenName = "Dana"
        contact.familyName = "Sample"
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "dana@example.test" as NSString),
        ]

        let participant = MeetingContactIdentity.participant(for: contact)

        #expect(participant.participantIdentifier == "email:dana@example.test")
        #expect(participant.displayName == "Dana Sample")
        #expect(participant.emailAddress == "dana@example.test")
    }

    @Test("new contact input requires a name and trims saved fields")
    func newContactDraftValidation() {
        var draft = NewMeetingContactDraft()
        #expect(!draft.canSave)

        draft.givenName = "  Dana "
        draft.familyName = " Sample\n"
        draft.emailAddress = " dana@example.test "

        #expect(draft.canSave)
        #expect(draft.normalizedGivenName == "Dana")
        #expect(draft.normalizedFamilyName == "Sample")
        #expect(draft.normalizedEmailAddress == "dana@example.test")
    }

    @Test("email-only attendees use a compact local-part fallback")
    func compactEmailFallback() {
        #expect(
            MeetingContactIdentity.compactDisplayName(
                "dana@example.test",
                emailAddress: "dana@example.test"
            ) == "dana"
        )
        #expect(
            MeetingContactIdentity.compactDisplayName(
                "Dana Sample",
                emailAddress: "dana@example.test"
            ) == "Dana Sample"
        )
        #expect(
            MeetingContactIdentity.isEmailFallback("personal@example.test")
        )
    }

}
