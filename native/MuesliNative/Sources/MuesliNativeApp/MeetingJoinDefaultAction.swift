import Foundation

/// Which of the three join actions is armed on the primary button of the meeting
/// notification panel and the Coming Up row. The other two stay reachable through
/// the split button's dropdown, so this only changes which one needs a single click.
enum MeetingJoinDefaultAction: String, Codable, CaseIterable {
    case joinAndRecord = "join_and_record"
    case joinOnly = "join_only"
    case recordOnly = "record_only"

    /// Preserves the pre-setting behaviour for existing installs.
    static let fallback: MeetingJoinDefaultAction = .joinAndRecord

    /// Used both on the primary button and in the dropdown, so the armed action
    /// reads the same wherever it appears.
    var buttonLabel: String {
        switch self {
        case .joinAndRecord:
            return "Join & Transcribe"
        case .joinOnly:
            return "Join Only"
        case .recordOnly:
            return "Transcribe Only"
        }
    }

    var symbolName: String {
        switch self {
        case .joinAndRecord:
            return "video.fill"
        case .joinOnly:
            return "arrow.up.forward.app.fill"
        case .recordOnly:
            return "record.circle"
        }
    }

    /// Falls back to transcribe-only when the prompt has no join affordance — a
    /// calendar event without a meeting link can still be transcribed.
    func resolved(hasJoinAndRecord: Bool, hasJoinOnly: Bool) -> MeetingJoinDefaultAction {
        switch self {
        case .joinAndRecord:
            return hasJoinAndRecord ? .joinAndRecord : .recordOnly
        case .joinOnly:
            return hasJoinOnly ? .joinOnly : .recordOnly
        case .recordOnly:
            return .recordOnly
        }
    }

    /// Dropdown contents: every available action except the one already armed.
    /// Empty means there is nothing to drop down and the caller should render a
    /// plain single-action button.
    func availableAlternatives(hasJoinAndRecord: Bool, hasJoinOnly: Bool) -> [MeetingJoinDefaultAction] {
        let armed = resolved(hasJoinAndRecord: hasJoinAndRecord, hasJoinOnly: hasJoinOnly)
        return Self.allCases.filter { candidate in
            guard candidate != armed else { return false }
            switch candidate {
            case .joinAndRecord:
                return hasJoinAndRecord
            case .joinOnly:
                return hasJoinOnly
            case .recordOnly:
                return true
            }
        }
    }
}
