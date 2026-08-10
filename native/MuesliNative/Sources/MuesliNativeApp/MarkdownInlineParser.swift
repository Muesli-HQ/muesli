import Foundation

/// Parses one line of Markdown without allowing block-level structure to
/// change the surrounding notes layout.
enum MarkdownInlineParser {
    static func parse(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}
