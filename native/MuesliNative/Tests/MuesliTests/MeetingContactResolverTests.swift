import Contacts
import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

private final class FakeMeetingContactReader: MeetingContactReading, @unchecked Sendable {
    var accessResult = true
    var accessError: Error?
    var resolvedContact: CNContact?
    var lookupError: Error?
    var candidates: [CNContact] = []
    var me: CNContact?
    var meError: Error?
    var callLookupError: Error?
    private(set) var callLookupCount = 0

    private(set) var accessRequestCount = 0
    private(set) var lookupCount = 0
    private(set) var requestedIdentifier: String?
    private(set) var requestedKeys: [CNKeyDescriptor] = []

    func unifiedContacts(matching predicate: NSPredicate, keysToFetch keys: [CNKeyDescriptor]) throws -> [CNContact] {
        callLookupCount += 1
        if let callLookupError { throw callLookupError }
        return candidates
    }
    func meContact(keysToFetch keys: [CNKeyDescriptor]) throws -> CNContact? {
        if let meError { throw meError }
        return me
    }

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
            value: CNPhoneNumber(stringValue: "+1 202 555 0123")
        ),
    ]
    return contact
}

private func namedContact(emailAddress: String? = nil) -> CNMutableContact {
    let contact = CNMutableContact()
    contact.givenName = "Alex"
    contact.familyName = "Example"
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

        #expect(MeetingContactIdentity.displayName(for: resolved) == "Alex Example")
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

        #expect(MeetingContactIdentity.displayName(for: resolved) == "Alex Example")
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

        #expect(MeetingContactIdentity.displayName(for: resolved) == "+1 202 555 0123")
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

        #expect(MeetingContactIdentity.displayName(for: resolved) == "+1 202 555 0123")
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

        #expect(MeetingContactIdentity.displayName(for: resolved) == "+1 202 555 0123")
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

        #expect(MeetingContactIdentity.displayName(for: resolved) == "+1 202 555 0123")
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
        let pickerContact = namedContact(emailAddress: "ALEX@EXAMPLE.TEST")
        let reader = FakeMeetingContactReader()
        reader.resolvedContact = namedContact(emailAddress: "ALEX@EXAMPLE.TEST")
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })

        let resolved = await resolver.resolve(pickerContact)
        let participant = MeetingContactIdentity.participant(for: resolved)

        #expect(participant.participantIdentifier == "email:alex@example.test")
        #expect(participant.emailAddress == "alex@example.test")
        #expect(participant.displayName == "Alex Example")
    }

    @Test("an email discovered during resolution enriches without changing participant identity")
    func discoveredEmailPreservesIdentity() async {
        let pickerContact = phoneOnlyContact()
        let reader = FakeMeetingContactReader()
        reader.resolvedContact = namedContact(emailAddress: "ALEX@EXAMPLE.TEST")
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })

        let resolved = await resolver.resolve(pickerContact)
        let selectedParticipant = MeetingContactIdentity.participant(for: pickerContact)
        let participant = MeetingContactIdentity.participant(
            for: resolved,
            preservingIdentifierFrom: pickerContact
        )

        #expect(selectedParticipant.participantIdentifier.hasPrefix("contact:"))
        #expect(participant.participantIdentifier == selectedParticipant.participantIdentifier)
        #expect(participant.displayName == "Alex Example")
        #expect(participant.emailAddress == "alex@example.test")
    }

    @Test("an unnamed unified contact does not replace the picker display name")
    func unnamedResolvedContactPreservesPickerName() {
        let pickerContact = namedContact(emailAddress: "ALEX@EXAMPLE.TEST")
        let resolvedContact = CNMutableContact()

        let participant = MeetingContactIdentity.participant(
            for: resolvedContact,
            preservingIdentifierFrom: pickerContact
        )

        #expect(participant.participantIdentifier == "email:alex@example.test")
        #expect(participant.displayName == "Alex Example")
        #expect(participant.emailAddress == "alex@example.test")
    }

    @Test("A unique caller contact uses the same participant identity as manual tagging")
    func callContactUsesManualIdentity() async {
        let reader = FakeMeetingContactReader()
        reader.candidates = [namedContact(emailAddress: "alex@example.test")]
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })
        let handle = CallerHandle(kind: .email, key: "email:alex@example.test", displayValue: "alex@example.test")
        #expect(await resolver.resolveCaller(.identified(handle)) == .contact(MeetingParticipantDraft(participantIdentifier: "email:alex@example.test", displayName: "Alex Example", emailAddress: "alex@example.test")))
    }

    @Test("Name lookup requires one exact folded display name")
    func callNamesRequireExactUniqueMatch() async {
        let reader = FakeMeetingContactReader()
        let contact = namedContact()
        reader.candidates = [contact, contact]
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })
        #expect(await resolver.resolveCaller(.nameOnly("Álex example")) == .contact(MeetingContactIdentity.participant(for: contact)))
        #expect(await resolver.resolveCaller(.nameOnly("Alex")) == .unavailable)
        reader.candidates = [contact, namedContact()]
        #expect(await resolver.resolveCaller(.nameOnly("Alex Example")) == .unavailable)
    }

    @Test("No Contacts permission never prompts; only raw handles retain fallback", arguments: [CNAuthorizationStatus.notDetermined, .denied, .restricted])
    func callLookupNeverRequestsAccess(_ status: CNAuthorizationStatus) async {
        let reader = FakeMeetingContactReader()
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { status })
        let handle = CallerHandle(kind: .email, key: "email:alex@example.test", displayValue: "alex@example.test")
        #expect(await resolver.resolveCaller(.identified(handle)) == .handle(handle))
        #expect(await resolver.resolveCaller(.nameOnly("Alex Example")) == .unavailable)
        #expect(reader.accessRequestCount == 0)
        #expect(reader.callLookupCount == 0)
    }

    @Test("No match falls back to a handle; ambiguous, failed and self matches do not")
    func callFallbackAndSelfExclusion() async {
        let reader = FakeMeetingContactReader()
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })
        let handle = CallerHandle(kind: .email, key: "email:alex@example.test", displayValue: "alex@example.test")
        #expect(await resolver.resolveCaller(.identified(handle)) == .handle(handle))
        reader.candidates = [namedContact(emailAddress: "other@example.test")]
        #expect(await resolver.resolveCaller(.identified(handle)) == .handle(handle))
        reader.candidates = [
            namedContact(emailAddress: "alex@example.test"),
            namedContact(emailAddress: "alex@example.test"),
        ]
        #expect(await resolver.resolveCaller(.identified(handle)) == .unavailable)
        reader.callLookupError = CocoaError(.fileReadUnknown)
        #expect(await resolver.resolveCaller(.identified(handle)) == .unavailable)
        reader.callLookupError = nil
        let me = namedContact(emailAddress: "alex@example.test")
        reader.me = me
        reader.candidates = [me]
        #expect(await resolver.resolveCaller(.identified(handle)) == .unavailable)
        #expect(await resolver.resolveCaller(.nameOnly("Alex Example")) == .unavailable)
    }

    @Test("Failed self-card reads and known self handles cannot fall back to raw callers")
    func failedMeReadAndUnmatchedSelfHandleSkip() async {
        let reader = FakeMeetingContactReader()
        let resolver = MeetingContactResolver(store: reader, authorizationStatus: { .authorized })
        let handle = CallerHandle(kind: .email, key: "email:alex@example.test", displayValue: "alex@example.test")
        reader.meError = CocoaError(.fileReadUnknown)
        #expect(await resolver.resolveCaller(.identified(handle)) == .unavailable)
        reader.meError = nil
        reader.me = namedContact(emailAddress: "alex@example.test")
        #expect(await resolver.resolveCaller(.identified(handle)) == .unavailable)
    }

}
