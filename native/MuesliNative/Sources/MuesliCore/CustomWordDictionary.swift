import Foundation

/// Portable import/export support for Muesli's personal dictionary.
///
/// The portable format is a JSON array of `{word, replacement,
/// matching_threshold}` objects. The decoder also accepts an app `config.json`
/// object containing the same array under `custom_words`, which makes the
/// dictionary usable from both the app and `muesli-cli` without duplicating
/// format handling.
public enum CustomWordDictionaryCodec {
    public struct MergeResult: Equatable {
        public let words: [CustomWord]
        public let addedCount: Int
        public let updatedCount: Int
        public let skippedCount: Int

        public init(words: [CustomWord], addedCount: Int, updatedCount: Int, skippedCount: Int) {
            self.words = words
            self.addedCount = addedCount
            self.updatedCount = updatedCount
            self.skippedCount = skippedCount
        }
    }

    public enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidFormat

        public var errorDescription: String? {
            "The file is not a valid Muesli dictionary."
        }
    }

    /// Decodes either a portable dictionary array or an app `config.json`.
    public static func decode(_ data: Data) throws -> [CustomWord] {
        let decoder = JSONDecoder()
        if let words = try? decoder.decode([CustomWord].self, from: data) {
            return words
        }

        if let config = try? decoder.decode(ConfigShape.self, from: data) {
            return config.customWords
        }

        throw Error.invalidFormat
    }

    /// Encodes a portable dictionary array without app-specific IDs.
    public static func encode(_ words: [CustomWord]) throws -> Data {
        let portableWords = words.map(PortableCustomWord.init)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(portableWords)
        data.append(Data("\n".utf8))
        return data
    }

    /// Merges imported entries into the current dictionary by normalized match
    /// word. Existing IDs are preserved when an entry is updated.
    public static func merge(_ imported: [CustomWord], into existing: [CustomWord]) -> MergeResult {
        var words = existing
        var indicesByWord: [String: Int] = [:]
        for (index, word) in words.enumerated() {
            let key = normalizedWordKey(word.word)
            guard !key.isEmpty else { continue }
            indicesByWord[key] = index
        }

        var addedCount = 0
        var updatedCount = 0
        var skippedCount = 0

        for importedWord in imported {
            let word = importedWord.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else {
                skippedCount += 1
                continue
            }

            let replacement = importedWord.replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedWord = CustomWord(
                id: importedWord.id,
                word: word,
                replacement: replacement,
                matchingThreshold: importedWord.matchingThreshold
            )
            let key = normalizedWordKey(word)

            if let index = indicesByWord[key] {
                let existingWord = words[index]
                let updated = CustomWord(
                    id: existingWord.id,
                    word: normalizedWord.word,
                    replacement: normalizedWord.replacement,
                    matchingThreshold: normalizedWord.matchingThreshold
                )
                if existingWord == updated {
                    skippedCount += 1
                } else {
                    words[index] = updated
                    updatedCount += 1
                }
            } else {
                indicesByWord[key] = words.count
                // Imported app config files carry persistent IDs. A new
                // entry must receive a fresh ID so a renamed existing word
                // cannot collide with an older backup's identifier.
                words.append(
                    CustomWord(
                        word: normalizedWord.word,
                        replacement: normalizedWord.replacement,
                        matchingThreshold: normalizedWord.matchingThreshold
                    )
                )
                addedCount += 1
            }
        }

        return MergeResult(
            words: words,
            addedCount: addedCount,
            updatedCount: updatedCount,
            skippedCount: skippedCount
        )
    }

    private struct ConfigShape: Decodable {
        let customWords: [CustomWord]

        enum CodingKeys: String, CodingKey {
            case customWords = "custom_words"
        }
    }

    private struct PortableCustomWord: Encodable {
        let word: String
        let replacement: String?
        let matchingThreshold: Double

        enum CodingKeys: String, CodingKey {
            case word
            case replacement
            case matchingThreshold = "matching_threshold"
        }

        init(_ word: CustomWord) {
            self.word = word.word
            self.replacement = word.replacement
            self.matchingThreshold = word.matchingThreshold
        }
    }

    private static func normalizedWordKey(_ word: String) -> String {
        word
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }
}
