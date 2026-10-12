import SwiftUI

public struct AIModelChoice: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let disabledReason: String?

    public init(id: String, title: String, disabledReason: String? = nil) {
        self.id = id
        self.title = title
        self.disabledReason = disabledReason
    }
}

/// Catalog-driven model rows. Unknown current models remain visible without
/// manufacturing an option that the host has not authorized.
public struct AIModelSelector: View {
    private let choices: [AIModelChoice]
    private let selectedID: String
    private let currentTitle: String?
    private let onSelect: (String) -> Void
    @Environment(\.aiElementsTheme) private var theme

    public init(choices: [AIModelChoice], selectedID: String, currentTitle: String? = nil,
                onSelect: @escaping (String) -> Void) {
        self.choices = choices
        self.selectedID = selectedID
        self.currentTitle = currentTitle
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if !choices.contains(where: { $0.id == selectedID }) {
                    VStack(alignment: .leading, spacing: 4) {
                        row(title: currentTitle ?? selectedID, selected: true)
                        Text("Current custom model").font(.system(size: 11)).foregroundStyle(theme.muted)
                            .padding(.horizontal, 16).padding(.bottom, 8)
                    }
                }
                ForEach(choices) { choice in
                    Button {
                        guard choice.disabledReason == nil else { return }
                        onSelect(choice.id)
                    } label: {
                        row(title: choice.title, selected: choice.id == selectedID)
                    }
                    .buttonStyle(.plain)
                    .disabled(choice.disabledReason != nil)
                    .help(choice.disabledReason ?? choice.title)
                    .accessibilityAddTraits(choice.id == selectedID ? .isSelected : [])
                }
            }
        }.frame(maxHeight: 280)
    }

    private func row(title: String, selected: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            if selected { AIIcon(.check, size: 12).accessibilityHidden(true) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
        .background(selected ? theme.surface : Color.clear)
    }
}
