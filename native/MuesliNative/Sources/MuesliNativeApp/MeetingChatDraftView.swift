import SwiftUI
import AIElementsSwift
import MuesliCore

struct MeetingChatDraftView: View {
    let turn: MeetingChatTurn
    let onSave: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss
    init(turn: MeetingChatTurn, onSave: @escaping (String) -> Void) {
        self.turn = turn; self.onSave = onSave
        _text = State(initialValue: turn.editableDraft ?? turn.originalAnswer ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label { Text("Edit draft") } icon: { AIIcon(.squarePen) }.font(MuesliTheme.title2())
            Text("The original answer and its source references are preserved.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
            TextEditor(text: $text).font(MuesliTheme.reading()).scrollContentBackground(.hidden)
                .padding(12).frame(minHeight: 320).background(MuesliTheme.backgroundDeep, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Editable answer draft")
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Save draft") { onSave(text); dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command) }
        }.padding(24).frame(width: 650)
    }
}
