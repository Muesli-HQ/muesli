import AppKit
import SwiftUI

struct NewMeetingContactView: View {
    let onCreated: (SavedMeetingContact) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = NewMeetingContactDraft()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isAccessDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Text("New Contact")
                .font(MuesliTheme.title2())

            Text("Add an email address or phone number so this person can be saved to Apple Contacts.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)

            Grid(alignment: .leading, horizontalSpacing: MuesliTheme.spacing12, verticalSpacing: MuesliTheme.spacing12) {
                contactField("First name", text: $draft.givenName)
                contactField("Last name", text: $draft.familyName)
                contactField("Email", text: $draft.emailAddress)
                contactField("Phone", text: $draft.phoneNumber)
            }

            HStack {
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
        .frame(width: 440)
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

    private func openContactsPrivacyPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
            NSWorkspace.shared.open(url)
        }
    }

    private func contactField(_ label: String, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 80, alignment: .trailing)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 280)
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
                let saved = try await MeetingContactStore().save(draft)
                // Dismiss before handing the contact back: `onCreated` can surface an
                // error on the presenting view, and SwiftUI drops a presentation
                // requested while another is being torn down.
                dismiss()
                onCreated(saved)
            } catch {
                isAccessDenied = (error as? MeetingContactStoreError) == .accessDenied
                errorMessage = error.localizedDescription
            }
        }
    }
}
