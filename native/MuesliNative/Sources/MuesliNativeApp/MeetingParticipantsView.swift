import AppKit
import Contacts
import MuesliCore
import SwiftUI

struct MeetingParticipantsView: View {
    let meetingID: Int64
    let controller: MuesliController

    @State private var participants: [MeetingParticipant] = []
    @State private var isContactPickerPresented = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Text("People")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.top, 5)

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
                .help("Add someone from Apple Contacts")
                .background {
                    MeetingContactPicker(isPresented: $isContactPickerPresented) { contact in
                        Task { await attach(contact) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("People in this meeting")
        .task(id: meetingID) {
            await reload()
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
        .help(participant.emailAddress ?? participant.displayName)
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
            participants = try await controller.meetingParticipants(meetingID: meetingID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func attach(_ contact: CNContact) async {
        do {
            try await controller.attachMeetingParticipant(
                meetingID: meetingID,
                participant: MeetingContactIdentity.participant(for: contact)
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
