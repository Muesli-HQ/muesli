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
        case .computerUse: 0
        case .quil: 1
        case .dictation, .meetingRecording: 4
        }
    }

    /// The single rule for which modifier-plus-key combinations each shortcut accepts.
    func acceptsCombination(_ hotkey: HotkeyConfig) -> Bool {
        switch self {
        case .dictation: hotkey.isValidDictationShortcut
        case .quil: ShortcutHotkeyPolicy.isValidQuilShortcut(hotkey)
        case .meetingRecording: hotkey.combinationKeyCode.flatMap(HotkeyConfig.letterLabel(for:)) != nil
        case .computerUse: false
        }
    }

    struct CombinationRules: Codable {
        let modifiers: [String]
        let keys: [String]
        let maximumModifiers: Int
        let valueFormat: String
    }

    var combinationRules: CombinationRules? {
        guard maximumModifiers > 0 else { return nil }
        let singleModifierNote = "Do not infer left/right for single modifier keys."
        let valueFormat = switch self {
        case .dictation:
            "Join modifiers in listed order and one listed key with +, e.g. control+space. Shift cannot be the only modifier, and command alone works only with digits, space, arrows, and function keys. \(singleModifierNote)"
        default:
            "Join modifiers in listed order and one listed key with +, e.g. control+k. \(singleModifierNote)"
        }
        return .init(modifiers: Self.modifiers.map(\.name), keys: combinationKeys.map(\.name),
                     maximumModifiers: maximumModifiers, valueFormat: valueFormat)
    }

    private var combinationKeys: [(name: String, code: UInt16)] {
        self == .dictation ? Self.keys : Self.keys.filter { HotkeyConfig.letterLabel(for: $0.code) != nil }
    }

    static let singleKeys: [HotkeyConfig] = (UInt16(0)...127).compactMap { code in
        HotkeyConfig.label(for: code).map { HotkeyConfig(keyCode: code, label: $0) }
    }
    private static let modifiers: [(name: String, flags: NSEvent.ModifierFlags)] = [
        ("command", .command), ("control", .control), ("option", .option), ("shift", .shift)
    ]
    /// Value names for every key that can anchor a combination; symbols get spelled-out names.
    private static let keys: [(name: String, code: UInt16)] = (UInt16(0)...127).compactMap { code in
        HotkeyConfig.keyLabel(for: code).map { (symbolNames[$0] ?? $0.lowercased(), code) }
    }.sorted { $0.name < $1.name }
    private static let symbolNames: [String: String] = [
        "=": "equal", "-": "minus", "[": "left_bracket", "]": "right_bracket", "\\": "backslash",
        ";": "semicolon", "'": "quote", ",": "comma", ".": "period", "/": "slash", "`": "grave",
        "←": "left", "→": "right", "↓": "down", "↑": "up",
    ]

    static func value(for hotkey: HotkeyConfig) -> String {
        guard hotkey.isCombination, let flags = hotkey.resolvedCombinationModifiers,
              let code = hotkey.combinationKeyCode, let key = keys.first(where: { $0.code == code }) else {
            return "key:\(hotkey.keyCode)"
        }
        return (modifiers.filter { flags.contains($0.flags) }.map(\.name) + [key.name]).joined(separator: "+")
    }

    func hotkey(for value: String) -> HotkeyConfig? {
        if let key = Self.singleKeys.first(where: { Self.value(for: $0) == value }) { return key }
        guard maximumModifiers > 0 else { return nil }
        let parts = value.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count - 1 <= maximumModifiers,
              let key = combinationKeys.first(where: { $0.name == parts.last }) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for name in parts.dropLast() {
            guard let modifier = Self.modifiers.first(where: { $0.name == name }),
                  !flags.contains(modifier.flags) else { return nil }
            flags.insert(modifier.flags)
        }
        let hotkey = HotkeyConfig.combination(modifiers: flags, keyCode: key.code)
        return Self.value(for: hotkey) == value && acceptsCombination(hotkey) ? hotkey : nil
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
