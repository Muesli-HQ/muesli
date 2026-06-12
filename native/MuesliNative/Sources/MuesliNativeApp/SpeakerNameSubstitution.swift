import Foundation
import MuesliCore

/// Pure rewrite of a transcript blob's speaker labels to resolved display names,
/// for the *summarizer input only* — the stored blob keeps its `Speaker N`/`You`
/// tokens. Unmatched/suggested speakers stay `Speaker N` so unconfirmed guesses
/// never enter generated notes.
enum SpeakerNameSubstitution {
    static func substitute(
        transcript: String,
        speakers: [String: MeetingSpeaker],
        userName: String
    ) -> String {
        let normalized = transcript.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines
            .map { rewrite(line: $0, speakers: speakers, userName: userName) }
            .joined(separator: "\n")
    }

    private static func rewrite(line: String, speakers: [String: MeetingSpeaker], userName: String) -> String {
        // Split an optional "[timestamp] " prefix off the front.
        var prefix = ""
        var remainder = line
        if line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            let afterClose = line.index(after: close)
            prefix = String(line[..<afterClose])
            // Preserve the original spacing between the bracket and the label.
            var cursor = afterClose
            while cursor < line.endIndex, line[cursor] == " " {
                prefix.append(" ")
                cursor = line.index(after: cursor)
            }
            remainder = String(line[cursor...])
        }

        guard let colon = remainder.firstIndex(of: ":") else { return line }
        let label = String(remainder[..<colon]).trimmingCharacters(in: .whitespaces)
        guard isSpeakerLabel(label) else { return line }

        let resolved = SpeakerNameResolver.resolve(label: label, speakers: speakers, userName: userName)
        let body = String(remainder[colon...]) // includes the ":"
        return prefix + resolved.display + body
    }

    private static func isSpeakerLabel(_ label: String) -> Bool {
        if label.localizedCaseInsensitiveCompare("You") == .orderedSame { return true }
        if label.localizedCaseInsensitiveCompare("Others") == .orderedSame { return true }
        return SpeakerNameResolver.isSpeakerClusterLabel(label)
    }
}
