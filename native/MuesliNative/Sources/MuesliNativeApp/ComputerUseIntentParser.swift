import Foundation

enum ComputerUseIntent: Equatable {
    case openApp(name: String)
    case focusApp(name: String)
    case click(label: String)
    case pressKey(ComputerUseKeyCommand)
    case typeText(String)
    case pasteText(String)
    case scroll(direction: ComputerUseScrollDirection, pages: Double)
}

enum ComputerUseScrollDirection: String, Codable, Equatable {
    case up
    case down
    case left
    case right
}

struct ComputerUseKeyCommand: Equatable {
    let modifiers: [ComputerUseKeyModifier]
    let key: String
}

enum ComputerUseKeyModifier: String, Codable, CaseIterable, Equatable {
    case command
    case option
    case control
    case shift
    case function
}

struct ParsedComputerUseIntent: Equatable {
    let intent: ComputerUseIntent
    let originalText: String
    let normalizedText: String
    let requiresConfirmation: Bool
}

enum ComputerUseIntentParser {
    private static let leadingPoliteWords = [
        "please",
        "can you",
        "could you",
        "would you",
    ]
    private static let invocationPrefixes = [
        "muesli",
        "computer",
        "computer use",
        "hey muesli",
        "okay muesli",
        "ok muesli",
    ]
    private static let clickPrefixes = [
        "click on",
        "click the",
        "click",
        "press the button",
        "press button",
        "tap on",
        "tap the",
        "tap",
    ]
    private static let riskyWords = [
        "archive",
        "buy",
        "cancel",
        "checkout",
        "confirm",
        "delete",
        "discard",
        "pay",
        "purchase",
        "remove",
        "send",
        "submit",
        "unsubscribe",
    ]

    static func parse(_ transcript: String) -> ParsedComputerUseIntent? {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return nil }

        let command = strippedCommandPrefix(from: normalized)
        guard !command.isEmpty else { return nil }

        if let intent = parseOpen(command) {
            return result(intent, transcript, normalized)
        }
        if let intent = parseFocus(command) {
            return result(intent, transcript, normalized)
        }
        if let intent = parseScroll(command) {
            return result(intent, transcript, normalized)
        }
        if let intent = parsePressKey(command) {
            return result(intent, transcript, normalized)
        }
        if let intent = parseType(command) {
            return result(intent, transcript, normalized)
        }
        if let intent = parsePaste(command) {
            return result(intent, transcript, normalized)
        }
        if let intent = parseClick(command) {
            return result(intent, transcript, normalized)
        }

        return nil
    }

    private static func parseOpen(_ command: String) -> ComputerUseIntent? {
        let prefixes = [
            "open the app",
            "open app",
            "open application",
            "open",
            "launch the app",
            "launch app",
            "launch application",
            "launch",
            "start the app",
            "start app",
            "start",
        ]
        guard let value = remainder(afterAny: prefixes, in: command) else { return nil }
        return .openApp(name: cleanedArgument(value))
    }

    private static func parseFocus(_ command: String) -> ComputerUseIntent? {
        let prefixes = [
            "focus on",
            "focus the app",
            "focus app",
            "focus application",
            "focus",
            "switch to",
            "bring up",
            "bring forward",
            "go to",
        ]
        guard let value = remainder(afterAny: prefixes, in: command) else { return nil }
        return .focusApp(name: cleanedArgument(value))
    }

    private static func parseClick(_ command: String) -> ComputerUseIntent? {
        guard let value = remainder(afterAny: clickPrefixes, in: command) else { return nil }
        return .click(label: cleanedElementLabel(value))
    }

    private static func parseType(_ command: String) -> ComputerUseIntent? {
        let prefixes = [
            "type out",
            "type in",
            "type",
            "write",
            "enter text",
            "enter",
        ]
        guard let value = remainder(afterAny: prefixes, in: command) else { return nil }
        return .typeText(cleanedFreeText(value))
    }

    private static func parsePaste(_ command: String) -> ComputerUseIntent? {
        let prefixes = [
            "paste in",
            "paste",
            "insert",
        ]
        guard let value = remainder(afterAny: prefixes, in: command) else { return nil }
        return .pasteText(cleanedFreeText(value))
    }

    private static func parseScroll(_ command: String) -> ComputerUseIntent? {
        let words = command.split(separator: " ").map(String.init)
        guard let scrollIndex = words.firstIndex(where: { $0 == "scroll" }) else { return nil }
        let tail = Array(words.dropFirst(scrollIndex + 1))
        guard let directionWord = tail.first(where: { ["up", "down", "left", "right"].contains($0) }),
              let direction = ComputerUseScrollDirection(rawValue: directionWord)
        else { return nil }

        let pages = pageCount(in: tail) ?? 1
        return .scroll(direction: direction, pages: pages)
    }

    private static func parsePressKey(_ command: String) -> ComputerUseIntent? {
        let prefixes = [
            "press",
            "hit",
            "keyboard",
        ]
        guard let value = remainder(afterAny: prefixes, in: command) else { return nil }
        let tokens = value
            .replacingOccurrences(of: "+", with: " ")
            .split(separator: " ")
            .map { normalizeKeyToken(String($0)) }
            .filter { !$0.isEmpty && $0 != "key" && $0 != "the" }
        guard !tokens.isEmpty else { return nil }

        var modifiers: [ComputerUseKeyModifier] = []
        var keyParts: [String] = []
        for token in tokens {
            if let modifier = modifier(for: token), !modifiers.contains(modifier) {
                modifiers.append(modifier)
            } else {
                keyParts.append(token)
            }
        }

        let key = keyParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return .pressKey(ComputerUseKeyCommand(modifiers: modifiers, key: key))
    }

    private static func result(
        _ intent: ComputerUseIntent,
        _ originalText: String,
        _ normalizedText: String
    ) -> ParsedComputerUseIntent {
        ParsedComputerUseIntent(
            intent: intent,
            originalText: originalText,
            normalizedText: normalizedText,
            requiresConfirmation: requiresConfirmation(intent)
        )
    }

    private static func normalize(_ text: String) -> String {
        let lowercased = text.lowercased()
        let scalars = lowercased.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return Character(scalar)
            }
            if scalar == "+" {
                return "+"
            }
            return " "
        }
        return collapseWhitespace(String(scalars))
    }

    private static func strippedCommandPrefix(from normalized: String) -> String {
        var command = normalized
        var changed = true
        while changed {
            changed = false
            for prefix in (invocationPrefixes + leadingPoliteWords).sorted(by: { $0.count > $1.count }) {
                if command == prefix {
                    return ""
                }
                if command.hasPrefix(prefix + " ") {
                    command = String(command.dropFirst(prefix.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        return command
    }

    private static func remainder(afterAny prefixes: [String], in command: String) -> String? {
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) {
            if command == prefix {
                return nil
            }
            if command.hasPrefix(prefix + " ") {
                let value = String(command.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func cleanedArgument(_ value: String) -> String {
        cleanedFreeText(value)
            .replacingOccurrences(of: #"^the "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" app$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedElementLabel(_ value: String) -> String {
        var label = cleanedFreeText(value)
        let suffixes = [" button", " link", " menu item", " field"]
        for suffix in suffixes where label.hasSuffix(suffix) {
            label = String(label.dropLast(suffix.count))
        }
        return label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedFreeText(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["the text", "text", "that says", "saying"] {
            if cleaned.hasPrefix(prefix + " ") {
                cleaned = String(cleaned.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return collapseWhitespace(cleaned)
    }

    private static func pageCount(in words: [String]) -> Double? {
        for (index, word) in words.enumerated() {
            guard word == "page" || word == "pages" else { continue }
            guard index > 0 else { return 1 }
            return numericValue(words[index - 1]) ?? 1
        }
        return nil
    }

    private static func numericValue(_ word: String) -> Double? {
        if let value = Double(word) {
            return value
        }
        switch word {
        case "one", "a", "an": return 1
        case "two": return 2
        case "three": return 3
        case "four": return 4
        case "five": return 5
        case "half": return 0.5
        default: return nil
        }
    }

    private static func normalizeKeyToken(_ token: String) -> String {
        switch token {
        case "cmd", "command": return "command"
        case "ctrl", "control": return "control"
        case "alt", "option": return "option"
        case "fn", "function": return "function"
        case "esc": return "escape"
        case "return": return "enter"
        default: return token
        }
    }

    private static func modifier(for token: String) -> ComputerUseKeyModifier? {
        switch token {
        case "command": return .command
        case "option": return .option
        case "control": return .control
        case "shift": return .shift
        case "function": return .function
        default: return nil
        }
    }

    private static func requiresConfirmation(_ intent: ComputerUseIntent) -> Bool {
        switch intent {
        case .click(let label):
            return containsRiskyWord(label)
        case .pressKey(let command):
            return command.modifiers.contains(.command) && ["q", "w"].contains(command.key)
        default:
            return false
        }
    }

    private static func containsRiskyWord(_ text: String) -> Bool {
        let words = Set(text.split(separator: " ").map(String.init))
        return riskyWords.contains { words.contains($0) }
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
