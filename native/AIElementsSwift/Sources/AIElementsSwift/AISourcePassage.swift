import SwiftUI

/// A passage within a source group. The caller supplies the original citation
/// number, readable metadata, a preview, and the action that opens the source.
public struct AISourcePassage: View {
    private let number: Int
    private let metadata: String
    private let preview: String
    private let action: () -> Void
    @Environment(\.aiElementsTheme) private var theme

    public init(number: Int, metadata: String, preview: String, action: @escaping () -> Void) {
        self.number = number
        self.metadata = metadata
        self.preview = preview
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)").font(.system(size: 11, design: .monospaced))
                    .frame(minWidth: 22, minHeight: 22)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.border, lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(metadata).font(theme.font(size: 11, weight: .medium)).foregroundStyle(theme.muted)
                    Text(preview).font(theme.font(size: 12)).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                AIIcon(.arrowUpRight, size: 12).foregroundStyle(theme.muted).accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open source passage")
    }
}
