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

    struct CombinationRules: Codable {
        let modifiers: [String]
        let keys: [String]
        let maximumModifiers: Int
        let valueFormat: String
    }

    var combinationRules: CombinationRules? {
        guard maximumModifiers > 0 else { return nil }
        return .init(modifiers: Self.modifiers.map(\.name), keys: availableKeyTokens.sorted(),
                     maximumModifiers: maximumModifiers,
                     valueFormat: self == .dictation
                        ? "Use modifier names in the supplied order, then a key: control+space. Shift alone cannot start a chord. Command alone requires a digit, space, arrow or function key. Bare modifiers use the listed key: values, including their side."
                        : "Join modifiers in listed order and one lowercase letter with +, e.g. control+k. Do not infer left/right for single modifier keys.")
    }

    static let singleKeys: [HotkeyConfig] = (UInt16(0)...127).compactMap { code in
        HotkeyConfig.label(for: code).map { HotkeyConfig(keyCode: code, label: $0) }
    }
    private static let modifiers: [(name: String, flags: NSEvent.ModifierFlags)] = [
        ("command", .command), ("control", .control), ("option", .option), ("shift", .shift)
    ]
    // Persisted hotkeys contain physical key codes. Tool values are a small,
    // deterministic vocabulary, independent of the user's input source.
    private static func token(for code: UInt16) -> String? {
        switch code {
        case 24: "equal"
        case 27: "minus"
        case 30: "right_bracket"
        case 33: "left_bracket"
        case 39: "quote"
        case 41: "semicolon"
        case 42: "backslash"
        case 43: "comma"
        case 44: "slash"
        case 47: "period"
        case 50: "grave"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        default: HotkeyConfig.keyLabel(for: code)?.lowercased()
        }
    }

    private static let codeByToken: [String: UInt16] = Dictionary(uniqueKeysWithValues:
        (UInt16(0)...127).compactMap { code in token(for: code).map { ($0, code) } })

    private var availableKeyTokens: [String] {
        Self.codeByToken.compactMap { name, code in
            if self == .dictation || HotkeyConfig.letterLabel(for: code) != nil { return name }
            return nil
        }
    }

    static func value(for hotkey: HotkeyConfig) -> String {
        guard hotkey.isCombination, let flags = hotkey.resolvedCombinationModifiers,
              let code = hotkey.combinationKeyCode, let name = token(for: code) else {
            return "key:\(hotkey.keyCode)"
        }
        return (modifiers.filter { flags.contains($0.flags) }.map(\.name) + [name]).joined(separator: "+")
    }

    func hotkey(for value: String) -> HotkeyConfig? {
        if let key = Self.singleKeys.first(where: { Self.value(for: $0) == value }) { return key }
        guard maximumModifiers > 0 else { return nil }
        let parts = value.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.count - 1 <= maximumModifiers,
              let name = parts.last, availableKeyTokens.contains(name),
              let code = Self.codeByToken[name] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for name in parts.dropLast() {
            guard let modifier = Self.modifiers.first(where: { $0.name == name }),
                  !flags.contains(modifier.flags) else { return nil }
            flags.insert(modifier.flags)
        }
        let key = HotkeyConfig.combination(modifiers: flags, keyCode: code)
        guard ShortcutHotkeyPolicy.allowsCombination(key, action: self) else { return nil }
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
