import Foundation
import MuesliCore

struct MeetingListParticipant: Equatable {
    let name: String?
    let email: String?

    var listLabel: String {
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let cleanName, !cleanName.isEmpty, let cleanEmail, !cleanEmail.isEmpty {
            return "\(cleanName) <\(cleanEmail)>"
        }
        if let cleanName, !cleanName.isEmpty { return cleanName }
        return cleanEmail ?? ""
    }
}

enum MeetingListItemMetadata {
    static func friendlyDate(
        _ raw: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard let date = parseStoredTimestamp(raw, timeZone: calendar.timeZone) else {
            return fallbackDate(raw)
        }

        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            day = monthDayFormatter(calendar: calendar).string(from: date)
        } else {
            day = monthDayYearFormatter(calendar: calendar).string(from: date)
        }

        return "\(day), \(timeFormatter(calendar: calendar).string(from: date))"
    }

    static func participantLine(from record: MeetingRecord, limit: Int = 2) -> String? {
        let participants = participants(from: record.formattedNotes)
        guard !participants.isEmpty else { return nil }

        let shown = participants.prefix(limit).map(\.listLabel).filter { !$0.isEmpty }
        guard !shown.isEmpty else { return nil }

        let remaining = participants.count - shown.count
        if remaining > 0 {
            return "\(shown.joined(separator: ", ")) +\(remaining) more"
        }
        return shown.joined(separator: ", ")
    }

    static func fullParticipantLine(from record: MeetingRecord) -> String? {
        let participants = participants(from: record.formattedNotes)
        let labels = participants.map(\.listLabel).filter { !$0.isEmpty }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    static func participants(from markdown: String) -> [MeetingListParticipant] {
        var results: [MeetingListParticipant] = []
        var seen = Set<String>()
        var isInParticipantSection = false

        for rawLine in markdown.normalizedMarkdownLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let heading = headingTitle(from: trimmed) {
                let normalized = normalizedHeading(heading)
                isInParticipantSection = ["attendees", "participants", "invitees", "people"].contains(normalized)
                continue
            }

            guard isInParticipantSection else { continue }
            guard let participant = participant(from: trimmed) else { continue }

            let key = (participant.email ?? participant.name ?? participant.listLabel).lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }

            seen.insert(key)
            results.append(participant)
        }

        return results
    }

    static func notesPreview(from record: MeetingRecord, limit: Int = 112) -> String {
        let source: String
        if !record.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           record.status != .completed {
            source = record.manualNotes
        } else {
            source = record.formattedNotes.isEmpty ? record.rawTranscript : record.formattedNotes
        }
        return MeetingPreviewText.noteSnippet(from: source, limit: limit)
    }

    private static func participant(from rawLine: String) -> MeetingListParticipant? {
        let hasListMarker = rawLine.range(
            of: #"^\s*(?:[-+*]|\d+[.)]|\[[ xX]\])\s+"#,
            options: .regularExpression
        ) != nil
        let email = firstEmail(in: rawLine)
        guard hasListMarker || email != nil else { return nil }

        let line = rawLine
            .replacingOccurrences(of: #"^\s*(?:[-+*]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*\[[ xX]\]\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty else { return nil }
        guard !isParticipantPlaceholder(line) else { return nil }

        var name = line
        if let email {
            name = name.replacingOccurrences(of: email, with: "")
        }
        name = name
            .replacingOccurrences(of: #"[<>]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-–—:;,."))

        if name.isEmpty, email == nil { return nil }
        return MeetingListParticipant(name: name.isEmpty ? nil : name, email: email)
    }

    private static func isParticipantPlaceholder(_ line: String) -> Bool {
        let normalized = line
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "none",
            "na",
            "no attendees",
            "no attendees captured",
            "no participants",
            "no participants captured",
            "no invitees",
            "no invitees captured"
        ].contains(normalized)
    }

    private static func firstEmail(in line: String) -> String? {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let range = line.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return String(line[range])
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

    static func normalizedHeading(_ heading: String) -> String {
        heading
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9 ]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackDate(_ raw: String) -> String {
        let clean = raw
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: "")
        return clean.count > 16 ? String(clean.prefix(16)) : clean
    }

    private static func parseStoredTimestamp(_ raw: String, timeZone: TimeZone) -> Date? {
        isoParsers.lazy.compactMap { $0.date(from: raw) }.first
            ?? localParsers(timeZone: timeZone).lazy.compactMap { $0.date(from: raw) }.first
    }

    private static let isoParsers: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return [fractional, wholeSeconds]
    }()

    private static func localParsers(timeZone: TimeZone) -> [DateFormatter] {
        [
            formatter(calendar: .current, dateFormat: "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", timeZone: timeZone),
            formatter(calendar: .current, dateFormat: "yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone),
        ]
    }

    private static func timeFormatter(calendar: Calendar) -> DateFormatter {
        formatter(calendar: calendar, dateFormat: "h:mm a")
    }

    private static func monthDayFormatter(calendar: Calendar) -> DateFormatter {
        formatter(calendar: calendar, dateFormat: "MMM d")
    }

    private static func monthDayYearFormatter(calendar: Calendar) -> DateFormatter {
        formatter(calendar: calendar, dateFormat: "MMM d, yyyy")
    }

    private static func formatter(calendar: Calendar, dateFormat: String) -> DateFormatter {
        formatter(calendar: calendar, dateFormat: dateFormat, timeZone: calendar.timeZone)
    }

    private static func formatter(calendar: Calendar, dateFormat: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return formatter
    }
}

private extension String {
    var normalizedMarkdownLines: [String] {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}
