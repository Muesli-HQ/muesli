import CryptoKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Bodhan artifact validation")
struct BodhanArtifactValidationTests {
    @Test("Cached artifacts reject same-size corruption, absent files and invalid hashes")
    func cachedIntegrity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("good".utf8)
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        try original.write(to: directory.appendingPathComponent("valid"))
        try Data("evil".utf8).write(to: directory.appendingPathComponent("corrupt"))
        let entries = ["valid", "corrupt", "absent"].map {
            BodhanModel.Artifact(path: $0, bytes: 4, sha256: digest)
        }
        #expect(try await BodhanModel.invalidCachedArtifacts(entries, at: directory) == ["corrupt", "absent"])
        #expect(try await BodhanModel.invalidCachedArtifacts([
            .init(path: "valid", bytes: 4, sha256: String(repeating: "z", count: 64))
        ], at: directory) == ["valid"])
        #expect(BodhanModel.isSHA256(digest.uppercased()))
        #expect(!BodhanModel.isSHA256(String(repeating: "0", count: 63)))
    }

    @available(macOS 15, *)
    private func tokenizer(prompts: [String: [Int]] = ["hi": [0, 1, 2, 3]],
                           mixed: [String: [Int]]? = nil,
                           eos: Int = 0, special: Int = 4, pieceCount: Int = 8) -> BodhanCoreML.Tokenizer {
        .init(pieces: Array(repeating: "piece", count: pieceCount), special_count: special,
              eos_id: eos, prompts: prompts, mixed_prompts: mixed)
    }

    @Test("Tokenizer validates automatic prompts, token IDs and mixed language coverage")
    func tokenizerValidation() throws {
        guard #available(macOS 15, *) else { return }
        try tokenizer().validate(vocabularySize: 8)
        #expect(try tokenizer().automaticPrefix() == [0, 1, 2])
        for invalid in [
            tokenizer(prompts: [:]), tokenizer(prompts: ["en": [0, 1, 2, 3]]),
            tokenizer(prompts: ["hi": [0, 1, 2]]), tokenizer(prompts: ["hi": [0, 1, 2, 8]]),
            tokenizer(prompts: ["hi": [-1, 1, 2, 3]]), tokenizer(eos: 8), tokenizer(special: -1),
            tokenizer(pieceCount: 7), tokenizer(mixed: ["en": [0, 1, 2, 3]]),
            tokenizer(mixed: ["hi": [0]]), tokenizer(prompts: ["hi": Array(repeating: 0, count: 257)])
        ] {
            #expect(throws: (any Error).self) { try invalid.validate(vocabularySize: 8) }
        }
    }

    @Test("Core ML diagnostic decoder checks window before constructing the mask")
    func decoderWindow() throws {
        guard #available(macOS 15, *) else { return }
        try BodhanCoreML.validateDecoderWindow(tokenCount: 1, position: 511)
        try BodhanCoreML.validateDecoderWindow(tokenCount: 512, position: 0)
        for (count, position) in [(0, 0), (1, -1), (513, 0), (2, 511), (1, Int.max)] {
            #expect(throws: (any Error).self) {
                try BodhanCoreML.validateDecoderWindow(tokenCount: count, position: position)
            }
        }
    }
}
