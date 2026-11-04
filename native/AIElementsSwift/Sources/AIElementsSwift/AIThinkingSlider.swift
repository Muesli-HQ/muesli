import SwiftUI

public struct AIThinkingChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let disabledReason: String?

    public init(id: String, title: String, disabledReason: String? = nil) {
        self.id = id
        self.title = title
        self.disabledReason = disabledReason
    }
}

/// Discrete positions come exclusively from the host's supported choices.
/// The host remains responsible for validating the selected ID at mutation time.
public struct AIThinkingSlider: View {
    private let title: String
    private let choices: [AIThinkingChoice]
    private let selectedID: String
    private let onSelect: (String) -> Void
    @Environment(\.aiElementsTheme) private var theme
    @State private var drag = AIThinkingDragState()

    public init(title: String = "Thinking level", choices: [AIThinkingChoice], selectedID: String,
                onSelect: @escaping (String) -> Void) {
        self.title = title
        self.choices = choices
        self.selectedID = selectedID
        self.onSelect = onSelect
    }

    private var available: [AIThinkingChoice] { AIThinkingScale.available(choices) }
    private var selectedIndex: Int? { available.firstIndex { $0.id == selectedID } }
    private var valueLabel: String {
        if let position = drag.position, let choice = AIThinkingScale.choice(at: position, in: available) { return choice.title }
        return choices.first { $0.id == selectedID }?.title ?? (selectedID.isEmpty ? "Unavailable" : selectedID)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(theme.font(size: 13))
                Spacer()
                Text(valueLabel).font(theme.font(size: 12, weight: .medium)).foregroundStyle(theme.muted)
            }
            Slider(value: Binding(get: { drag.position ?? Double(selectedIndex ?? 0) }, set: { value in
                guard selectedIndex != nil else { return }
                if let value = drag.update(value, choices: available, selectedID: selectedID) { onSelect(value) }
            }), in: 0...Double(max(available.count - 1, 1)), step: 1, onEditingChanged: { editing in
                if editing { drag.begin(at: Double(selectedIndex ?? 0)) }
                else if let value = drag.finish(choices: available, selectedID: selectedID) { onSelect(value) }
            })
                .tint(theme.accent)
                .disabled(available.count < 2 || selectedIndex == nil)
                .accessibilityLabel(title)
                .accessibilityValue(valueLabel)
            if available.count > 1 {
                HStack {
                    Text(available.first?.title ?? "")
                    Spacer()
                    Text(available.last?.title ?? "")
                }.font(theme.font(size: 10)).foregroundStyle(theme.muted).accessibilityHidden(true)
            }
            if let reason = choices.first(where: { $0.id == selectedID })?.disabledReason {
                Text(reason).font(theme.font(size: 11)).foregroundStyle(theme.muted)
            }
        }
        .onChange(of: choices) { _, _ in drag.cancel() }
        .onChange(of: selectedID) { _, _ in drag.cancel() }
    }
}

/// Interaction state deliberately keeps drag updates out of persistence callbacks.
/// Keyboard/accessibility steps, which need not start a drag, commit individually.
struct AIThinkingDragState {
    private(set) var isEditing = false
    private(set) var position: Double?

    mutating func begin(at position: Double) {
        isEditing = true
        self.position = position
    }

    mutating func update(_ position: Double, choices: [AIThinkingChoice], selectedID: String) -> String? {
        guard let choice = AIThinkingScale.choice(at: position, in: choices) else { return nil }
        if isEditing { self.position = position; return nil }
        return choice.id == selectedID ? nil : choice.id
    }

    mutating func finish(choices: [AIThinkingChoice], selectedID: String) -> String? {
        defer { cancel() }
        guard isEditing, let position,
              let choice = AIThinkingScale.choice(at: position, in: choices), choice.id != selectedID else { return nil }
        return choice.id
    }

    mutating func cancel() {
        isEditing = false
        position = nil
    }
}

/// Kept separate from rendering so unsupported levels and malformed positions
/// cannot accidentally map to a model setting.
enum AIThinkingScale {
    static func available(_ choices: [AIThinkingChoice]) -> [AIThinkingChoice] {
        choices.filter { $0.disabledReason == nil }
    }

    static func choice(at position: Double, in choices: [AIThinkingChoice]) -> AIThinkingChoice? {
        guard position.isFinite, !choices.isEmpty else { return nil }
        let index = Int(min(Double(choices.count - 1), max(0, position.rounded())))
        let choice = choices[index]
        return choice.disabledReason == nil ? choice : nil
    }
}
