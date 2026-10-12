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
        choices.first { $0.id == selectedID }?.title ?? (selectedID.isEmpty ? "Unavailable" : selectedID)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.system(size: 13))
                Spacer()
                Text(valueLabel).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.muted)
            }
            Slider(value: Binding(get: { Double(selectedIndex ?? 0) }, set: { value in
                guard selectedIndex != nil,
                      let choice = AIThinkingScale.choice(at: value, in: available), choice.id != selectedID else { return }
                onSelect(choice.id)
            }), in: 0...Double(max(available.count - 1, 1)), step: 1)
                .tint(theme.accent)
                .disabled(available.count < 2 || selectedIndex == nil)
                .accessibilityLabel(title)
                .accessibilityValue(valueLabel)
            if available.count > 1 {
                HStack(spacing: 0) {
                    ForEach(Array(available.enumerated()), id: \.element.id) { index, _ in
                        if index > 0 { Spacer(minLength: 0) }
                        Rectangle().fill(theme.border).frame(width: 1, height: 4)
                    }
                }.padding(.horizontal, 8).accessibilityHidden(true)
                HStack {
                    Text(available.first?.title ?? "")
                    Spacer()
                    Text(available.last?.title ?? "")
                }.font(.system(size: 10)).foregroundStyle(theme.muted).accessibilityHidden(true)
            }
            if let reason = choices.first(where: { $0.id == selectedID })?.disabledReason {
                Text(reason).font(.system(size: 11)).foregroundStyle(theme.muted)
            }
        }
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
