import AppIntents

@available(macOS 13.0, *)
enum MuesliShortcutsError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noDictations
    case noMeetings
    case notRunning

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noDictations: return "Muesli has no dictations yet."
        case .noMeetings: return "Muesli has no meetings yet."
        case .notRunning: return "Muesli isn't running. Open Muesli and try again."
        }
    }
}
