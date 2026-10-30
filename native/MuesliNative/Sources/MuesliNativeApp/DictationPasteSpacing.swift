import Foundation

/// Presentation-only spacing for dictation paste. Recognition and saved text
/// remain unchanged, as do Quill and other verbatim paste callers.
enum DictationPasteSpacing {
    static func trailingSeparator(after text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return "" }
        var ending = text[...]
        while let character = ending.last, isClosingPunctuation(character) {
            ending.removeLast()
        }
        let content = ending.dropLast()
        guard let terminal = ending.last, matches(sentenceTerminal, terminal),
              let content = content.last(where: \.isLetter) ?? content.last(where: \.isNumber),
              !matches(unspacedScript, content) else { return "" }
        return " "
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        character == "\"" || character == "'" || character.unicodeScalars.allSatisfy {
            $0.properties.generalCategory == .closePunctuation || $0.properties.generalCategory == .finalPunctuation
        }
    }

    // Unicode properties cover Arabic question marks, Indic danda, etc. without
    // a model/language setting. Chinese/Japanese endings keep their native spacing.
    private static let sentenceTerminal = try! NSRegularExpression(pattern: #"[\p{Sentence_Terminal}…]"#)
    private static let unspacedScript = try! NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Bopomofo}]"#)

    private static func matches(_ expression: NSRegularExpression, _ character: Character) -> Bool {
        let text = String(character)
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
