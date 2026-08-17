import AppKit
import MuesliCore
import SwiftUI

struct NewMeetingContactView: View {
    let onCreated: (MeetingParticipantDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = NewMeetingContactDraft()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isAccessDenied = false
    @FocusState private var focusedField: Field?

    private enum Field {
        case firstName
        case lastName
        case email
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Create New Contact")
                    .font(MuesliTheme.title2())
                Text("Save this person to Apple Contacts and add them to the meeting.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            Grid(alignment: .leading, horizontalSpacing: MuesliTheme.spacing12, verticalSpacing: MuesliTheme.spacing12) {
                contactField("First name", text: $draft.givenName, field: .firstName)
                contactField("Last name", text: $draft.familyName, field: .lastName)
                contactField("Email", text: $draft.emailAddress, field: .email)
            }

            HStack(spacing: MuesliTheme.spacing12) {
                if isSaving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving to Contacts…")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save Contact") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canSave || isSaving)
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(width: 430)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            focusedField = .firstName
        }
        .alert("Couldn't Save Contact", isPresented: errorBinding) {
            if isAccessDenied {
                Button("Open System Settings") {
                    openContactsPrivacyPane()
                    errorMessage = nil
                }
            }
            Button("OK", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "The contact could not be saved.")
        }
    }

    private func contactField(_ label: String, text: Binding<String>, field: Field) -> some View {
        GridRow {
            Text(label)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 78, alignment: .trailing)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field)
                .frame(minWidth: 270)
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

    private func save() {
        guard draft.canSave, !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let participant = try await MeetingContactCreator.create(draft)
                dismiss()
                onCreated(participant)
            } catch {
                isAccessDenied = (error as? MeetingContactCreatorError) == .accessDenied
                errorMessage = error.localizedDescription
            }
        }
    }

    private func openContactsPrivacyPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
