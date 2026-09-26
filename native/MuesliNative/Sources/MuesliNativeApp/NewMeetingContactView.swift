import AppKit
import MuesliCore
import SwiftUI

@MainActor
struct NewMeetingContactView: View {
    @StateObject private var flow: MeetingContactCreationFlow

    init(flow: MeetingContactCreationFlow) {
        _flow = StateObject(wrappedValue: flow)
    }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    private enum Field {
        case firstName
        case lastName
        case company
        case phone
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
                contactField("First name", text: $flow.draft.givenName, field: .firstName)
                contactField("Last name", text: $flow.draft.familyName, field: .lastName)
                contactField("Company", text: $flow.draft.companyName, field: .company)
                contactField("Phone", text: $flow.draft.phoneNumber, field: .phone)
                contactField("Email", text: $flow.draft.emailAddress, field: .email)
            }
            .disabled(flow.isWorking || flow.hasSavedContact)

            if flow.hasSavedContact, !flow.isComplete {
                Text(flow.savedParticipant == nil
                     ? "Saved to Apple Contacts. Close this form and choose the person from Contacts to add them to the meeting."
                     : "Saved to Apple Contacts. You can retry adding this person to the meeting, or close this form and choose them later.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }

            HStack(spacing: MuesliTheme.spacing12) {
                if flow.isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(flow.hasSavedContact ? "Adding to meeting…" : "Saving to Contacts…")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }

                Spacer()

                Button(flow.hasSavedContact ? "Close" : "Cancel") {
                    flow.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(flow.isWorking)

                Button(flow.savedParticipant == nil ? "Save Contact" : "Retry Add to Meeting") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(flow.isWorking || (flow.savedParticipant == nil && (!flow.draft.canSave || flow.hasSavedContact)))
            }
        }
        .padding(MuesliTheme.spacing24)
        .frame(width: 430)
        .interactiveDismissDisabled(flow.isWorking || flow.hasSavedContact)
        .onAppear {
            focusedField = .firstName
        }
        .onChange(of: flow.isComplete) { _, complete in
            if complete { dismiss() }
        }
        .alert(alertTitle, isPresented: errorBinding) {
            if flow.isAccessDenied {
                Button("Open System Settings") {
                    openContactsPrivacyPane()
                    flow.clearError()
                }
            }
            Button("OK", role: .cancel) {
                flow.clearError()
            }
        } message: {
            Text(alertMessage)
        }
    }

    private var alertTitle: String {
        switch flow.failureStage {
        case .attachment:
            return "Couldn't Add Person to Meeting"
        case .contactSaved:
            return "Contact Saved"
        case .contacts, .none:
            return "Couldn't Save Contact"
        }
    }

    private var alertMessage: String {
        switch flow.failureStage {
        case .attachment:
            return "The contact was saved to Apple Contacts. Adding them to this meeting failed. \(flow.errorMessage ?? "Please retry adding them.")"
        case .contactSaved:
            return flow.errorMessage ?? "The contact was saved, but Apple Contacts did not return an identifier. Choose the saved person from Contacts to add them to the meeting."
        case .contacts, .none:
            return flow.errorMessage ?? "The contact could not be saved."
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
            get: { flow.errorMessage != nil },
            set: { presented in
                if !presented {
                    flow.clearError()
                }
            }
        )
    }

    private func save() {
        Task { @MainActor in
            await flow.saveAndAttach()
        }
    }

    private func openContactsPrivacyPane() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
