import Foundation

enum MenuBarMeetingTitleFormatter {
    static let defaultMaxLength = 30

    static func title(
        for eventTitle: String,
        startDate: Date,
        maxLength: Int = defaultMaxLength,
        timeZone: TimeZone = .current
    ) -> String {
        let startTime = startTimeString(from: startDate, timeZone: timeZone)
        let suffix = " · \(startTime)"
        let compactTitle = compact(eventTitle)
        let title = compactTitle.isEmpty ? "Meeting" : compactTitle
        let titleLimit = max(1, maxLength - suffix.count - 1)
        return " \(truncated(title, limit: titleLimit))\(suffix)"
    }

    private static func startTimeString(from date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func compact(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return "…" }
        return String(text.prefix(limit - 1))
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
