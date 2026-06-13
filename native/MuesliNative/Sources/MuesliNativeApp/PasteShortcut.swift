import Foundation

/// The keyboard chord Muesli simulates to paste dictated text into the focused app.
///
/// Muesli inserts dictation by writing the transcript to the clipboard and posting a
/// synthetic paste keystroke. Most apps treat ⌘V as paste, but terminals and editors
/// that remap ⌘V (e.g. a Ghostty config binding `cmd+v` to a control character and
/// moving paste to `cmd+shift+v`) drop the default chord. Picking the chord that
/// matches the target app's paste binding keeps insertion reliable.
enum PasteShortcut: String, Codable, CaseIterable {
    case commandV = "command_v"
    case commandShiftV = "command_shift_v"

    var displayName: String {
        switch self {
        case .commandV: return "⌘V (default)"
        case .commandShiftV: return "⌘⇧V"
        }
    }
}
