import SwiftUI

/// A compact removable context attachment. Removal semantics belong to the host.
public struct AIAttachment: View {
    private let title: String
    private let onRemove: () -> Void
    @Environment(\.aiElementsTheme) private var theme

    public init(title: String, onRemove: @escaping () -> Void) {
        self.title = title
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: 6) {
            AIIcon(.fileText, size: 12).foregroundStyle(theme.muted).accessibilityHidden(true)
            Text(title).font(theme.font(size: 12)).lineLimit(1)
            Button(action: onRemove) {
                AIIcon(.x, size: 11).foregroundStyle(theme.muted).frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.border, lineWidth: 1))
    }
}
