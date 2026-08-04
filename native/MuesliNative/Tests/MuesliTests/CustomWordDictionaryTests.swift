import Foundation
import Testing
@testable import MuesliCore

@Suite("Custom word dictionary portability")
struct CustomWordDictionaryTests {
    @Test("decodes a portable dictionary array")
    func decodesPortableArray() throws {
        let data = Data(
            #"[{"word":"museli","replacement":"muesli","matching_threshold":0.9}]"#.utf8
        )

        let words = try CustomWordDictionaryCodec.decode(data)

        #expect(words.count == 1)
        #expect(words[0].word == "museli")
        #expect(words[0].targetWord == "muesli")
        #expect(words[0].matchingThreshold == 0.9)
    }

    @Test("decodes the app config dictionary shape")
    func decodesConfigShape() throws {
        let data = Data(
            #"{"custom_words":[{"word":"kubernete","replacement":"Kubernetes"}],"other_config_key":true}"#.utf8
        )

        let words = try CustomWordDictionaryCodec.decode(data)

        #expect(words.map(\.targetWord) == ["Kubernetes"])
    }

    @Test("exports portable entries without app-specific IDs")
    func exportsPortableEntries() throws {
        let words = [
            CustomWord(word: "museli", replacement: "muesli", matchingThreshold: 0.9),
        ]

        let data = try CustomWordDictionaryCodec.encode(words)
        let json = String(decoding: data, as: UTF8.self)

        #expect(!json.contains("\"id\""))
        #expect(json.contains("\"matching_threshold\""))
        let decoded = try CustomWordDictionaryCodec.decode(data)
        #expect(decoded.count == 1)
        #expect(decoded[0].word == words[0].word)
        #expect(decoded[0].replacement == words[0].replacement)
        #expect(decoded[0].matchingThreshold == words[0].matchingThreshold)
    }

    @Test("merges imported entries by normalized match word")
    func mergesEntries() {
        let existingID = UUID()
        let existing = CustomWord(
            id: existingID,
            word: "Muesli",
            replacement: "Muesli",
            matchingThreshold: 0.85
        )
        let imported = [
            CustomWord(word: " muesli ", replacement: "Muesli", matchingThreshold: 0.9),
            CustomWord(word: "kubernete", replacement: "Kubernetes"),
            CustomWord(word: "   ", replacement: "ignored"),
        ]

        let result = CustomWordDictionaryCodec.merge(imported, into: [existing])

        #expect(result.addedCount == 1)
        #expect(result.updatedCount == 1)
        #expect(result.skippedCount == 1)
        #expect(result.words.count == 2)
        #expect(result.words[0].id == existingID)
        #expect(result.words[0].word == "muesli")
        #expect(result.words[0].matchingThreshold == 0.9)
        #expect(result.words[1].targetWord == "Kubernetes")
    }

    @Test("new imported entries receive fresh IDs")
    func newEntriesDoNotReuseImportedIDs() {
        let importedID = UUID()
        let imported = [
            CustomWord(id: importedID, word: "kubernete", replacement: "Kubernetes"),
        ]

        let result = CustomWordDictionaryCodec.merge(imported, into: [])

        #expect(result.words.count == 1)
        #expect(result.words[0].id != importedID)
    }

    @Test("preserves explicit empty replacements through app import")
    func preservesExplicitEmptyReplacement() throws {
        let data = Data(
            #"[{"word":"delete","replacement":""}]"#.utf8
        )

        let imported = try CustomWordDictionaryCodec.decode(data)
        let result = CustomWordDictionaryCodec.merge(imported, into: [])

        #expect(imported[0].replacement == "")
        #expect(result.words[0].replacement == "")
        #expect(CustomWordMatcher.apply(text: "delete", customWords: result.words) == "")
    }
}
