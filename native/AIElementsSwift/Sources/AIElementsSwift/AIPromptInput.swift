import SwiftUI

/// A composition surface, independent of editor technology and request state.
/// Pass EmptyView for an unused header or footer. The host handles submission,
/// keyboard input, focus ownership, attachments, and text measurements.
public struct AIPromptInput<Header: View, Editor: View, Footer: View>: View {
    private let isFocused: Bool
    private let header: Header
    private let editor: Editor
    private let footer: Footer
    @Environment(\.aiElementsTheme) private var theme

    public init(
        isFocused: Bool = false,
        @ViewBuilder header: () -> Header,
        @ViewBuilder editor: () -> Editor,
        @ViewBuilder footer: () -> Footer
    ) {
        self.isFocused = isFocused
        self.header = header()
        self.editor = editor()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            editor
            footer
        }
        .padding(14)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(isFocused ? theme.focus : theme.border, lineWidth: isFocused ? 2 : 1).allowsHitTesting(false))
    }
}
