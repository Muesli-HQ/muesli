import AppKit

/// Shared by the key recorder and settings tools. Values describe keys, never code.
enum ShortcutAssignment: String, CaseIterable {
    case dictation, computerUse, quil, meetingRecording

    var settingID: String {
        switch self {
        case .dictation: "dictation_hotkey"
        case .computerUse: "cua_hotkey"
        case .quil: "quill_hotkey"
        case .meetingRecording: "meeting_hotkey"
        }
    }

    var label: String {
        switch self {
        case .dictation: "Dictation shortcut key"
        case .computerUse: "Computer use shortcut key"
        case .quil: "Quill shortcut key"
        case .meetingRecording: "Meeting recording shortcut key"
        }
    }

    var keyPath: KeyPath<AppConfig, HotkeyConfig> {
        switch self {
        case .dictation: \.dictationHotkey
        case .computerUse: \.computerUseHotkey
        case .quil: \.quilHotkey
        case .meetingRecording: \.meetingRecordingHotkey
        }
    }

    var maximumModifiers: Int {
        switch self {
        case .dictation, .computerUse: 0
        case .quil: 1
        case .meetingRecording: 4
        }
    }

    struct CombinationRules: Codable {
        let modifiers: [String]
        let letters: [String]
        let maximumModifiers: Int
        let valueFormat: String
    }

    var combinationRules: CombinationRules? {
        guard maximumModifiers > 0 else { return nil }
        return .init(modifiers: Self.modifiers.map(\.name), letters: Self.letters.map(\.name),
                     maximumModifiers: maximumModifiers,
                     valueFormat: "Join modifiers in listed order and one lowercase letter with +, e.g. control+k. Do not infer left/right for single modifier keys.")
    }

    static let singleKeys: [HotkeyConfig] = (UInt16(0)...127).compactMap { code in
        HotkeyConfig.label(for: code).map { HotkeyConfig(keyCode: code, label: $0) }
    }
    private static let modifiers: [(name: String, flags: NSEvent.ModifierFlags)] = [
        ("command", .command), ("control", .control), ("option", .option), ("shift", .shift)
    ]
    private static let letters: [(name: String, code: UInt16)] = (UInt16(0)...127).compactMap { code in
        HotkeyConfig.letterLabel(for: code).map { ($0.lowercased(), code) }
    }.sorted { $0.name < $1.name }

    static func value(for hotkey: HotkeyConfig) -> String {
        guard hotkey.isCombination, let flags = hotkey.resolvedCombinationModifiers,
              let code = hotkey.combinationKeyCode, let letter = HotkeyConfig.letterLabel(for: code) else {
            return "key:\(hotkey.keyCode)"
        }
        return (modifiers.filter { flags.contains($0.flags) }.map(\.name) + [letter.lowercased()]).joined(separator: "+")
    }

    func hotkey(for value: String) -> HotkeyConfig? {
        if let key = Self.singleKeys.first(where: { Self.value(for: $0) == value }) { return key }
        guard maximumModifiers > 0 else { return nil }
        let parts = value.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count - 1 <= maximumModifiers,
              let letter = Self.letters.first(where: { $0.name == parts.last }) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for name in parts.dropLast() {
            guard let modifier = Self.modifiers.first(where: { $0.name == name }),
                  !flags.contains(modifier.flags) else { return nil }
            flags.insert(modifier.flags)
        }
        let key = HotkeyConfig.combination(modifiers: flags, keyCode: letter.code)
        return Self.value(for: key) == value ? key : nil
    }

    @MainActor
    func update(_ hotkey: HotkeyConfig, controller: MuesliController) -> ShortcutHotkeyUpdateResult {
        switch self {
        case .dictation: controller.updateDictationHotkey(hotkey)
        case .computerUse: controller.updateComputerUseHotkey(hotkey)
        case .quil: controller.updateQuilHotkey(hotkey)
        case .meetingRecording: controller.updateMeetingRecordingHotkey(hotkey)
        }
    }
}
