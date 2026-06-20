import Foundation

enum ScheduledMeetingNotificationLeadTime: String, Codable, CaseIterable {
    case atStart = "at_start"
    case oneMinute = "one_minute"
    case threeMinutes = "three_minutes"
    case fiveMinutes = "five_minutes"

    var seconds: TimeInterval {
        switch self {
        case .atStart:
            return 0
        case .oneMinute:
            return 60
        case .threeMinutes:
            return 3 * 60
        case .fiveMinutes:
            return 5 * 60
        }
    }
}
