import SwiftUI

/// Settings UI and CUA consume the same definition; no separate voice binding.
/// A new finite setting needs only its definition and a control with that ID.
struct MuesliSettingControl: View {
    let controller: MuesliController
    let id: String
    var allowedChoiceIDs: Set<String>? = nil
    @Environment(\.muesliSettingDefinitions) private var definitions
    @State private var errorMessage: String?
    @State private var isApplying = false

    var body: some View {
        Group {
            if let setting = definitions.first(where: { $0.id == id }) {
                let state = filteredSnapshot(setting)
                if Set(state.choices.map(\.id)) == ["on", "off"] {
                    HStack {
                        if state.current == "off", state.unavailable["on"] != nil,
                           let requestPermission = setting.requestPermission {
                            Button("Grant access", action: requestPermission)
                                .help(state.unavailable["on"] ?? "Grant the required permissions")
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { state.current == "on" }, set: { apply($0 ? "on" : "off") }))
                            .toggleStyle(.switch)
                            .tint(MuesliTheme.accent)
                            .labelsHidden()
                            .accessibilityLabel(state.label)
                            .disabled(state.unavailable[state.current == "on" ? "off" : "on"] != nil)
                            .help(state.unavailable[state.current == "on" ? "off" : "on"] ?? state.label)
                    }
                } else if setting.presentation == .discreteSlider, !state.choices.isEmpty {
                    let index = state.choices.firstIndex { $0.id == state.current } ?? 0
                    HStack(spacing: 12) {
                        Slider(value: Binding(get: { Double(index) }, set: { value in
                            let next = min(max(Int(value.rounded()), 0), state.choices.count - 1)
                            apply(state.choices[next].id)
                        }), in: 0...Double(max(state.choices.count - 1, 1)), step: 1)
                            .tint(MuesliTheme.accent)
                            .accessibilityLabel(state.label)
                            .accessibilityValue(state.choices[index].label)
                            .disabled(state.choices.count < 2)
                        Text(state.choices[index].label)
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    .frame(height: 24)
                } else {
                    let selected = state.choices.first { $0.id == state.current }?.label ?? state.current
                    // Preserve custom/current values without manufacturing a selectable option.
                    let hasCurrent = state.choices.contains { $0.id == state.current }
                    let placeholder = selected.isEmpty ? "Choose an option…" : selected
                    let labels = (hasCurrent ? [] : [placeholder]) + state.choices.map(\.label)
                    FixedWidthPopUp(selection: hasCurrent ? selected : placeholder, options: labels,
                        disabledOptions: Set(state.choices.filter { state.unavailable[$0.id] != nil }.map(\.label))
                            .union(hasCurrent ? [] : [placeholder]), onSelectIndex: { index in
                            let choiceIndex = index - (hasCurrent ? 0 : 1)
                            guard state.choices.indices.contains(choiceIndex) else { return }
                            apply(state.choices[choiceIndex].id)
                        })
                        .frame(height: 24)
                        .accessibilityLabel(state.label)
                        .disabled(state.choices.isEmpty)
                }
            } else {
                Text("Setting unavailable").foregroundStyle(.secondary)
            }
        }
        .disabled(isApplying)
        .alert("Setting could not be changed", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }

    private func filteredSnapshot(_ setting: MuesliSetting) -> MuesliSetting.Snapshot {
        let state = setting.snapshot(config: controller.appState.config)
        guard let allowedChoiceIDs else { return state }
        return .init(id: state.id, label: state.label, current: state.current,
            choices: state.choices.filter { allowedChoiceIDs.contains($0.id) }, unavailable: state.unavailable)
    }

    private func apply(_ value: String) {
        isApplying = true
        Task { @MainActor in
            defer { isApplying = false }
            do { try await controller.applySetting(id, value: value) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct MuesliSettingDefinitionsKey: EnvironmentKey {
    static let defaultValue: [MuesliSetting] = []
}
extension EnvironmentValues {
    var muesliSettingDefinitions: [MuesliSetting] {
        get { self[MuesliSettingDefinitionsKey.self] }
        set { self[MuesliSettingDefinitionsKey.self] = newValue }
    }
}
