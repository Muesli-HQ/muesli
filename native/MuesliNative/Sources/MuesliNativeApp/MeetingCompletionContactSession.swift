import AppKit
import Contacts
import MuesliCore

/// The lifetime of one completion card, separate from its AppKit presentation.
@MainActor
final class MeetingCompletionContactSession {
    enum SelectionResult: Equatable { case added, duplicate, failed, cancelled }

    private let meetingID: Int64
    private let loadParticipants: () async throws -> [MeetingParticipant]
    private let resolveContact: (CNContact) async -> CNContact
    private let attachParticipant: (MeetingParticipantDraft) async throws -> Void
    private let participantsDidChange: () -> Void
    private var isValid = true
    private(set) var hasLoaded = false
    private(set) var participants: [MeetingParticipant] = []
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var buttonLabel = "Add Contact"
    var onChange: (() -> Void)?

    var canPresentPicker: Bool { isValid && !isBusy && (hasLoaded || errorMessage != nil) }

    init(
        meetingID: Int64,
        loadParticipants: @escaping () async throws -> [MeetingParticipant],
        resolveContact: @escaping (CNContact) async -> CNContact,
        attachParticipant: @escaping (MeetingParticipantDraft) async throws -> Void,
        participantsDidChange: @escaping () -> Void
    ) {
        self.meetingID = meetingID
        self.loadParticipants = loadParticipants
        self.resolveContact = resolveContact
        self.attachParticipant = attachParticipant
        self.participantsDidChange = participantsDidChange
    }

    func invalidate() {
        isValid = false
        onChange = nil
    }

    func load() async {
        guard isValid, !isBusy else { return }
        isBusy = true
        onChange?()
        defer { finishWork() }
        do {
            let loaded = try await loadParticipants()
            guard isValid else { return }
            participants = loaded
            hasLoaded = true
            errorMessage = nil
        } catch {
            guard isValid else { return }
            errorMessage = "Couldn't load contacts"
        }
    }

    func select(_ selectedContact: CNContact) async -> SelectionResult {
        guard isValid, !isBusy else { return .cancelled }
        isBusy = true
        errorMessage = nil
        onChange?()
        defer { finishWork() }

        let resolvedContact = await resolveContact(selectedContact)
        guard isValid else { return .cancelled }
        let draft = MeetingContactIdentity.participant(for: resolvedContact, preservingIdentifierFrom: selectedContact)
        let contactEmails = Set([selectedContact, resolvedContact].flatMap { contact -> [String] in
            guard contact.isKeyAvailable(CNContactEmailAddressesKey) else { return [] }
            return contact.emailAddresses.compactMap { Self.normalizedEmail($0.value as String) }
        })
        do {
            let current = try await loadParticipants()
            guard isValid else { return .cancelled }
            participants = current
            hasLoaded = true
        } catch {
            guard isValid else { return .cancelled }
            errorMessage = "Couldn't load contacts"
            return .failed
        }
        guard !participants.contains(where: { Self.matches($0, draft, contactEmails: contactEmails) }) else { return .duplicate }

        do {
            try await attachParticipant(draft)
        } catch {
            guard isValid else { return .cancelled }
            errorMessage = "Couldn't add contact"
            return .failed
        }
        // A committed write belongs to the meeting even if its card was closed meanwhile.
        participantsDidChange()
        guard isValid else { return .cancelled }
        buttonLabel = "Add Another"
        let fallback = MeetingParticipant(
            meetingID: meetingID,
            participantIdentifier: draft.participantIdentifier,
            displayName: draft.displayName,
            emailAddress: draft.emailAddress,
            insertionOrder: (participants.map(\.insertionOrder).max() ?? -1) + 1
        )
        participants.append(fallback)
        // A failed refresh must not turn a successful write into an apparent failure.
        if let refreshed = try? await loadParticipants() {
            guard isValid else { return .cancelled }
            participants = refreshed
        }
        return isValid ? .added : .cancelled
    }

    var fullParticipantSummary: String {
        guard !participants.isEmpty else { return "" }
        return "With " + participants.map(\.displayName).joined(separator: ", ")
    }

    func participantSummary(maxWidth: CGFloat) -> String {
        guard !participants.isEmpty else { return "" }
        let names = participants.map(\.displayName)
        let font = NSFont.systemFont(ofSize: 11)
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        func summary(_ count: Int) -> String {
            let extra = names.count - count
            return "With " + names.prefix(count).joined(separator: ", ") + (extra > 0 ? " +\(extra)" : "")
        }
        var count = min(2, names.count)
        while count > 1, width(summary(count)) > maxWidth { count -= 1 }
        let result = summary(count)
        guard width(result) > maxWidth else { return result }
        let suffix = names.count > 1 ? " +\(names.count - 1)" : ""
        var name = names[0]
        while !name.isEmpty, width("With " + name + "…" + suffix) > maxWidth { name.removeLast() }
        return "With " + name + "…" + suffix
    }

    private func finishWork() {
        guard isValid else { return }
        isBusy = false
        onChange?()
    }

    private static func normalizedEmail(_ email: String?) -> String? {
        let value = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return value.isEmpty ? nil : value
    }

    private static func matches(_ participant: MeetingParticipant, _ draft: MeetingParticipantDraft, contactEmails: Set<String>) -> Bool {
        if participant.participantIdentifier == draft.participantIdentifier { return true }
        guard let email = normalizedEmail(participant.emailAddress) else { return false }
        return contactEmails.contains(email)
    }
}
