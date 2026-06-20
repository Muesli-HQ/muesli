import SwiftUI
import MuesliCore

struct MeetingNotesView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                let lines = markdown.components(separatedBy: .newlines)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    markdownLine(line)
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing24)
            .padding(.vertical, MuesliTheme.spacing16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func markdownLine(_ rawLine: String) -> some View {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let indentLevel = Self.indentLevel(for: rawLine)
        if line.isEmpty {
            Color.clear
                .frame(height: MuesliTheme.spacing8)
        } else if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2)))
                .font(MuesliTheme.title1())
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.top, MuesliTheme.spacing8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3)))
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.top, MuesliTheme.spacing12)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4)))
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.top, MuesliTheme.spacing4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if line.hasPrefix("- [ ] ") {
            listRow(text: String(line.dropFirst(6)), indentLevel: indentLevel, systemImage: "square")
        } else if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
            listRow(text: String(line.dropFirst(6)), indentLevel: indentLevel, systemImage: "checkmark.square", iconColor: MuesliTheme.success)
        } else if line.hasPrefix("- ") {
            listRow(text: String(line.dropFirst(2)), indentLevel: indentLevel)
        } else if let numbered = Self.numberedListContent(from: line) {
            HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
                Text(numbered.marker)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 22, alignment: .trailing)
                Text(numbered.text)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indentLevel) * MuesliTheme.spacing20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if line.hasPrefix("**") && line.hasSuffix("**") {
            Text(String(line.dropFirst(2).dropLast(2)))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(line)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func listRow(
        text: String,
        indentLevel: Int,
        systemImage: String? = nil,
        iconColor: Color = MuesliTheme.textTertiary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MuesliTheme.spacing8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(iconColor)
                    .frame(width: 14, alignment: .center)
            } else {
                Circle()
                    .fill(MuesliTheme.textTertiary)
                    .frame(width: 4, height: 4)
                    .offset(y: -2)
                    .frame(width: 14, alignment: .center)
            }
            Text(text)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indentLevel) * MuesliTheme.spacing20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func indentLevel(for line: String) -> Int {
        let spaces = line.prefix { character in
            character == " " || character == "\t"
        }.reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        }
        return min(spaces / 2, 4)
    }

    private static func numberedListContent(from line: String) -> (marker: String, text: String)? {
        guard let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) else {
            return nil
        }
        let marker = line[..<line.index(before: range.upperBound)]
            .trimmingCharacters(in: .whitespaces)
        let text = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !marker.isEmpty, !text.isEmpty else { return nil }
        return (String(marker), text)
    }
}
