import SwiftUI
import MuesliCore
import AIElementsSwift

struct MeetingChatModelPicker: View {
    let appState: AppState
    let controller: MuesliController
    @Environment(\.muesliSettingDefinitions) private var definitions
    @Environment(\.dismiss) private var dismiss
    @State private var applying = false
    @State private var errorMessage: String?

    private var modelSettingID: String? {
        let backend = appState.config.meetingSummaryBackend
        if backend == MeetingSummaryBackendOption.chatGPT.backend { return "summary_chatgpt_model" }
        if backend == MeetingSummaryBackendOption.openAI.backend { return "summary_openai_model" }
        if backend == MeetingSummaryBackendOption.anthropic.backend { return "summary_anthropic_model" }
        if backend == MeetingSummaryBackendOption.claudeCode.backend { return "summary_claude_code_model" }
        if backend == MeetingSummaryBackendOption.openRouter.backend { return "summary_openrouter_model" }
        return nil
    }
    private func snapshot(_ id: String) -> MuesliSetting.Snapshot? {
        definitions.first { $0.id == id }?.snapshot(config: appState.config, source: .manualUI)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Model").font(MuesliTheme.headline())
                Text(MeetingSummaryBackendOption.resolved(appState.config.meetingSummaryBackend).label)
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(16)
            if let id = modelSettingID, let state = snapshot(id) {
                AIModelSelector(
                    choices: state.choices.map { .init(id: $0.id, title: $0.label, disabledReason: state.unavailable[$0.id]) },
                    selectedID: state.current,
                    currentTitle: state.current.isEmpty ? MeetingTextGenerationClient.model(appState.config) : state.current
                ) { value in apply(id, value: value) }
            } else {
                Text(MeetingTextGenerationClient.model(appState.config)).font(.callout).padding(.horizontal, 16).padding(.bottom, 12)
            }
            if let thinking = snapshot("summary_thinking"), !thinking.choices.isEmpty {
                Divider()
                AIThinkingSlider(
                    choices: thinking.choices.map { .init(id: $0.id, title: $0.label, disabledReason: thinking.unavailable[$0.id]) },
                    selectedID: thinking.current
                ) { value in apply("summary_thinking", value: value) }
                    .padding(16)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Shared with meeting summaries. Changes apply to your next question.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    dismiss(); appState.selectedSettingsPane = .meetings; appState.selectedTab = .settings
                } label: { Label { Text("AI Settings…") } icon: { AIIcon(.slidersHorizontal) } }.buttonStyle(.borderless).font(.caption)
            }.padding(16)
        }.frame(width: 310).disabled(applying)
            .alert("Setting could not be changed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }

    private func apply(_ id: String, value: String) {
        applying = true
        Task { @MainActor in
            defer { applying = false }
            do { try await controller.applySetting(id, value: value) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
