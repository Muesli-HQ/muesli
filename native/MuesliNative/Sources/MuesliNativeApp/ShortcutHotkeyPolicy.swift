import AppKit

enum ShortcutHotkeyUpdateResult: Equatable {
    case updated(notice: String?)
    case conflict(message: String)
    case unavailable(message: String)

    var message: String? {
        switch self {
        case .updated(let notice):
            return notice
        case .conflict(let message), .unavailable(let message):
            return message
        }
    }

    var didUpdate: Bool {
        switch self {
        case .updated:
            return true
        case .conflict, .unavailable:
            return false
        }
    }

    static var updated: ShortcutHotkeyUpdateResult {
        .updated(notice: nil)
    }
}

struct ShortcutHotkeyPolicy {
    /// Shared validation for physical recording and settings-tool values.
    /// Moved from the signed shortcut-recorder foundation.
    static func allowsCombination(_ hotkey: HotkeyConfig, action: ShortcutAssignment) -> Bool {
        switch action {
        case .dictation:
            return hotkey.isValidDictationShortcut
        case .quil:
            return isValidQuilShortcut(hotkey)
        case .meetingRecording:
            return hotkey.combinationKeyCode.flatMap(HotkeyConfig.letterLabel(for:)) != nil
        case .computerUse:
            return false
        }
    }

    static func dictationActivationUnavailableReason(
        state: DictationState,
        hasHotkeySession: Bool,
        isCapturingShortcut: Bool
    ) -> String? {
        guard state == .idle, !hasHotkeySession, !isCapturingShortcut else {
            return "Finish dictation or shortcut recording before changing activation."
        }
        return nil
    }

    static func conflictMessage(with action: String, hotkey: HotkeyConfig) -> String {
        "This shortcut overlaps with \(action) (\(hotkey.displayLabel)). Choose a different shortcut."
    }

    private static func conflict(with action: String, hotkey: HotkeyConfig) -> ShortcutHotkeyUpdateResult {
        .conflict(message: conflictMessage(with: action, hotkey: hotkey))
    }
    static let commonGlobalShortcutWarning = "This shortcut is commonly used by other apps. Muesli listens globally, so choose a less common combination if it conflicts with your workflow."
    static let commandSpaceWarning = "Command-Space may already open Spotlight or switch input sources. Choose another shortcut, or change the conflicting shortcut in System Settings > Keyboard > Keyboard Shortcuts."
    static let quilKeyCountMessage = "Quill supports one key or a two-key shortcut."
    static let pasteConflictMessage = "Muesli uses this shortcut to paste. Choose a different shortcut."
    static let dictationShortcutMessage = "Use a modifier key, or add Control, Option, or Shift. Command alone works only with digits, Space, arrows, and function keys."

    static func isValidQuilShortcut(_ hotkey: HotkeyConfig) -> Bool {
        guard hotkey.isCombination else { return HotkeyConfig.label(for: hotkey.keyCode) != nil }
        guard let modifiers = hotkey.resolvedCombinationModifiers,
              hotkey.combinationKeyCode.flatMap(HotkeyConfig.letterLabel(for:)) != nil else { return false }
        return [NSEvent.ModifierFlags.command, .control, .option, .shift]
            .filter { modifiers.contains($0) }
            .count == 1
    }

    static func validateQuilHotkey(
        _ hotkey: HotkeyConfig,
        dictationHotkey: HotkeyConfig,
        computerUseHotkey: HotkeyConfig,
        isComputerUseEnabled: Bool,
        meetingRecordingHotkey: HotkeyConfig,
        isMeetingRecordingEnabled: Bool
    ) -> ShortcutHotkeyUpdateResult {
        guard isValidQuilShortcut(hotkey) else { return .conflict(message: quilKeyCountMessage) }
        if hotkeysConflict(hotkey, dictationHotkey) {
            return conflict(with: "Dictation", hotkey: dictationHotkey)
        }
        if isComputerUseEnabled && hotkeysConflict(hotkey, computerUseHotkey) {
            return conflict(with: "Computer Use Command", hotkey: computerUseHotkey)
        }
        if isMeetingRecordingEnabled && hotkeysConflict(hotkey, meetingRecordingHotkey) {
            return conflict(with: "Meeting Recording", hotkey: meetingRecordingHotkey)
        }
        return .updated(notice: commonGlobalShortcutWarning(for: hotkey))
    }

    static func hotkeysConflict(_ a: HotkeyConfig, _ b: HotkeyConfig) -> Bool {
        if a.isCombination != b.isCombination {
            let bare = a.isCombination ? b : a
            let chord = a.isCombination ? a : b
            guard let modifier = modifierFlag(for: bare.keyCode),
                  let modifiers = chord.resolvedCombinationModifiers else { return false }
            // Chords are side-independent, so either physical Control key, for
            // example, overlaps a chord containing Control.
            return modifiers.contains(modifier)
        }
        if a.isCombination {
            guard a.combinationKeyCode == b.combinationKeyCode,
                  let lhs = a.resolvedCombinationModifiers,
                  let rhs = b.resolvedCombinationModifiers else { return false }
            // Ctrl-D and Ctrl-Shift-D can trigger in sequence as modifiers are
            // added; sharing only a modifier with a different base key is safe.
            return lhs.isSubset(of: rhs) || rhs.isSubset(of: lhs)
        }
        return a.keyCode == b.keyCode
    }

    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        default: return nil
        }
    }

    static func validateDictationHotkey(
        _ hotkey: HotkeyConfig,
        computerUseHotkey: HotkeyConfig,
        isComputerUseEnabled: Bool,
        meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault,
        isMeetingRecordingEnabled: Bool = false
    ) -> ShortcutHotkeyUpdateResult {
        guard hotkey.isValidDictationShortcut else {
            return .conflict(message: dictationShortcutMessage)
        }
        if isComputerUseEnabled && hotkeysConflict(hotkey, computerUseHotkey) {
            return conflict(with: "Computer Use Command", hotkey: computerUseHotkey)
        }
        if isMeetingRecordingEnabled && hotkeysConflict(hotkey, meetingRecordingHotkey) {
            return conflict(with: "Meeting Recording", hotkey: meetingRecordingHotkey)
        }
        return .updated(notice: commonGlobalShortcutWarning(for: hotkey))
    }

    static func validateComputerUseHotkey(
        _ hotkey: HotkeyConfig,
        dictationHotkey: HotkeyConfig,
        isComputerUseEnabled: Bool,
        meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault,
        isMeetingRecordingEnabled: Bool = false
    ) -> ShortcutHotkeyUpdateResult {
        if hotkeysConflict(hotkey, dictationHotkey) {
            return conflict(with: "Dictation", hotkey: dictationHotkey)
        }
        if isMeetingRecordingEnabled && hotkeysConflict(hotkey, meetingRecordingHotkey) {
            return conflict(with: "Meeting Recording", hotkey: meetingRecordingHotkey)
        }
        return .updated
    }

    static func validateMeetingRecordingHotkey(
        _ hotkey: HotkeyConfig,
        dictationHotkey: HotkeyConfig,
        computerUseHotkey: HotkeyConfig,
        isComputerUseEnabled: Bool
    ) -> ShortcutHotkeyUpdateResult {
        if hotkeysConflict(hotkey, dictationHotkey) {
            return conflict(with: "Dictation", hotkey: dictationHotkey)
        }
        if isComputerUseEnabled && hotkeysConflict(hotkey, computerUseHotkey) {
            return conflict(with: "Computer Use Command", hotkey: computerUseHotkey)
        }
        return .updated(notice: commonGlobalShortcutWarning(for: hotkey))
    }

    static func commonGlobalShortcutWarning(for hotkey: HotkeyConfig) -> String? {
        guard hotkey.isCombination,
              let modifiers = hotkey.resolvedCombinationModifiers,
              let keyCode = hotkey.combinationKeyCode else { return nil }

        if modifiers == .command, keyCode == 49 { return commandSpaceWarning }

        let commonAppShortcuts: Set<HotkeySignature> = [
            HotkeySignature(modifiers: [.command], keyCode: 12), // Cmd+Q
            HotkeySignature(modifiers: [.command], keyCode: 13), // Cmd+W
            HotkeySignature(modifiers: [.command], keyCode: 15), // Cmd+R
            HotkeySignature(modifiers: [.command, .shift], keyCode: 15), // Cmd+Shift+R
        ]
        let signature = HotkeySignature(modifiers: modifiers, keyCode: keyCode)
        return commonAppShortcuts.contains(signature) ? commonGlobalShortcutWarning : nil
    }

    static func resolvedComputerUseHotkeyWhenEnabling(
        currentHotkey: HotkeyConfig,
        dictationHotkey: HotkeyConfig,
        meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault,
        isMeetingRecordingEnabled: Bool = false
    ) -> (hotkey: HotkeyConfig, result: ShortcutHotkeyUpdateResult) {
        (currentHotkey, validateComputerUseHotkey(
            currentHotkey,
            dictationHotkey: dictationHotkey,
            isComputerUseEnabled: true,
            meetingRecordingHotkey: meetingRecordingHotkey,
            isMeetingRecordingEnabled: isMeetingRecordingEnabled
        ))
    }

    private struct HotkeySignature: Hashable {
        let modifiersRawValue: UInt
        let keyCode: UInt16

        init(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) {
            self.modifiersRawValue = UInt(HotkeyConfig.supportedCombinationModifiers(from: modifiers).rawValue)
            self.keyCode = keyCode
        }
    }
}
