import Foundation

/// Turns a raw continuation into what Cotypist shows, or a reason to stay quiet:
///  - after a typed space the continuation must start a new word (its leading space is dropped);
///  - the first word's log-probability must clear the gate;
///  - later words are kept while their average token log-probability clears the trim threshold,
///    up to `maxWords`, stopping after a sentence end;
///  - a final word is kept only when known complete (the model moved on, or stopped by itself);
///  - with `heal`, the content starts with the half-typed word: tokens inside it were forced, so
///    their log-probabilities don't count, and the shown text is what follows it.
enum CotypistShaper {
    struct Thresholds {
        var firstWord = -3.0
        var trim = -2.5
        var maxWords = 6
    }

    struct Shaped: Equatable {
        let text: String
        let firstWordLogProb: Double
    }

    static func shape(_ completion: CotypistCompletion, afterSpace: Bool, heal: String?, maxTokens: Int,
                      firstWordOnly: Bool, thresholds: Thresholds = .init()) -> Result<Shaped, Rejection> {
        let tokens = completion.tokens
        if completion.stop == .healFailed { return .failure(.healFailed) }
        guard !tokens.isEmpty else { return .failure(.lineBreak) }
        let stoppedByModel = completion.stop == .endOfText || completion.stop == .newline || tokens.count < maxTokens
        var healLength = heal?.count ?? 0

        // Group tokens into words: a token starting with a space begins a new word.
        struct Word { var text = ""; var logprob = 0.0; var count = 0 }
        var words: [Word] = []
        var consumed = 0
        for token in tokens {
            if words.isEmpty || token.text.hasPrefix(" ") { words.append(Word()) }
            words[words.count - 1].text += token.text
            consumed += token.text.count
            if consumed <= healLength { continue }  // forced by the typed word, not the model's choice
            words[words.count - 1].logprob += token.logprob
            words[words.count - 1].count += 1
        }
        if healLength > 0 && consumed <= healLength { return .failure(.nothingBeyondTypedWord) }
        // A typed word the model left exactly as-is: the suggestion starts at the next word.
        if healLength > 0, words[0].count == 0, words.count > 1 {
            healLength -= words[0].text.count
            words.removeFirst()
        }
        if afterSpace && healLength == 0 && !words[0].text.hasPrefix(" ") {
            return .failure(.continuesPreviousWord)
        }
        let firstWordLogProb = words[0].logprob
        if firstWordLogProb < thresholds.firstWord { return .failure(.lowConfidence(firstWordLogProb)) }
        if firstWordOnly && words.count < 2 && !stoppedByModel { return .failure(.firstWordIncomplete) }

        var text = ""
        for (index, word) in words.prefix(firstWordOnly ? 1 : thresholds.maxWords).enumerated() {
            let isLast = index == words.count - 1
            // The last generated word may be cut off mid-word unless the model stopped by itself.
            if isLast && !stoppedByModel && index > 0 && !firstWordOnly { break }
            if index > 0 && word.logprob / Double(max(word.count, 1)) < thresholds.trim { break }
            text += word.text
            if let last = word.text.last, ".!?".contains(last) { break }
        }
        var shown = healLength > 0 ? String(text.dropFirst(healLength)) : text
        if afterSpace && healLength == 0 && shown.hasPrefix(" ") { shown.removeFirst() }
        guard !shown.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.empty) }
        return .success(Shaped(text: shown, firstWordLogProb: firstWordLogProb))
    }

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case lineBreak, healFailed, nothingBeyondTypedWord, continuesPreviousWord
        case lowConfidence(Double), firstWordIncomplete, empty

        var description: String {
            switch self {
            case .lineBreak: "model predicted a line break"
            case .healFailed: "no token continues the typed word"
            case .nothingBeyondTypedWord: "nothing beyond the typed word"
            case .continuesPreviousWord: "continues the previous word"
            case .lowConfidence(let logprob): String(format: "low confidence first word (%.2f)", logprob)
            case .firstWordIncomplete: "first word not complete yet"
            case .empty: "empty after trimming"
            }
        }
    }
}
