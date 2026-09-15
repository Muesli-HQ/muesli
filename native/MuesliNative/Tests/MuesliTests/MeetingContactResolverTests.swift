import Contacts
import Foundation
import Testing
@testable import MuesliNativeApp

private final class FakeMeetingContactReader: MeetingContactReading, @unchecked Sendable {
    var accessResult = true
    var accessError: Error?
    var resolvedContact: CNContact?
    var lookupError: Error?

    private(set) var accessRequestCount = 0
    private(set) var lookupCount = 0
    private(set) var requestedIdentifier: String?
    private(set) var requestedKeys: [CNKeyDescriptor] = []

    func requestContactsAccess() async throws -> Bool {
        accessRequestCount += 1
        if let accessError {
            throw accessError
        }
        return accessResult
    }

    func unifiedContact(
        withIdentifier identifier: String,
        keysToFetch keys: [CNKeyDescriptor]
    ) throws -> CNContact {
        lookupCount += 1
        requestedIdentifier = identifier
        requestedKeys = keys
        if let lookupError {
            throw lookupError
        }
        guard let resolvedContact else {
            throw CocoaError(.fileNoSuchFile)
        }
        return resolvedContact
    }
}

private func phoneOnlyContact() -> CNMutableContact {
    let contact = CNMutableContact()
    contact.phoneNumbers = [
        CNLabeledValue(
            label: CNLabelPhoneNumberMobile,
            value: CNPhoneNumber(stringValue: "+1 949 870 7734")
        ),
    ]
    return contact
}

private func namedContact(emailAddress: String? = nil) -> CNMutableContact {
    let contact = CNMutableContact()
    contact.givenName = "Michael"
    contact.familyName = "Smith"
    if let emailAddress {
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: emailAddress as NSString),
        ]
    }
    return contact
}

@Suite("Meeting contact resolver")
struct MeetingContactResolverTests {
    @Test("authorized lookup replaces a phone-only picker contact with its named unified contact")
    func authorizedLookupUsesUnifiedContact() async {
        let pickerContact = phoneOnlyContact()
        let storedContact = namedContact()
        let reader = FakeMeetingContactReader()
        reader.resolvedContact = storedContact
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })

        let resolved = await resolver.resolve(pickerContact)

        #expect(MeetingContactIdentity.displayName(for: resolved) == "Michael Smith")
        #expect(reader.accessRequestCount == 0)
        #expect(reader.lookupCount == 1)
        #expect(reader.requestedIdentifier == pickerContact.identifier)
    }

    @Test("undetermined access requests permission before lookup")
    func requestsAccessBeforeLookup() async {
        let reader = FakeMeetingContactReader()
        reader.resolvedContact = namedContact()
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .notDetermined })

        let resolved = await resolver.resolve(phoneOnlyContact())

        #expect(MeetingContactIdentity.displayName(for: resolved) == "Michael Smith")
        #expect(reader.accessRequestCount == 1)
        #expect(reader.lookupCount == 1)
    }

    @Test(
        "denied or restricted access preserves the picker contact",
        arguments: [CNAuthorizationStatus.denied, .restricted]
    )
    func deniedAccessPreservesPickerContact(status: CNAuthorizationStatus) async {
        let pickerContact = phoneOnlyContact()
        let reader = FakeMeetingContactReader()
        reader.resolvedContact = namedContact()
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { status })

        let resolved = await resolver.resolve(pickerContact)

        #expect(MeetingContactIdentity.displayName(for: resolved) == "+1 949 870 7734")
        #expect(reader.accessRequestCount == 0)
        #expect(reader.lookupCount == 0)
    }

    @Test("a refused access request preserves the picker contact")
    func refusedAccessPreservesPickerContact() async {
        let pickerContact = phoneOnlyContact()
        let reader = FakeMeetingContactReader()
        reader.accessResult = false
        reader.resolvedContact = namedContact()
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .notDetermined })

        let resolved = await resolver.resolve(pickerContact)

        #expect(MeetingContactIdentity.displayName(for: resolved) == "+1 949 870 7734")
        #expect(reader.accessRequestCount == 1)
        #expect(reader.lookupCount == 0)
    }

    @Test("an access request error preserves the picker contact")
    func accessErrorPreservesPickerContact() async {
        let pickerContact = phoneOnlyContact()
        let reader = FakeMeetingContactReader()
        reader.accessError = CocoaError(.userCancelled)
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .notDetermined })

        let resolved = await resolver.resolve(pickerContact)

        #expect(MeetingContactIdentity.displayName(for: resolved) == "+1 949 870 7734")
        #expect(reader.accessRequestCount == 1)
        #expect(reader.lookupCount == 0)
    }

    @Test("a unified-contact lookup error preserves the picker contact")
    func lookupErrorPreservesPickerContact() async {
        let pickerContact = phoneOnlyContact()
        let reader = FakeMeetingContactReader()
        reader.lookupError = CocoaError(.fileReadUnknown)
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })

        let resolved = await resolver.resolve(pickerContact)

        #expect(MeetingContactIdentity.displayName(for: resolved) == "+1 949 870 7734")
        #expect(reader.lookupCount == 1)
    }

    @Test("lookup requests every contact identity fallback key")
    func requestsCompleteIdentityKeys() async {
        let reader = FakeMeetingContactReader()
        reader.resolvedContact = namedContact()
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })

        _ = await resolver.resolve(phoneOnlyContact())

        let stringKeys = reader.requestedKeys.compactMap { $0 as? String }
        #expect(stringKeys.contains(CNContactNicknameKey))
        #expect(stringKeys.contains(CNContactOrganizationNameKey))
        #expect(stringKeys.contains(CNContactEmailAddressesKey))
        #expect(stringKeys.contains(CNContactPhoneNumbersKey))
        let fullNameDescriptor = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        #expect(reader.requestedKeys.contains { ($0 as AnyObject).isEqual(fullNameDescriptor) })
    }

    @Test("an existing picker email remains the normalized participant identity")
    func existingEmailIdentityIsRetained() async {
        let pickerContact = namedContact(emailAddress: "MICHAEL@EXAMPLE.TEST")
        let reader = FakeMeetingContactReader()
        reader.resolvedContact = namedContact(emailAddress: "MICHAEL@EXAMPLE.TEST")
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })

        let resolved = await resolver.resolve(pickerContact)
        let participant = MeetingContactIdentity.participant(for: resolved)

        #expect(participant.participantIdentifier == "email:michael@example.test")
        #expect(participant.emailAddress == "michael@example.test")
        #expect(participant.displayName == "Michael Smith")
    }

    @Test("an email discovered during resolution enriches without changing participant identity")
    func discoveredEmailPreservesIdentity() async {
        let pickerContact = phoneOnlyContact()
        let reader = FakeMeetingContactReader()
        reader.resolvedContact = namedContact(emailAddress: "MICHAEL@EXAMPLE.TEST")
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })

        let resolved = await resolver.resolve(pickerContact)
        let selectedParticipant = MeetingContactIdentity.participant(for: pickerContact)
        let participant = MeetingContactIdentity.participant(
            for: resolved,
            preservingIdentifierFrom: pickerContact
        )

        #expect(selectedParticipant.participantIdentifier.hasPrefix("contact:"))
        #expect(participant.participantIdentifier == selectedParticipant.participantIdentifier)
        #expect(participant.displayName == "Michael Smith")
        #expect(participant.emailAddress == "michael@example.test")
    }
}
