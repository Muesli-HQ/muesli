import Foundation

/// Local Markdown block parsing. No HTML execution or external resource loading.
public enum AIMarkdownBlock: Equatable, Sendable {
    case line(String)
    case code(String)
    case table([[String]])

    public static func parse(_ markdown: String) -> [Self] {
        let lines = markdown.components(separatedBy: .newlines)
        var result: [Self] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = openingFence(line) {
                index += 1
                var code: [String] = []
                while index < lines.count && !closesFence(lines[index], character: fence.character, length: fence.length) {
                    code.append(lines[index]); index += 1
                }
                result.append(.code(code.joined(separator: "\n")))
                if index < lines.count { index += 1 }
                continue
            }
            if index + 1 < lines.count, line.contains("|"),
               let header = tableCells(line), let separators = tableCells(lines[index + 1]),
               header.count == separators.count,
               separators.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) {
                var rows = [header]
                index += 2
                while index < lines.count, lines[index].contains("|"),
                      let cells = tableCells(lines[index]), cells.count == header.count {
                    rows.append(cells); index += 1
                }
                result.append(.table(rows))
                continue
            }
            result.append(.line(line)); index += 1
        }
        return result
    }

    private static func openingFence(_ line: String) -> (character: Character, length: Int)? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, first == "`" || first == "~" else { return nil }
        let length = text.prefix(while: { $0 == first }).count
        guard length >= 3 else { return nil }
        return (first, length)
    }

    private static func closesFence(_ line: String, character: Character, length: Int) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        let count = text.prefix(while: { $0 == character }).count
        return count >= length && text.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func tableCells(_ line: String) -> [String]? {
        let text = line.trimmingCharacters(in: .whitespaces)
        let characters = Array(text)
        var cells: [String] = []; var cell = ""; var index = 0
        var inlineFence: Int?; var delimiters = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                let next = characters[index + 1]
                if next != "|" { cell.append("\\") }
                cell.append(next); index += 2; continue
            }
            if character == "`" {
                var count = 1
                while index + count < characters.count && characters[index + count] == "`" { count += 1 }
                if inlineFence == count { inlineFence = nil }
                else if inlineFence == nil { inlineFence = count }
                cell += String(repeating: "`", count: count); index += count; continue
            }
            if character == "|", inlineFence == nil {
                cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = ""; delimiters += 1
            } else { cell.append(character) }
            index += 1
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        guard delimiters > 0 else { return nil }
        if text.hasPrefix("|"), cells.first == "" { cells.removeFirst() }
        if text.hasSuffix("|"), cells.last == "", cells.count > 1 { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }
}
