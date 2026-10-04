import AppKit
import Carbon

/// A recorded override is a physical chord; automatic paste resolves Command-V
/// from the foreground input layout at dispatch time. No global hotkey is registered.
struct PasteKeyChord: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: UInt64

    static let supportedModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    init?(keyCode: UInt16, modifiers: CGEventFlags) {
        guard keyCode < 128, ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode),
              !modifiers.intersection(Self.supportedModifiers).isEmpty,
              modifiers.subtracting(Self.supportedModifiers).isEmpty else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
    }

    var flags: CGEventFlags { CGEventFlags(rawValue: modifiers) }

    private enum CodingKeys: String, CodingKey { case keyCode = "key_code", modifiers }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let key = try values.decode(UInt16.self, forKey: .keyCode)
        let flags = CGEventFlags(rawValue: try values.decode(UInt64.self, forKey: .modifiers))
        guard let chord = Self(keyCode: key, modifiers: flags) else {
            throw DecodingError.dataCorruptedError(forKey: .keyCode, in: values, debugDescription: "Invalid paste chord")
        }
        self = chord
    }

    @MainActor var displayLabel: String {
        var label = ""
        if flags.contains(.maskControl) { label += "⌃" }
        if flags.contains(.maskAlternate) { label += "⌥" }
        if flags.contains(.maskShift) { label += "⇧" }
        if flags.contains(.maskCommand) { label += "⌘" }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc",
            76: "⌤", 114: "Help", 115: "Home", 116: "Page Up", 117: "⌦", 119: "End",
            121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        if let name = special[keyCode] { return label + name }
        // Ignore Control/Option for the legend (they can produce control/dead keys),
        // but honor Command layouts such as Dvorak-QWERTY Command.
        let legend = PasteKeyboardLayout.currentCharacter(keyCode: keyCode, flags: flags.intersection(.maskCommand))
        if let legend, !legend.isEmpty, legend.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return label + legend.uppercased()
        }
        return label + "Key \(keyCode)"
    }
}

enum PasteShortcut: Equatable, Sendable, Codable {
    case automatic
    case custom(PasteKeyChord)

    private enum CodingKeys: String, CodingKey { case mode, chord }

    init(from decoder: Decoder) throws {
        // Preserve the two values used by contributor PR #206's experimental builds.
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            self = legacy == "command_shift_v"
                ? .custom(PasteKeyChord(keyCode: 9, modifiers: [.maskCommand, .maskShift])!) : .automatic
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if try values.decode(String.self, forKey: .mode) == "custom" {
            self = .custom(try values.decode(PasteKeyChord.self, forKey: .chord))
        } else {
            self = .automatic
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic: try values.encode("automatic", forKey: .mode)
        case .custom(let chord):
            try values.encode("custom", forKey: .mode)
            try values.encode(chord, forKey: .chord)
        }
    }

    @MainActor var displayLabel: String {
        switch self {
        case .automatic: "Automatic (⌘V)"
        case .custom: chordLabel
        }
    }

    @MainActor var chordLabel: String {
        switch self {
        case .automatic: "⌘V"
        case .custom(let chord): chord.displayLabel
        }
    }
}

/// Inverts the system's layout tables once per paste (at most 128 translations).
/// Resolving at dispatch avoids stale caches when the user changes input sources
/// during transcription. UCKeyTranslate is needed here because there is no input
/// NSEvent to translate; we are generating a shortcut, not processing a keypress.
enum PasteKeyboardLayout {
    static func commandChord(
        for character: String,
        translate: (UInt16, CGEventFlags) -> String?
    ) -> PasteKeyChord? {
        for keyCode in UInt16(0)..<128 {
            if translate(keyCode, .maskCommand)?.caseInsensitiveCompare(character) == .orderedSame,
               let chord = PasteKeyChord(keyCode: keyCode, modifiers: .maskCommand) {
                return chord
            }
        }
        return nil
    }

    @MainActor static func resolve(_ shortcut: PasteShortcut) -> PasteKeyChord? {
        if case .custom(let chord) = shortcut { return chord }
        // An IME may not supply layout data. Its underlying ASCII-capable layout
        // is the fallback, never an assumed US physical V key.
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let chord = commandChord(for: "v", translate: { character(keyCode: $0, flags: $1, source: source) }) {
            return chord
        }
        guard let fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return commandChord(for: "v", translate: { character(keyCode: $0, flags: $1, source: fallback) })
    }

    @MainActor static func currentCharacter(keyCode: UInt16, flags: CGEventFlags) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return character(keyCode: keyCode, flags: flags, source: source)
    }

    static func character(keyCode: UInt16, flags: CGEventFlags, source: TISInputSource) -> String? {
        guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.maskCommand) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.maskControl) { carbonModifiers |= UInt32(controlKey) }
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), (carbonModifiers >> 8) & 0xff,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
            characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
