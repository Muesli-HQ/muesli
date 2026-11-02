import SwiftUI

/// A composition surface, independent of editor technology and request state.
/// Pass EmptyView for an unused header or footer. The host handles submission,
/// keyboard input, focus ownership, attachments, and text measurements.
public struct AIPromptInput<Header: View, Editor: View, Footer: View>: View {
    private let isFocused: Bool
    private let isCompact: Bool
    private let header: Header
    private let editor: Editor
    private let footer: Footer
    @Environment(\.aiElementsTheme) private var theme

    public init(
        isFocused: Bool = false,
        isCompact: Bool = false,
        @ViewBuilder header: () -> Header,
        @ViewBuilder editor: () -> Editor,
        @ViewBuilder footer: () -> Footer
    ) {
        self.isFocused = isFocused
        self.isCompact = isCompact
        self.header = header()
        self.editor = editor()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 0 : 6) {
            if !isCompact { header }
            editor
            if !isCompact { footer }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isCompact ? 4 : 14)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(isFocused ? theme.focus : theme.border, lineWidth: isFocused ? 2 : 1).allowsHitTesting(false))
    }
}
