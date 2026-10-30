import SwiftUI

/// Native Markdown responses with headings, lists, quotes, code, and GFM-style tables.
public struct AIResponse: View {
    private let markdown: String
    private let inlineContent: ((String) -> AttributedString)?
    @Environment(\.aiElementsTheme) private var theme

    /// Supply inlineContent to enforce host-specific link policies or render citations.
    /// Link activation follows SwiftUI's openURL environment. This view loads no remote media.
    public init(_ markdown: String, inlineContent: ((String) -> AttributedString)? = nil) {
        self.markdown = markdown
        self.inlineContent = inlineContent
    }

    private func attributed(_ text: String) -> AttributedString {
        if let inlineContent { return inlineContent(text) }
        return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    ScrollView(.horizontal) {
                        Text(code).font(.system(size: 12, design: .monospaced)).padding(12)
                    }.background(theme.surface, in: RoundedRectangle(cornerRadius: 8))
                case .line(let line):
                    lineView(line)
                case .table(let rows):
                    ScrollView(.horizontal) {
                        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                                GridRow {
                                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                        Text(attributed(cell))
                                            .font(theme.font(size: 13, weight: index == 0 ? .semibold : .regular))
                                            .frame(minWidth: 120, maxWidth: 240, alignment: .leading)
                                            .padding(10)
                                            .background(index == 0 ? theme.surface.opacity(0.7) : theme.surface)
                                            .overlay(Rectangle().stroke(theme.border, lineWidth: 0.5))
                                    }
                                }
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 8))
                    }.padding(.vertical, 4)
                }
            }
        }.lineSpacing(4).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [AIMarkdownBlock] { AIMarkdownBlock.parse(markdown) }

    @ViewBuilder private func lineView(_ raw: String) -> some View {
        let line = raw.trimmingCharacters(in: .whitespaces)
        let indent = min(raw.prefix { $0 == " " }.count / 2, 4)
        if line.isEmpty {
            Color.clear.frame(height: 5)
        } else if let heading = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            Text(attributed(String(line[heading.upperBound...])))
                .font(line.hasPrefix("# ") ? theme.heading : theme.subheading).padding(.top, 8)
        } else if let list = line.range(of: #"^(?:[-*+] \[[ xX]\] |[-*+] |\d+[.)]\s+)"#, options: .regularExpression) {
            let marker = String(line[..<list.upperBound]).trimmingCharacters(in: .whitespaces)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker.count == 1 ? "•" : marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                Text(attributed(String(line[list.upperBound...])))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.leading, CGFloat(indent) * 16)
        } else if line.hasPrefix("> ") {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(theme.border).frame(width: 3)
                Text(attributed(String(line.dropFirst(2)))).foregroundStyle(.secondary)
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
        } else {
            Text(attributed(raw)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
