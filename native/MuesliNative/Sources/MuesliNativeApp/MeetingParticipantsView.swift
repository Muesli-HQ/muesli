import AppKit
import Contacts
import MuesliCore
import SwiftUI

struct MeetingParticipantsView: View {
    let meetingID: Int64
    let controller: MuesliController

    @State private var participants: [MeetingParticipant] = []
    @State private var isContactPickerPresented = false
    @State private var isNewContactPresented = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var statusDismissTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Text("People")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                WordFlowLayout(spacing: MuesliTheme.spacing8) {
                    ForEach(participants) { participant in
                        participantChip(participant)
                    }

                    Button {
                        isContactPickerPresented = true
                    } label: {
                        Label("Add person", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Attach someone from Contacts to this meeting")
                    .background {
                        MeetingContactPicker(isPresented: $isContactPickerPresented) { contact in
                            attach(contact)
                        }
                    }

                    Button("New Contact…") {
                        isNewContactPresented = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .help("Create a new contact in Apple Contacts and attach them")
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .transition(.opacity)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People in this meeting")
        .task(id: meetingID) {
            await reload()
        }
        .onDisappear {
            statusDismissTask?.cancel()
        }
        .sheet(isPresented: $isNewContactPresented) {
            NewMeetingContactView { contact in
                Task { @MainActor in
                    await attach(
                        contactIdentifier: contact.identifier,
                        displayName: contact.displayName
                    )
                }
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

    private func participantChip(_ participant: MeetingParticipant) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "person.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(participant.displayName)
                .lineLimit(1)
            Button {
                remove(participant)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .padding(3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(participant.displayName)")
        }
        .font(MuesliTheme.caption())
        .foregroundStyle(MuesliTheme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
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

    private func reload() async {
        do {
            participants = try await DictationStore.withTransientLockRetry {
                try controller.meetingParticipants(meetingID: meetingID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Resolves the picker-vended contact's name before storing it — the picker may
    /// hand back a contact without the name keys fetched.
    private func attach(_ contact: CNContact) {
        Task { @MainActor in
            let displayName = await MeetingContactStore().resolveDisplayName(for: contact)
            await attach(contactIdentifier: contact.identifier, displayName: displayName)
        }
    }

    private func attach(contactIdentifier: String, displayName: String) async {
        do {
            let added = try await DictationStore.withTransientLockRetry {
                try controller.attachMeetingParticipant(
                    meetingID: meetingID,
                    contactIdentifier: contactIdentifier,
                    displayName: displayName
                )
            }
            await reload()
            if !added {
                showStatus("\(displayName) is already on this meeting.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ participant: MeetingParticipant) {
        Task { @MainActor in
            do {
                try await DictationStore.withTransientLockRetry {
                    try controller.removeMeetingParticipant(
                        meetingID: meetingID,
                        contactIdentifier: participant.contactIdentifier
                    )
                }
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func showStatus(_ message: String) {
        statusDismissTask?.cancel()
        statusMessage = message
        statusDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }
}
