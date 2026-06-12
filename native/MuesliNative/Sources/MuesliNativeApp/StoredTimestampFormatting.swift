import Foundation

enum StoredTimestampFormatting {
    static func displayDateTime(
        _ raw: String,
        timeZone: TimeZone = .current
    ) -> String {
        guard let date = parse(raw, timeZone: timeZone) else {
            return fallbackDisplayDateTime(raw)
        }
        return formatter(dateFormat: "yyyy-MM-dd HH:mm", timeZone: timeZone).string(from: date)
    }

    static func exportDateTime(
        _ raw: String,
        timeZone: TimeZone = .current
    ) -> String {
        guard let date = parse(raw, timeZone: timeZone) else {
            return fallbackExportDateTime(raw)
        }
        return formatter(dateFormat: "yyyy-MM-dd HH:mm:ss", timeZone: timeZone).string(from: date)
    }

    static func parse(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        isoParsers.lazy.compactMap { $0.date(from: raw) }.first
            ?? localParsers(timeZone: timeZone).lazy.compactMap { $0.date(from: raw) }.first
    }

    private static let isoParsers: [ISO8601DateFormatter] = {
        let iso1 = ISO8601DateFormatter()
        iso1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        iso2.formatOptions = [.withInternetDateTime]
        return [iso1, iso2]
    }()

    private static func localParsers(timeZone: TimeZone) -> [DateFormatter] {
        [
            formatter(dateFormat: "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", timeZone: timeZone),
            formatter(dateFormat: "yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone),
        ]
    }

    private static func formatter(dateFormat: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = dateFormat
        return formatter
    }

    private static func fallbackDisplayDateTime(_ raw: String) -> String {
        let clean = raw.replacingOccurrences(of: "T", with: " ")
        return clean.count > 16 ? String(clean.prefix(16)) : clean
    }

    private static func fallbackExportDateTime(_ raw: String) -> String {
        raw.replacingOccurrences(of: "T", with: " ")
            .components(separatedBy: ".").first ?? raw
    }
}
