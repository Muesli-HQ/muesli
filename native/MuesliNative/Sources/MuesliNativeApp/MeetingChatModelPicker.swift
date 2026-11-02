import SwiftUI
import MuesliCore
import AIElementsSwift

struct MeetingChatModelPicker: View {
    let appState: AppState
    let controller: MuesliController
    @Environment(\.muesliSettingDefinitions) private var definitions
    @Environment(\.dismiss) private var dismiss

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
            HStack {
                Text("Model").font(MuesliTheme.font(size: 13, weight: .semibold))
                Spacer()
                if let providers = snapshot("summary_source") {
                    Menu {
                        ForEach(providers.choices.filter { choice in
                            choice.id == providers.current || controller.canUseSummaryProvider(.resolved(choice.id))
                        }, id: \.id) { choice in
                            Button { apply("summary_source", value: choice.id) } label: {
                                if choice.id == providers.current { Label { Text(choice.label) } icon: { AIIcon(.check, size: 12) } }
                                else { Text(choice.label) }
                            }.disabled(providers.unavailable[choice.id] != nil)
                        }
                        Divider()
                        Button("Connect a provider…") { openSettings() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(MeetingSummaryBackendOption.resolved(appState.config.meetingSummaryBackend).label)
                            AIIcon(.chevronDown, size: 10)
                        }.font(MuesliTheme.font(.caption))
                    }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Meeting AI provider")
                }
            }.padding(12)
            if let id = modelSettingID, let state = snapshot(id) {
                AIModelSelector(
                    choices: state.choices.map { .init(id: $0.id, title: $0.label, disabledReason: state.unavailable[$0.id]) },
                    selectedID: state.current,
                    currentTitle: state.current.isEmpty ? MeetingTextGenerationClient.model(appState.config) : state.current
                ) { value in apply(id, value: value) }
            } else {
                Text(MeetingTextGenerationClient.model(appState.config)).font(MuesliTheme.font(.callout)).padding(.horizontal, 16).padding(.bottom, 12)
            }
            if let thinking = snapshot("summary_thinking"), !thinking.choices.isEmpty {
                Divider()
                AIThinkingSlider(
                    choices: thinking.choices.map { .init(id: $0.id, title: $0.label, disabledReason: thinking.unavailable[$0.id]) },
                    selectedID: thinking.current
                ) { value in apply("summary_thinking", value: value) }
                    .id(appState.config.meetingSummaryBackend + ":" + MeetingTextGenerationClient.model(appState.config))
                    .padding(12)
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("Shared with meeting summaries")
                    .font(MuesliTheme.font(size: 10)).foregroundStyle(.secondary)
                Button {
                    openSettings()
                } label: { Label { Text("AI Settings…") } icon: { AIIcon(.slidersHorizontal) } }.buttonStyle(.borderless).font(MuesliTheme.font(.caption))
            }.padding(12)
        }.frame(width: 280)
    }

    private func openSettings() {
        dismiss()
        appState.selectedSettingsPane = .meetings
        appState.selectedTab = .settings
    }

    private func apply(_ id: String, value: String) {
        guard snapshot(id)?.current != value else { return }
        controller.setSettingFromUI(id, value: value)
    }
}
