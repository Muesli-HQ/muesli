import AppKit

enum ShortcutHotkeyUpdateResult: Equatable {
    case updated(notice: String?)
    case conflict(message: String)

    var message: String? {
        switch self {
        case .updated(let notice):
            return notice
        case .conflict(let message):
            return message
        }
    }

    var didUpdate: Bool {
        switch self {
        case .updated:
            return true
        case .conflict:
            return false
        }
    }

    static var updated: ShortcutHotkeyUpdateResult {
        .updated(notice: nil)
    }
}

struct ShortcutHotkeyPolicy {
    static let conflictMessage = "These shortcuts need different keys."
    static let commonGlobalShortcutWarning = "This shortcut is commonly used by other apps. Muesli listens globally, so choose a less common combination if it conflicts with your workflow."

    static func hotkeysConflict(_ a: HotkeyConfig, _ b: HotkeyConfig) -> Bool {
        if a.isCombination != b.isCombination { return false }
        if a.isCombination {
            return normalizedCombinationModifiers(a) == normalizedCombinationModifiers(b)
                && a.combinationKeyCode == b.combinationKeyCode
        }
        return a.keyCode == b.keyCode
    }

    private static func normalizedCombinationModifiers(_ hotkey: HotkeyConfig) -> UInt? {
        hotkey.resolvedCombinationModifiers.map { UInt($0.rawValue) }
    }

    static func validateDictationHotkey(
        _ hotkey: HotkeyConfig,
        computerUseHotkey: HotkeyConfig,
        isComputerUseEnabled: Bool,
        meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault,
        isMeetingRecordingEnabled: Bool = false
    ) -> ShortcutHotkeyUpdateResult {
        if isComputerUseEnabled && hotkeysConflict(hotkey, computerUseHotkey) {
            return .conflict(message: conflictMessage)
        }
        if isMeetingRecordingEnabled && hotkeysConflict(hotkey, meetingRecordingHotkey) {
            return .conflict(message: conflictMessage)
        }
        return .updated
    }

    static func validateComputerUseHotkey(
        _ hotkey: HotkeyConfig,
        dictationHotkey: HotkeyConfig,
        isComputerUseEnabled: Bool,
        meetingRecordingHotkey: HotkeyConfig = .meetingRecordingDefault,
        isMeetingRecordingEnabled: Bool = false
    ) -> ShortcutHotkeyUpdateResult {
        if isComputerUseEnabled && hotkeysConflict(hotkey, dictationHotkey) {
            return .conflict(message: conflictMessage)
        }
        if isMeetingRecordingEnabled && hotkeysConflict(hotkey, meetingRecordingHotkey) {
            return .conflict(message: conflictMessage)
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
            return .conflict(message: conflictMessage)
        }
        if isComputerUseEnabled && hotkeysConflict(hotkey, computerUseHotkey) {
            return .conflict(message: conflictMessage)
        }
        return .updated(notice: commonGlobalShortcutWarning(for: hotkey))
    }

    static func commonGlobalShortcutWarning(for hotkey: HotkeyConfig) -> String? {
        guard hotkey.isCombination,
              let modifiers = hotkey.resolvedCombinationModifiers,
              let keyCode = hotkey.combinationKeyCode else { return nil }

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
        var resolved = currentHotkey
        var notice: String?

        if hotkeysConflict(resolved, dictationHotkey) {
            resolved = HotkeyConfig.computerUseDefault(avoiding: dictationHotkey)
            notice = "Computer Use Command moved to \(resolved.label) to avoid matching Push to Talk."
        }
        if isMeetingRecordingEnabled && hotkeysConflict(resolved, meetingRecordingHotkey) {
            let fallback = HotkeyConfig.computerUseDefault(avoiding: dictationHotkey)
            if hotkeysConflict(fallback, dictationHotkey)
                || hotkeysConflict(fallback, meetingRecordingHotkey) {
                return (currentHotkey, .conflict(message: conflictMessage))
            }
            resolved = fallback
            notice = "Computer Use Command moved to \(resolved.label) to avoid matching Meeting Recording."
        }
        return (resolved, .updated(notice: notice))
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
