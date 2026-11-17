import SwiftUI

/// A host-supplied, transient file preview. This component never reads files.
public struct AIAttachmentPreview: View {
    private let title: String
    private let detail: String
    private let icon: AIIconName
    private let preview: Image?
    private let showsPreview: Bool
    private let onRemove: (() -> Void)?
    @Environment(\.aiElementsTheme) private var theme

    public init(title: String, detail: String, icon: AIIconName = .fileText,
                preview: Image? = nil, showsPreview: Bool = true, onRemove: (() -> Void)? = nil) {
        self.title = title; self.detail = detail; self.icon = icon
        self.preview = preview; self.showsPreview = showsPreview; self.onRemove = onRemove
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsPreview {
                ZStack {
                    if let preview { preview.resizable().scaledToFit() }
                    else { AIIcon(icon, size: 28).foregroundStyle(theme.muted) }
                }
                .frame(width: 160, height: 96)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(theme.font(size: 13)).lineLimit(2)
                    Text(detail).font(theme.font(size: 12)).foregroundStyle(theme.muted).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let onRemove {
                    Button(action: onRemove) { AIIcon(.x, size: 11).frame(width: 20, height: 20) }
                        .buttonStyle(.plain).foregroundStyle(theme.muted)
                        .accessibilityLabel("Remove \(title)")
                }
            }
        }
        .frame(width: 160, alignment: .leading).padding(8)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(theme.border, lineWidth: 1).allowsHitTesting(false))
    }
}
