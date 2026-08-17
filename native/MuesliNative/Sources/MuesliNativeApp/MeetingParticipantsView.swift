import Contacts
import MuesliCore
import SwiftUI

extension Notification.Name {
    static let meetingParticipantsDidChange = Notification.Name("MuesliMeetingParticipantsDidChange")
}

struct MeetingParticipantsView: View {
    let meetingID: Int64
    let controller: MuesliController

    @State private var participants: [MeetingParticipant] = []
    @State private var isContactPickerPresented = false
    @State private var isNewContactPresented = false
    @State private var isPeoplePopoverPresented = false
    @State private var errorMessage: String?

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
        .featureTourTarget(.meetingPeople)
        .help(participants.isEmpty ? "Add people to this meeting" : "Show \(peopleDescription)")
        .accessibilityLabel(
            participants.isEmpty ? "Add people to this meeting" : "\(peopleDescription) in this meeting"
        )
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
        .alert("Couldn't Update People", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "The meeting's people could not be updated.")
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

            if participants.isEmpty {
                Text("No one has been added yet.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, MuesliTheme.spacing8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        ForEach(participants) { participant in
                            participantListRow(participant)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(MuesliTheme.spacing16)
        .frame(width: 340)
    }

    private var addPersonMenu: some View {
        Menu {
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
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
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

    private func attach(_ contact: CNContact) async {
        await attach(MeetingContactIdentity.participant(for: contact))
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
