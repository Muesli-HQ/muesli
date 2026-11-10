import SwiftUI
import MuesliCore

extension MeetingStatus {
    var displayLabel: String {
        switch self {
        case .recording:
            return "Recording"
        case .processing:
            return "Processing"
        case .completed:
            return "Completed"
        case .noteOnly:
            return "Note only"
        case .failed:
            return "Needs attention"
        }
    }

    var displayColor: Color {
        switch self {
        case .recording:
            return MuesliTheme.recording
        case .processing:
            return MuesliTheme.accent
        case .completed:
            return MuesliTheme.success
        case .noteOnly:
            return MuesliTheme.textTertiary
        case .failed:
            return MuesliTheme.transcribing
        }
    }

    /// Status pill text; `displayColor` remains the dot and tint color.
    var displayTextColor: Color {
        switch self {
        case .recording:
            return MuesliTheme.destructiveText
        case .processing:
            return MuesliTheme.accentText
        case .completed:
            return MuesliTheme.successText
        case .noteOnly:
            return MuesliTheme.textTertiary
        case .failed:
            return MuesliTheme.warningText
        }
    }
}
