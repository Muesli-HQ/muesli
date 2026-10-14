import SwiftUI

public enum AIMessageRole: Equatable, Sendable {
    case user
    case assistant
}

/// A message layout: a restrained surface for the user and flat assistant content.
/// Content, markdown parsing, identity labels, and message actions belong to the host.
public struct AIMessage<Content: View>: View {
    public let role: AIMessageRole
    private let content: Content
    @Environment(\.aiElementsTheme) private var theme

    public init(role: AIMessageRole, @ViewBuilder content: () -> Content) {
        self.role = role
        self.content = content()
    }

    public var body: some View {
        Group {
            if role == .user {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 24)
                    content
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
            } else {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
