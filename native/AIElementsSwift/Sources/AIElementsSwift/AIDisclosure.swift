import SwiftUI

/// Progressive disclosure for tool activity, provider summaries, or sources.
/// This component does not invent reasoning or infer execution state.
public struct AIDisclosure<Content: View>: View {
    private let title: String
    private let icon: AIIconName?
    private let content: Content
    @State private var isExpanded: Bool
    @Environment(\.aiElementsTheme) private var theme

    public init(
        title: String,
        icon: AIIconName? = nil,
        initiallyExpanded: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.content = content()
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content.padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                if let icon { AIIcon(icon, size: 13).accessibilityHidden(true) }
                Text(title).font(theme.font(size: 12, weight: .medium))
            }.foregroundStyle(theme.muted)
        }
        .disclosureGroupStyle(AIElementsDisclosureStyle())
    }
}

/// Shared Lucide trigger matching the upstream trailing-chevron disclosures.
struct AIElementsDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.aiElementsTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                    AIIcon(.chevronDown, size: 14)
                        .rotationEffect(.degrees(configuration.isExpanded ? 180 : 0))
                        .foregroundStyle(theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
