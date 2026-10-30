import AppIntents

@available(macOS 13.0, *)
enum MuesliShortcutsError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noDictations
    case noMeetings
    case notRunning

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noDictations: return "muesli has no dictations yet."
        case .noMeetings: return "muesli has no meetings yet."
        case .notRunning: return "muesli isn't running. Open muesli and try again."
        }
    }
}
