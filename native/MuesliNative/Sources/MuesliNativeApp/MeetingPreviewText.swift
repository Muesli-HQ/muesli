import Foundation

enum MeetingPreviewText {
    static func snippet(from source: String, limit: Int = 88) -> String {
        let compact = plainText(from: source)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !compact.isEmpty else { return "No notes yet" }
        guard compact.count > limit else { return compact }

        let prefixCount = max(0, limit - 3)
        return String(compact.prefix(prefixCount)) + "..."
    }

    static func noteSnippet(from source: String, limit: Int = 112) -> String {
        let compact = notePlainText(from: source)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !compact.isEmpty else { return "No notes yet" }
        guard compact.count > limit else { return compact }

        let prefixCount = max(0, limit - 3)
        return String(compact.prefix(prefixCount)) + "..."
    }

    static func plainText(from markdown: String) -> String {
        var lines: [String] = []
        var isInsideFence = false

        for rawLine in markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                isInsideFence.toggle()
                continue
            }
            guard !isInsideFence else { continue }

            if line.range(of: #"^\s{0,3}[-*_]{3,}\s*$"#, options: .regularExpression) != nil ||
                line.range(of: #"^\s{0,3}[=-]{3,}\s*$"#, options: .regularExpression) != nil {
                continue
            }

            line = line.replacingOccurrences(
                of: #"^\s{0,3}#{1,6}\s*"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"^\s*>+\s*"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"^\s*(?:[-+*]|\d+[.)])\s+"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"^\s*\[[ xX]\]\s+"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"!\[([^\]]*)\]\([^)]+\)"#,
                with: "$1",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"\[([^\]]+)\]\([^)]+\)"#,
                with: "$1",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"`([^`\n]+)`"#,
                with: "$1",
                options: .regularExpression
            )
            line = stripMarkdownDelimiters(from: line)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if !line.isEmpty {
                lines.append(line)
            }
        }

        return lines.joined(separator: " ")
    }

    static func notePlainText(from markdown: String) -> String {
        var lines: [String] = []
        var isInsideFence = false
        var isInsideSkippedSection = false

        for rawLine in markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                isInsideFence.toggle()
                continue
            }
            guard !isInsideFence else { continue }

            if line.range(of: #"^\s{0,3}[-*_]{3,}\s*$"#, options: .regularExpression) != nil ||
                line.range(of: #"^\s{0,3}[=-]{3,}\s*$"#, options: .regularExpression) != nil {
                continue
            }

            if let heading = headingTitle(from: line) {
                let normalized = MeetingListItemMetadata.normalizedHeading(heading)
                isInsideSkippedSection = skippedSectionHeadings.contains(normalized)
                if isInsideSkippedSection || genericNoteHeadings.contains(normalized) {
                    continue
                }
            } else if isInsideSkippedSection {
                continue
            }

            line = line.replacingOccurrences(
                of: #"^\s{0,3}#{1,6}\s*"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"^\s*>+\s*"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"^\s*(?:[-+*]|\d+[.)])\s+"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"^\s*\[[ xX]\]\s+"#,
                with: "",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"!\[([^\]]*)\]\([^)]+\)"#,
                with: "$1",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"\[([^\]]+)\]\([^)]+\)"#,
                with: "$1",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"`([^`\n]+)`"#,
                with: "$1",
                options: .regularExpression
            )
            line = stripMarkdownDelimiters(from: line)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if !line.isEmpty {
                lines.append(line)
            }
        }

        return lines.joined(separator: " ")
    }

    private static func headingTitle(from line: String) -> String? {
        guard line.range(of: #"^\s{0,3}#{1,6}\s+"#, options: .regularExpression) != nil else {
            return nil
        }
        return line.replacingOccurrences(
            of: #"^\s{0,3}#{1,6}\s*"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let genericNoteHeadings: Set<String> = [
        "meeting summary",
        "summary",
        "key discussion points",
        "discussion points",
        "decisions",
        "decisions made",
        "action items",
        "notable quotes",
        "raw transcript"
    ]

    private static let skippedSectionHeadings: Set<String> = [
        "attendees",
        "participants",
        "invitees",
        "people",
        "source",
        "source trail"
    ]

    private static func stripMarkdownDelimiters(from text: String) -> String {
        var result = text
        let replacements = [
            (#"\*\*([^*\n]+)\*\*"#, "$1"),
            (#"__([^_\n]+)__"#, "$1"),
            (#"~~([^~\n]+)~~"#, "$1"),
            (#"(^|[\s(\[{])\*([^*\n]+)\*($|[\s)\]}.,;:!?])"#, "$1$2$3"),
            (#"(^|[\s(\[{])_([^_\n]+)_($|[\s)\]}.,;:!?])"#, "$1$2$3")
        ]

        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        return result
    }
}
