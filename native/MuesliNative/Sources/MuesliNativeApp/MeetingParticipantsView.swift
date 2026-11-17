import Contacts
import MuesliCore

enum ParticipantSuggestionPrivacy {
    static let disclosure = "AI may send part of this meeting to your provider."
}
import SwiftUI

extension Notification.Name {
    static let meetingParticipantsDidChange = Notification.Name("MuesliMeetingParticipantsDidChange")
}

struct MeetingParticipantsView: View {
    let meetingID: Int64
    let controller: MuesliController
    let compactDiscardAction: (() -> Void)?

    @State private var participants: [MeetingParticipant] = []
    @State private var isContactPickerPresented = false
    @State private var isNewContactPresented = false
    @State private var isPeoplePopoverPresented = false
    @State private var isManualPersonPresented = false
    @State private var manualPersonName = ""
    @State private var suggestions: [MeetingParticipantSuggestion] = []
    @State private var suggestionFingerprint = ""
    @State private var suggestionTask: Task<Void, Never>?
    @State private var findingPeople = false
    @State private var suggestionMessage: String?
    @State private var evidenceSuggestionID: String?
    @State private var matchingPeople: [String: [MeetingParticipantDraft]] = [:]
    @State private var errorMessage: String?

    init(
        meetingID: Int64,
        controller: MuesliController,
        compactDiscardAction: (() -> Void)? = nil
    ) {
        self.meetingID = meetingID
        self.controller = controller
        self.compactDiscardAction = compactDiscardAction
    }

    private var peopleDescription: String {
        participants.count == 1 ? "1 person" : "\(participants.count) people"
    }

    private var firstParticipantName: String? {
        participants.first.map {
            MeetingContactIdentity.compactDisplayName(
                $0.displayName,
                emailAddress: $0.emailAddress
            )
        }
    }

    var body: some View {
        participantControl
        .featureTourTarget(.meetingPeople)
        .popover(isPresented: $isPeoplePopoverPresented, arrowEdge: .bottom) {
            peoplePopover
        }
        .background {
            MeetingContactPicker(isPresented: $isContactPickerPresented) { contact in
                Task { await attach(contact) }
            }
        }
        .task(id: meetingID) {
            await reload()
            await reloadSuggestions()
        }
        .onDisappear { suggestionTask?.cancel(); suggestionTask = nil }
        .onChange(of: isPeoplePopoverPresented) { _, presented in
            if presented {
                Task {
                    await reload()
                    await reloadSuggestions()
                }
            }
        }
        .onChange(of: meetingID) { _, _ in
            suggestionTask?.cancel(); suggestionTask = nil
            suggestions = []; matchingPeople = [:]; suggestionMessage = nil; evidenceSuggestionID = nil; findingPeople = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingParticipantsDidChange)) { notification in
            guard notification.object as? Int64 == meetingID else { return }
            Task { await reload() }
        }
        .sheet(isPresented: $isNewContactPresented) {
            NewMeetingContactView { participant in
                Task { await attach(participant) }
            }
        }
        .alert("Add person", isPresented: $isManualPersonPresented) {
            TextField("Name", text: $manualPersonName)
            Button("Cancel", role: .cancel) { manualPersonName = "" }
            Button("Add") {
                let name = manualPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
                manualPersonName = ""
                guard !name.isEmpty else { return }
                Task { await attach(MeetingParticipantDraft(participantIdentifier: "manual:\(UUID().uuidString)", displayName: name)) }
            }
        }
        .alert("Couldn't Update People", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "The meeting's people could not be updated.")
        }
    }

    @ViewBuilder
    private var participantControl: some View {
        if let compactDiscardAction {
            Menu {
                Button {
                    presentPeoplePopoverAfterMenuDismisses()
                } label: {
                    Label("Add people…", systemImage: "person.2")
                }

                Divider()

                Button("Discard meeting", role: .destructive) {
                    compactDiscardAction()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.backgroundRaised)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More recording actions")
            .accessibilityLabel("More recording actions")
        } else {
            Button {
                isPeoplePopoverPresented.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: participants.isEmpty ? "person.2" : "person.2.fill")

                    if let firstParticipantName {
                        Text(firstParticipantName)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if participants.count > 1 {
                            Text("+\(participants.count - 1)")
                                .foregroundStyle(MuesliTheme.textTertiary)
                        }
                    } else {
                        Text("Add people")
                    }
                }
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: MeetingHeaderLayout.contextControlHeight)
                .frame(maxWidth: 220)
                .background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .help(participants.isEmpty ? "Add people to this meeting" : "Show \(peopleDescription)")
            .accessibilityLabel(
                participants.isEmpty ? "Add people to this meeting" : "\(peopleDescription) in this meeting"
            )
        }
    }

    private var peoplePopover: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing8) {
                Text("People")
                    .font(MuesliTheme.title3())

                if !participants.isEmpty {
                    Text(peopleDescription)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }

                Spacer()

                addPersonMenu
            }

            Divider()
            ScrollViewReader { proxy in
            ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            if participants.isEmpty && suggestions.isEmpty {
                Text("No one has been added yet.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, MuesliTheme.spacing8)
            } else if !participants.isEmpty {
                LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    ForEach(participants) { participant in
                        participantListRow(participant)
                    }
                }
            }

            if !participants.isEmpty || suggestions.isEmpty { Divider() }
            HStack {
                Button(findingPeople ? "Finding people…" : "Find participants") { findParticipants() }
                    .disabled(findingPeople)
                if findingPeople { ProgressView().controlSize(.small) }
            }
            Text(ParticipantSuggestionPrivacy.disclosure)
                .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let suggestionMessage {
                Text(suggestionMessage).font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true).id("suggestionMessage")
            }
            if !suggestions.isEmpty {
                    Text("Suggested")
                        .font(MuesliTheme.caption()).foregroundStyle(MuesliTheme.textSecondary)
                    LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(suggestions) { suggestion in
                            HStack(spacing: MuesliTheme.spacing8) {
                                    Image(systemName: "person.crop.circle")
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                    Text(suggestion.name).font(MuesliTheme.callout()).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button { evidenceSuggestionID = suggestion.id } label: {
                                        Image(systemName: "info.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Show supporting excerpt")
                                    .accessibilityLabel("Show evidence for \(suggestion.name)")
                                    .popover(isPresented: Binding(
                                        get: { evidenceSuggestionID == suggestion.id },
                                        set: { if !$0 { evidenceSuggestionID = nil } }
                                    )) {
                                        ScrollView {
                                            Text(suggestion.excerpt).font(MuesliTheme.callout())
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }.frame(width: 260, height: 110).padding(MuesliTheme.spacing12)
                                    }
                                    Menu("Add") {
                                        Button("Add as new person") { resolve(suggestion, add: true) }
                                        ForEach(matchingPeople[suggestion.id] ?? [], id: \.participantIdentifier) { person in
                                            Button("Use \(person.displayName)\(person.emailAddress.map { " · " + $0 } ?? "")") {
                                                resolve(suggestion, add: true, existingPerson: person)
                                            }
                                        }
                                    }
                                    Button { resolve(suggestion, add: false) } label: {
                                        Image(systemName: "xmark").frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Dismiss suggestion")
                                    .accessibilityLabel("Dismiss \(suggestion.name)")
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.id("suggestions")
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: suggestions) { _, updated in
                if !updated.isEmpty { proxy.scrollTo("suggestions", anchor: .top) }
            }
            .onChange(of: suggestionMessage) { _, updated in
                if updated != nil { proxy.scrollTo("suggestionMessage", anchor: .bottom) }
            }
            }
        }
        .padding(MuesliTheme.spacing16)
        .frame(width: 340, height: 220)
    }

    private var addPersonMenu: some View {
        Menu {
            Button {
                isPeoplePopoverPresented = false
                Task { @MainActor in
                    await Task.yield()
                    isManualPersonPresented = true
                }
            } label: {
                Label("Enter a name…", systemImage: "person.badge.plus")
            }
            Button {
                chooseExistingContact()
            } label: {
                Label("Choose from Contacts…", systemImage: "person.crop.circle.badge.plus")
            }

            Button {
                createNewContact()
            } label: {
                Label("Create New Contact…", systemImage: "person.badge.plus")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.badge.plus")
                Text("Add person")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: MeetingHeaderLayout.contextControlHeight)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay {
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose or create an Apple contact")
    }

    private func participantListRow(_ participant: MeetingParticipant) -> some View {
        let displayName = MeetingContactIdentity.compactDisplayName(
            participant.displayName,
            emailAddress: participant.emailAddress
        )
        return HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(MuesliTheme.textTertiary)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(MuesliTheme.callout())
                if let email = participant.emailAddress, email != displayName {
                    Text(email)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                }
            }

            Spacer()

            Button {
                remove(participant)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.muesli(.quiet))
            .help("Remove \(displayName)")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in
                if !presented {
                    errorMessage = nil
                }
            }
        )
    }

    private func chooseExistingContact() {
        isPeoplePopoverPresented = false
        Task { @MainActor in
            await Task.yield()
            isContactPickerPresented = true
        }
    }

    private func presentPeoplePopoverAfterMenuDismisses() {
        Task { @MainActor in
            await Task.yield()
            isPeoplePopoverPresented = true
        }
    }

    private func createNewContact() {
        isPeoplePopoverPresented = false
        Task { @MainActor in
            await Task.yield()
            isNewContactPresented = true
        }
    }

    private func reload() async {
        do {
            participants = try await controller.meetingParticipants(meetingID: meetingID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadSuggestions() async {
        do {
            let (fingerprint, found) = try await controller.participantSuggestions(meetingID: meetingID)
            guard !Task.isCancelled else { return }
            suggestionFingerprint = fingerprint; suggestions = found
            var matches: [String: [MeetingParticipantDraft]] = [:]
            for suggestion in found {
                try Task.checkCancellation()
                matches[suggestion.id] = try await controller.globalSearchWorker.people(matching: suggestion.name)
            }
            guard !Task.isCancelled else { return }
            matchingPeople = matches
        } catch is CancellationError {} catch {
            guard !Task.isCancelled else { return }
            suggestionMessage = error.localizedDescription
        }
    }

    private func findParticipants() {
        suggestionTask?.cancel()
        findingPeople = true; suggestionMessage = nil
        suggestionTask = Task {
            defer { findingPeople = false }
            do {
                let wasTruncated = try await controller.findParticipantSuggestions(meetingID: meetingID)
                try Task.checkCancellation()
                await reloadSuggestions()
                if wasTruncated {
                    suggestionMessage = suggestions.isEmpty ? "No suggestions found. Only part of this meeting was reviewed." : "Only part of this meeting was reviewed."
                } else if suggestions.isEmpty { suggestionMessage = "No new suggestions in the reviewed text." }
            } catch is CancellationError {} catch { suggestionMessage = error.localizedDescription }
        }
    }

    private func resolve(_ suggestion: MeetingParticipantSuggestion, add: Bool, existingPerson: MeetingParticipantDraft? = nil) {
        Task {
            do {
                try await controller.resolveParticipantSuggestion(meetingID: meetingID, fingerprint: suggestionFingerprint, name: suggestion.name, add: add, existingPerson: existingPerson)
                await reloadSuggestions()
                if add { await reload() }
            } catch {
                suggestionMessage = error.localizedDescription
                await reloadSuggestions()
            }
        }
    }

    private func attach(_ contact: CNContact) async {
        let resolvedContact = await MeetingContactResolver().resolve(contact)
        await attach(
            MeetingContactIdentity.participant(
                for: resolvedContact,
                preservingIdentifierFrom: contact
            )
        )
    }

    private func attach(_ participant: MeetingParticipantDraft) async {
        do {
            try await controller.attachMeetingParticipant(
                meetingID: meetingID,
                participant: participant
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ participant: MeetingParticipant) {
        Task {
            do {
                try await controller.removeMeetingParticipant(
                    meetingID: meetingID,
                    participantIdentifier: participant.participantIdentifier
                )
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
