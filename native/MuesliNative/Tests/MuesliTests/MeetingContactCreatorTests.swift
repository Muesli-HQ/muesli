import Contacts
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

final class FakeMeetingContactWriter: MeetingContactWriting, @unchecked Sendable {
    struct Snapshot {
        var status: CNAuthorizationStatus = .authorized
        var granted = true
        var destination = "carddav-default"
        var rejectSave = false
        var requests = 0
        var destinations: [String] = []
        var givenName = ""
        var familyName = ""
        var company = ""
        var phone: String?
        var email: String?
        var identifier = ""
        var savedOnMainThread = false
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private let accessRequest: (@Sendable () async throws -> Bool)?

    init(accessRequest: (@Sendable () async throws -> Bool)? = nil) {
        self.accessRequest = accessRequest
    }
    var snapshot: Snapshot { lock.withLock { state } }
    func configure(_ update: (inout Snapshot) -> Void) { lock.withLock { update(&state) } }
    func contactsAuthorizationStatus() -> CNAuthorizationStatus { snapshot.status }
    func requestContactsAccess() async throws -> Bool {
        let granted = lock.withLock {
            state.requests += 1
            return state.granted
        }
        if let accessRequest { return try await accessRequest() }
        return granted
    }
    func defaultContainerIdentifier() -> String { snapshot.destination }
    func save(_ contact: CNMutableContact, toContainerWithIdentifier identifier: String) throws {
        try lock.withLock {
            state.destinations.append(identifier)
            if state.rejectSave { throw CocoaError(.fileWriteNoPermission) }
            state.givenName = contact.givenName
            state.familyName = contact.familyName
            state.company = contact.organizationName
            state.phone = contact.phoneNumbers.first?.value.stringValue
            state.email = contact.emailAddresses.first?.value as String?
            state.identifier = contact.identifier
            state.savedOnMainThread = Thread.isMainThread
        }
    }
}

@Suite("Meeting contact creator")
struct MeetingContactCreatorTests {
    private func draft() -> NewMeetingContactDraft {
        var draft = NewMeetingContactDraft()
        draft.givenName = "  Zoë "
        draft.familyName = " Example\n"
        draft.companyName = " Example Co "
        draft.phoneNumber = " +1 555 0100 "
        draft.emailAddress = " PERSON@EXAMPLE.TEST "
        return draft
    }

    @Test func savesAllFiveFieldsToExplicitDefaultOffMainThread() async throws {
        let store = FakeMeetingContactWriter()
        let participant = try await MeetingContactCreator(store: store).create(draft())
        let saved = store.snapshot
        #expect(saved.destinations == ["carddav-default"])
        #expect(saved.givenName == "Zoë")
        #expect(saved.familyName == "Example")
        #expect(saved.company == "Example Co")
        #expect(saved.phone == "+1 555 0100")
        #expect(saved.email == "PERSON@EXAMPLE.TEST")
        #expect(!saved.savedOnMainThread)
        #expect(saved.requests == 0)
        #expect(participant.participantIdentifier == "email:person@example.test")
        #expect(participant.emailAddress == "person@example.test")
    }

    @Test func resolvesChangedDefaultForEachAttempt() async throws {
        let store = FakeMeetingContactWriter()
        let creator = MeetingContactCreator(store: store)
        _ = try await creator.create(draft())
        store.configure { $0.destination = "local-default" }
        _ = try await creator.create(draft())
        #expect(store.snapshot.destinations == ["carddav-default", "local-default"])
    }

    @Test func missingDefaultDoesNotSave() async {
        let store = FakeMeetingContactWriter()
        store.configure { $0.destination = "" }
        await #expect(throws: MeetingContactCreatorError.destinationUnavailable) {
            try await MeetingContactCreator(store: store).create(draft())
        }
        #expect(store.snapshot.destinations.isEmpty)
    }

    @Test func rejectedDefaultDoesNotFallback() async {
        let store = FakeMeetingContactWriter()
        store.configure { $0.rejectSave = true }
        await #expect(throws: CocoaError.self) {
            try await MeetingContactCreator(store: store).create(draft())
        }
        #expect(store.snapshot.destinations == ["carddav-default"])
    }

    @Test(arguments: [CNAuthorizationStatus.denied, .restricted])
    func deniedPermissionDoesNotSave(status: CNAuthorizationStatus) async {
        let store = FakeMeetingContactWriter()
        store.configure { $0.status = status }
        await #expect(throws: MeetingContactCreatorError.accessDenied) {
            try await MeetingContactCreator(store: store).create(draft())
        }
        #expect(store.snapshot.requests == 0)
        #expect(store.snapshot.destinations.isEmpty)
    }

    @Test func refusedPermissionDoesNotSave() async {
        let store = FakeMeetingContactWriter()
        store.configure { $0.status = .notDetermined; $0.granted = false }
        await #expect(throws: MeetingContactCreatorError.accessDenied) {
            try await MeetingContactCreator(store: store).create(draft())
        }
        #expect(store.snapshot.requests == 1)
        #expect(store.snapshot.destinations.isEmpty)
    }

    @Test func grantsPermissionOnlyOnCreate() async throws {
        let store = FakeMeetingContactWriter()
        store.configure { $0.status = .notDetermined }
        let creator = MeetingContactCreator(store: store)
        #expect(store.snapshot.requests == 0)
        _ = try await creator.create(draft())
        #expect(store.snapshot.requests == 1)
        #expect(store.snapshot.destinations == ["carddav-default"])
    }

    @Test func optionalFieldsStayEmptyAndPhoneOnlyUsesSavedIdentity() async throws {
        let store = FakeMeetingContactWriter()
        var input = NewMeetingContactDraft()
        input.familyName = " 李 "
        input.phoneNumber = " +1 555 0100 "
        let participant = try await MeetingContactCreator(store: store).create(input)
        #expect(participant.participantIdentifier == "contact:\(store.snapshot.identifier)")
        #expect(!store.snapshot.identifier.isEmpty)
        #expect(participant.emailAddress == nil)
        #expect(store.snapshot.company.isEmpty)
        #expect(store.snapshot.email == nil)
        input.phoneNumber = " \n "
        _ = try await MeetingContactCreator(store: store).create(input)
        #expect(store.snapshot.phone == nil)
    }

    @Test func blankNamesDoNotRequestAccessOrSave() async {
        let store = FakeMeetingContactWriter()
        store.configure { $0.status = .notDetermined }
        var input = NewMeetingContactDraft()
        input.givenName = " \n "
        input.familyName = " \t "
        input.emailAddress = "person@example.test"
        await #expect(throws: MeetingContactCreatorError.nameRequired) {
            try await MeetingContactCreator(store: store).create(input)
        }
        #expect(store.snapshot.requests == 0)
        #expect(store.snapshot.destinations.isEmpty)
    }

    @Test func unavailableAuthorizationDoesNotSave() async throws {
        let store = FakeMeetingContactWriter()
        let status = try #require(CNAuthorizationStatus(rawValue: 4))
        store.configure { $0.status = status }
        await #expect(throws: MeetingContactCreatorError.accessUnavailable) {
            try await MeetingContactCreator(store: store).create(draft())
        }
        #expect(store.snapshot.requests == 0)
        #expect(store.snapshot.destinations.isEmpty)
    }

    @Test func authorizationErrorFromPermissionRequestIsRecoverable() async {
        let store = FakeMeetingContactWriter(accessRequest: {
            throw NSError(domain: CNErrorDomain, code: CNError.Code.authorizationDenied.rawValue)
        })
        store.configure { $0.status = .notDetermined }
        await #expect(throws: MeetingContactCreatorError.accessDenied) {
            try await MeetingContactCreator(store: store).create(draft())
        }
        #expect(store.snapshot.destinations.isEmpty)
    }

    @Test func permissionRequestErrorDoesNotSave() async {
        let store = FakeMeetingContactWriter(accessRequest: { throw CocoaError(.fileReadNoPermission) })
        store.configure { $0.status = .notDetermined }
        await #expect(throws: CocoaError.self) {
            try await MeetingContactCreator(store: store).create(draft())
        }
        #expect(store.snapshot.destinations.isEmpty)
    }

    @Test func cancellationDuringPermissionDoesNotSave() async {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (decisions, answer) = AsyncStream<Bool>.makeStream()
        let store = FakeMeetingContactWriter(accessRequest: {
            signal.yield(())
            for await granted in decisions { return granted }
            return false
        })
        store.configure { $0.status = .notDetermined }
        let creator = MeetingContactCreator(store: store)
        let input = draft()
        let task = Task { try await creator.create(input) }
        for await _ in started { break }
        task.cancel()
        answer.yield(true)
        answer.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.snapshot.destinations.isEmpty)
    }

    @Test func cancelledBeforeSaveWritesNothing() async {
        let store = FakeMeetingContactWriter()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingContactCreator(store: store).create(draft())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(store.snapshot.destinations.isEmpty)
    }
}
