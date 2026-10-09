import SwiftUI
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
            Text("Edit draft").font(.title2)
            Text("The original answer and its source references are preserved.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(MuesliTheme.body()).frame(minHeight: 320)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save draft") { onSave(text); dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 650)
    }
}
