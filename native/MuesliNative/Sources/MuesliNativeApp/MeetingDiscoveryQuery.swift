import CoreFoundation
import Foundation
import MuesliCore

/// Structured arguments supplied by the model. Dates are Gregorian civil days on the user's Mac.
struct MeetingDiscoveryQuery: Equatable, Sendable {
    let title: String
    let from: Date?
    let until: Date?
    let limit: Int

    let restrictToLatest: Bool

    init(_ fields: [String: Any], timeZone: TimeZone = .current, restrictToLatest: Bool = false) throws {
        self.restrictToLatest = restrictToLatest
        guard Set(fields.keys) == ["tool", "title", "from", "until", "limit"],
              fields["title"] is NSNull || fields["title"] is String,
              let n = fields["limit"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.stringValue == String(n.intValue), (1...10).contains(n.intValue) else { throw MeetingChatError.invalidResponse }
        title = (fields["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count <= 200 else { throw MeetingChatError.invalidResponse }
        limit = n.intValue
        let range = try LocalChatDateRange(fields, timeZone: timeZone)
        from = range.from
        until = range.until
    }

    func intersecting(_ scope: MeetingChatScope) -> MeetingChatScope? {
        var result = scope
        if let from { result.startDate = max(scope.startDate ?? from, from) }
        if let until { result.endDateExclusive = min(scope.endDateExclusive ?? until, until) }
        if let start = result.startDate, let end = result.endDateExclusive, end <= start { return nil }
        return result
    }
    var detail: String {
        [title, from?.ISO8601Format() ?? "", until?.ISO8601Format() ?? "", "limit \(limit)"].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct LocalChatDateRange {
    let from: Date?
    let until: Date?
    init(_ fields: [String: Any], timeZone: TimeZone = .current) throws {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd"
        format.isLenient = false
        func day(_ key: String) throws -> Date? {
            if fields[key] is NSNull { return nil }
            guard let value = fields[key] as? String, value.utf8.count == 10,
                  let date = format.date(from: value), format.string(from: date) == value else { throw MeetingChatError.invalidResponse }
            return date
        }
        from = try day("from")
        until = try day("until")
        if let from, let until, from >= until { throw MeetingChatError.invalidResponse }
    }
}
