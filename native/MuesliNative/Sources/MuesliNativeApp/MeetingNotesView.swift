import SwiftUI
import MuesliCore
import ImageIO
import AIElementsSwift

struct MeetingNotesView: View {
    let markdown: String
    var highlightedRange: NSRange? = nil
    var footer: AnyView? = nil

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                let blocks = Self.blocks(markdown)
                ForEach(blocks, id: \.start) { block in
                    Group {
                        if let rows = block.table { markdownTable(rows) }
                        else { markdownLine(block.line) }
                    }
                        .background(highlightedLine.map { block.start <= $0 && $0 < block.start + block.count } == true ? MuesliTheme.surfaceSelected : Color.clear)
                        .id(block.start)
                }
                if let footer { footer.padding(.top, MuesliTheme.spacing24) }
            }
            .frame(maxWidth: MuesliTheme.readingWidth, alignment: .leading)
            .padding(.horizontal, MuesliTheme.spacing24)
            .padding(.vertical, MuesliTheme.spacing16)
            .frame(maxWidth: .infinity, alignment: .center)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if let line = highlightedBlock { proxy.scrollTo(line, anchor: .center) } }
        .onChange(of: highlightedRange) { _, _ in if let line = highlightedBlock { proxy.scrollTo(line, anchor: .center) } }
        }
    }
    private var highlightedBlock: Int? {
        guard let line = highlightedLine else { return nil }
        return Self.blocks(markdown).first { $0.start <= line && line < $0.start + $0.count }?.start
    }

    struct NoteBlock {
        let start: Int
        let count: Int
        let line: String
        let table: [[String]]?
    }

    static func blocks(_ markdown: String) -> [NoteBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [NoteBlock] = []
        var index = 0
        var fence: (Character, Int)?
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, first == "`" || first == "~" {
                let length = trimmed.prefix { $0 == first }.count
                if length >= 3 {
                    if let open = fence, open.0 == first, length >= open.1,
                       trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    else if fence == nil { fence = (first, length) }
                }
            }
            if fence == nil, let table = AIMarkdownBlock.table(in: lines, startingAt: index) {
                result.append(NoteBlock(start: index, count: table.lineCount, line: "", table: table.rows))
                index += table.lineCount
            } else {
                result.append(NoteBlock(start: index, count: 1, line: lines[index], table: nil))
                index += 1
            }
        }
        return result
    }

    private func markdownTable(_ rows: [[String]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { row, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell))
                                .font(MuesliTheme.font(size: 14, weight: row == 0 ? .semibold : .regular))
                                .foregroundStyle(MuesliTheme.textPrimary)
                                .frame(minWidth: 110, maxWidth: 240, alignment: .leading)
                                .padding(10)
                                .background(row == 0 ? MuesliTheme.surfaceSelected : MuesliTheme.surfacePrimary)
                                .overlay(Rectangle().stroke(MuesliTheme.surfaceBorder, lineWidth: 0.5))
                        }
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .padding(.vertical, 4)
    }
    private var highlightedLine: Int? {
        guard let range = highlightedRange, range.location >= 0, range.location <= (markdown as NSString).length else { return nil }
        return (markdown as NSString).substring(to: range.location).components(separatedBy: .newlines).count - 1
    }

    @ViewBuilder
    private func markdownLine(_ rawLine: String) -> some View {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        let indentLevel = Self.indentLevel(for: rawLine)
        let references = MeetingNoteImages.references(in: rawLine)
        if !references.isEmpty {
            let parts = Self.imageParts(rawLine, references: references)
            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let text):
                        if !text.isEmpty {
                            Text(Self.inline(text)).font(MuesliTheme.reading()).foregroundStyle(MuesliTheme.textPrimary)
                        }
                    case .image(let id, let width):
                        MeetingNoteImageView(id: id, width: width)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else if line.isEmpty {
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
                    .font(MuesliTheme.reading())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 22, alignment: .trailing)
                Text(Self.inline(numbered.text))
                    .font(MuesliTheme.reading())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(indentLevel) * MuesliTheme.spacing20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(Self.inline(line))
                .font(MuesliTheme.reading())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private enum ImagePart {
        case text(String)
        case image(UUID, Int?)
    }

    private static func imageParts(_ line: String, references: [MeetingNoteImages.Reference]) -> [ImagePart] {
        let source = line as NSString
        var offset = 0
        var parts: [ImagePart] = []
        for reference in references {
            if reference.range.location > offset {
                parts.append(.text(source.substring(with: NSRange(location: offset, length: reference.range.location - offset))))
            }
            parts.append(.image(reference.id, reference.width))
            offset = reference.range.upperBound
        }
        if offset < source.length { parts.append(.text(source.substring(from: offset))) }
        return parts
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
            Text(Self.inline(text))
                .font(MuesliTheme.reading())
                .foregroundStyle(MuesliTheme.textPrimary)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indentLevel) * MuesliTheme.spacing20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Renders inline markdown — bold, italic, code, links — within one line.
    ///
    /// Block structure (headings, lists, checkboxes) is matched by
    /// `markdownLine`, so parsing is inline-only: a stray `#` or `-` in body
    /// text stays literal instead of being re-read as a block marker. Text that
    /// fails to parse falls back to itself, so notes always render.
    static func inline(_ text: String) -> AttributedString {
        MarkdownInlineParser.parse(text)
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

private struct MeetingNoteImageView: View {
    let id: UUID
    let width: Int?
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: min(CGFloat(width ?? 500), image.size.width), alignment: .leading)
                    .accessibilityLabel("Meeting note image")
            } else if loaded {
                Label("Image unavailable on this device", systemImage: "photo")
                    .font(MuesliTheme.font(.caption)).foregroundStyle(MuesliTheme.textTertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: id) {
            let thumbnail = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(MeetingNoteImages.url(for: id) as CFURL,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0,
                    [kCGImageSourceCreateThumbnailFromImageAlways: true,
                     kCGImageSourceThumbnailMaxPixelSize: 1000,
                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            image = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            loaded = true
        }
    }
}
