import Contacts
import Testing
@testable import MuesliNativeApp

/// Stand-in for `CNContactStore` so the save flow can be exercised without touching
/// the machine's real address book or its TCC state.
private final class FakeContactWriter: MeetingContactWriting, @unchecked Sendable {
    var accessGranted = true
    var accessError: Error?
    var matches: [CNContact] = []
    var fetchError: Error?
    var saveError: Error?
    private(set) var savedRequestCount = 0
    private(set) var lastRequestedKeys: [CNKeyDescriptor] = []

    func requestContactsAccess() async throws -> Bool {
        if let accessError {
            throw accessError
        }
        return accessGranted
    }

    func fetchContacts(matching predicate: NSPredicate, keysToFetch keys: [CNKeyDescriptor]) throws -> [CNContact] {
        lastRequestedKeys = keys
        if let fetchError {
            throw fetchError
        }
        return matches
    }

    func saveContact(_ request: CNSaveRequest) throws {
        if let saveError {
            throw saveError
        }
        savedRequestCount += 1
    }
}

private func makeDraft(
    givenName: String = "Dana",
    familyName: String = "Sample",
    emailAddress: String = "dana@example.test",
    phoneNumber: String = ""
) -> NewMeetingContactDraft {
    NewMeetingContactDraft(
        givenName: givenName,
        familyName: familyName,
        emailAddress: emailAddress,
        phoneNumber: phoneNumber
    )
}

@Suite("Meeting contact store")
struct MeetingContactStoreTests {
    @Test("saves a contact and reports its derived name")
    func savesContact() async throws {
        let writer = FakeContactWriter()
        let store = MeetingContactStore(store: writer, authorizationStatus: { .authorized })

        let saved = try await store.save(makeDraft())

        #expect(saved.displayName == "Dana Sample")
        #expect(!saved.identifier.isEmpty)
        #expect(writer.savedRequestCount == 1)
    }

    @Test("rejects a draft with neither email nor phone")
    func rejectsIncompleteDraft() async {
        let writer = FakeContactWriter()
        let store = MeetingContactStore(store: writer, authorizationStatus: { .authorized })

        await #expect(throws: MeetingContactStoreError.missingEmailOrPhone) {
            try await store.save(makeDraft(emailAddress: "  ", phoneNumber: " "))
        }
        #expect(writer.savedRequestCount == 0)
    }

    @Test("surfaces denied access without attempting a write")
    func deniedAuthorizationIsReported() async {
        let writer = FakeContactWriter()
        let store = MeetingContactStore(store: writer, authorizationStatus: { .denied })

        await #expect(throws: MeetingContactStoreError.accessDenied) {
            try await store.save(makeDraft())
        }
        #expect(writer.savedRequestCount == 0)
    }

    @Test("treats a refused prompt as denied access")
    func refusedPromptIsReported() async {
        let writer = FakeContactWriter()
        writer.accessGranted = false
        let store = MeetingContactStore(store: writer, authorizationStatus: { .notDetermined })

        await #expect(throws: MeetingContactStoreError.accessDenied) {
            try await store.save(makeDraft())
        }
        #expect(writer.savedRequestCount == 0)
    }

    @Test("refuses to duplicate somebody already in Contacts")
    func duplicateContactIsRejected() async {
        let existing = CNMutableContact()
        existing.givenName = "Dana"
        existing.familyName = "Sample"

        let writer = FakeContactWriter()
        writer.matches = [existing]
        let store = MeetingContactStore(store: writer, authorizationStatus: { .authorized })

        await #expect(throws: MeetingContactStoreError.duplicateContact(displayName: "Dana Sample")) {
            try await store.save(makeDraft())
        }
        #expect(writer.savedRequestCount == 0)
    }

    @Test("names a nameless duplicate by its email instead of \"Unnamed contact\"")
    func duplicateWithoutNameIsIdentifiable() async {
        // Email-or-phone-only contacts are exactly what this app's own form creates, so
        // the lookup must fetch every key `displayName(for:)` falls back to. Fetching
        // only the name would leave the user with "Unnamed contact is already in your
        // Contacts" and no way to tell who that is.
        let existing = CNMutableContact()
        existing.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: "dana@example.test")]

        let writer = FakeContactWriter()
        writer.matches = [existing]
        let store = MeetingContactStore(store: writer, authorizationStatus: { .authorized })

        await #expect(throws: MeetingContactStoreError.duplicateContact(displayName: "dana@example.test")) {
            try await store.save(makeDraft(givenName: "", familyName: ""))
        }

        let requestedKeys = writer.lastRequestedKeys.compactMap { $0 as? String }
        #expect(requestedKeys.contains(CNContactNicknameKey))
        #expect(requestedKeys.contains(CNContactOrganizationNameKey))
        #expect(requestedKeys.contains(CNContactEmailAddressesKey))
        #expect(requestedKeys.contains(CNContactPhoneNumbersKey))
    }

    @Test("a failed duplicate lookup does not block the save")
    func duplicateLookupFailureIsNotFatal() async throws {
        let writer = FakeContactWriter()
        writer.fetchError = CocoaError(.fileReadUnknown)
        let store = MeetingContactStore(store: writer, authorizationStatus: { .authorized })

        _ = try await store.save(makeDraft())

        #expect(writer.savedRequestCount == 1)
    }

    @Test("uses the contact as-is when its name keys are already available")
    func resolveDisplayNameUsesAvailableKeys() async {
        let contact = CNMutableContact()
        contact.givenName = "Alice"
        contact.familyName = "Example"

        let writer = FakeContactWriter()
        let store = MeetingContactStore(store: writer, authorizationStatus: { .authorized })

        #expect(await store.resolveDisplayName(for: contact) == "Alice Example")
    }

    @Test("never re-fetches a name while access is undetermined")
    func resolveDisplayNameDoesNotPromptWhenUndetermined() async {
        // A permission prompt must never fire merely to render a participant's name,
        // so an unauthorized store falls back rather than reaching for the address book.
        let writer = FakeContactWriter()
        let store = MeetingContactStore(store: writer, authorizationStatus: { .notDetermined })

        #expect(await store.resolveDisplayName(for: CNMutableContact()) == "Unnamed contact")
    }
}
