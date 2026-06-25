import Foundation

struct ParsedTranscriptLine: Equatable {
    var startSeconds: Double
    var text: String
}

/// Parses a stored transcript whose lines may begin with `[HH:MM:SS]` or
/// `[MM:SS]`, optionally followed by a `You:` / `Others:` / `Speaker N:` label.
/// Lines without a leading timestamp are skipped (they carry no timing).
enum TranscriptTimestampParser {
    static func parse(_ transcript: String) -> [ParsedTranscriptLine] {
        var result: [ParsedTranscriptLine] = []
        for rawLine in transcript.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let inside = String(line[line.index(after: line.startIndex)..<close])
            guard let seconds = seconds(fromTimecode: inside) else { continue }
            var body = line[line.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
            body = stripSpeakerLabel(body)
            guard !body.isEmpty else { continue }
            result.append(ParsedTranscriptLine(startSeconds: seconds, text: body))
        }
        return result
    }

    /// Accepts "HH:MM:SS" or "MM:SS".
    static func seconds(fromTimecode raw: String) -> Double? {
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let ints = parts.compactMap { Int($0) }
        guard ints.count == parts.count else { return nil }
        if ints.count == 3 { return Double(ints[0] * 3600 + ints[1] * 60 + ints[2]) }
        return Double(ints[0] * 60 + ints[1])
    }

    private static func stripSpeakerLabel(_ text: String) -> String {
        guard let colon = text.firstIndex(of: ":") else { return text }
        let candidate = text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        let isLabel = candidate.localizedCaseInsensitiveCompare("You") == .orderedSame
            || candidate.localizedCaseInsensitiveCompare("Others") == .orderedSame
            || candidate.range(of: #"^Speaker\s+\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        guard isLabel else { return text }
        return text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
