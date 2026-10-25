import SwiftUI

struct SharingRecipientField: View {
    @Binding var input: SharingRecipientInput
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                if !input.emails.isEmpty {
                    ScrollView {
                        WordFlowLayout(spacing: 6) {
                            ForEach(input.emails, id: \.self) { email in
                                HStack(spacing: 6) {
                                    Text(email).lineLimit(1).truncationMode(.middle)
                                        .frame(maxWidth: 440)
                                    Button {
                                        input.remove(email)
                                        focused = true
                                    } label: {
                                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(email)")
                                }
                                .font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(MuesliTheme.accentSubtle, in: Capsule())
                                .help(email)
                            }
                        }
                    }
                    .frame(height: input.emails.count == 1 ? 30 : 64)
                }
                HStack {
                    TextField(input.emails.isEmpty ? "Add a person by email" : "Add another person", text: $input.draft)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { input.commit() }
                        .onKeyPress(.tab) {
                            input.commit()
                            return .ignored
                        }
                    if !input.draft.isEmpty {
                        Button {
                            input.commit()
                            focused = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MuesliTheme.accent)
                        .accessibilityLabel("Add email")
                    }
                }
            }
            .padding(10)
            .background(MuesliTheme.backgroundBase, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? MuesliTheme.accent : MuesliTheme.surfaceBorder)
            )
            if let error = input.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: focused) { _, value in if !value { input.commit() } }
        .onChange(of: input.draft) { _, value in
            // A delimiter commits an address; pasting multiple addresses commits the batch.
            // Do not tokenize a valid-looking prefix while someone is still typing a domain.
            if value.rangeOfCharacter(from: CharacterSet(charactersIn: ",;\n\t")) != nil
                || (value.contains(" ")
                    && value.split(separator: " ").allSatisfy({ SharingRecipientInput.isValid(String($0)) }))
            {
                input.commit()
            }
        }
    }
}
