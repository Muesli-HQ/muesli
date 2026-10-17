import Foundation
import MuesliCore

enum MeetingPreviewText {
    static func transcriptSearchField(rawTranscript: String, matching query: String) -> String? {
        let readableTranscript = MeetingSpeakerState.modelFacingTranscript(rawTranscript)
        let normalizedQuery = query.lowercased()
        guard readableTranscript.lowercased().contains(normalizedQuery)
                || rawTranscript.lowercased().contains(normalizedQuery) else { return nil }
        return plainText(from: rawTranscript)
    }

    static func snippet(from source: String, limit: Int = 88) -> String {
        let compact = plainText(from: source)
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

        for rawLine in MeetingSpeakerState.modelFacingTranscript(markdown)
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
