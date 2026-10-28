import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Cotypist's typeahead model: a base (not instruction-tuned) model continuing the user's text,
/// greedily, with per-token log-probabilities for gating and a prompt cache that survives
/// between requests so typing forward only processes the new tokens.
/// The typeahead models Cotypist can run: base (not instruction-tuned) models, 4-bit MLX, each
/// pinned by revision and benchmarked on real writing (CotypistModelComparisonTests).
enum CotypistModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwen35_0_8b = "qwen3.5-0.8b-base"
    case qwen35_2b = "qwen3.5-2b-base"
    case gemma4E2B = "gemma-4-e2b-base"

    /// The model selected when nothing else is: the recommended one.
    static let defaultModel: CotypistModel = .qwen35_0_8b

    var id: String { rawValue }

    var label: String {
        switch self {
        case .qwen35_0_8b: "Qwen 3.5 0.8B"
        case .qwen35_2b: "Qwen 3.5 2B"
        case .gemma4E2B: "Gemma 4 E2B"
        }
    }

    /// The best balance of speed, accuracy and size in testing on real writing.
    var isRecommended: Bool { self == .qwen35_0_8b }

    var summary: String {
        switch self {
        case .qwen35_0_8b: "As accurate as Gemma on real writing at a ninth of the size, and about twice as fast."
        case .qwen35_2b: "The most accurate in testing, at about Gemma's speed and a third of its size."
        case .gemma4E2B: "Cotypist's first model. Accurate, but the largest and slowest of the three."
        }
    }

    var logo: String {
        switch self {
        case .qwen35_0_8b, .qwen35_2b: "qwen-logo"
        case .gemma4E2B: "google-logo"
        }
    }

    /// Where the 4-bit weights are downloaded from, pinned by revision. The Qwen repositories hold
    /// Muesli's MLX conversions of the unmodified `Qwen/Qwen3.5-*-Base` checkpoints (Apache 2.0;
    /// source revisions in their model cards).
    var repoID: String {
        switch self {
        case .qwen35_0_8b: "Muesli-HQ/qwen35-0.8b-base-cotypist-mlx-4bit"
        case .qwen35_2b: "Muesli-HQ/qwen35-2b-base-cotypist-mlx-4bit"
        case .gemma4E2B: "mlx-community/gemma-4-e2b-4bit"
        }
    }

    var revision: String {
        switch self {
        case .qwen35_0_8b: "5e47c2ac8c821c9e8f677063fc18bfc55a6a0eef"
        case .qwen35_2b: "2434da7449586e5e676ce03f5f34008e5df85ba8"
        case .gemma4E2B: "a280baf4aece348bd0f561ca43b9d47cc66d8498"
        }
    }

    private var folder: String {
        switch self {
        case .qwen35_0_8b: "qwen3.5-0.8b-base-4bit"
        case .qwen35_2b: "qwen3.5-2b-base-4bit"
        case .gemma4E2B: "gemma-4-e2b-4bit"
        }
    }

    var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/typeahead/\(folder)/\(revision)")
    }

    /// Every file the runtime needs at the pinned revision, with its size and SHA-256 (matching
    /// what Hugging Face serves), for the shared resumable, verified download. `nil` would mark a
    /// model with no published home yet ("Coming soon").
    var release: ManagedCleanupModel? {
        switch self {
        case .qwen35_0_8b:
            ManagedCleanupModel(repoID, revision, [
                ("model.safetensors", 424_026_782, "8d7883bce060432705aa0e48e8743babd47d7c3d6ca89e8d63574549b52ea3ad"),
                ("model.safetensors.index.json", 60_784, "d95a2e17af08ab870498266088eccee4d0a012338c604465ae7df24b976c488e"),
                ("config.json", 2_625, "919d818806acc6093475afcccc40b4c27deb509ef1508ba940c71c9b3ce83ab5"),
                ("tokenizer.json", 19_989_339, "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f"),
                ("tokenizer_config.json", 1_505, "ce915a484ffe99d34d38a925d07e291d43846c241431304512c7fadb9287d168"),
            ])
        case .qwen35_2b:
            ManagedCleanupModel(repoID, revision, [
                ("model.safetensors", 1_059_404_951, "cdafd8bae44b62e95217e5003e11fb17f84c8a288a16b21f61697a14737ed004"),
                ("model.safetensors.index.json", 60_786, "3b2dffa510d1d73decdbc12d5e1bc7d6a9f7b2deb631bfd84238a1f8fc4e0fd1"),
                ("config.json", 2_625, "8893a91e9b7763d7b94c6db181f5b7c79c6f4881a69cefb11549eefcab1823bf"),
                ("tokenizer.json", 19_989_339, "a5cd9732badce41de57e6efce8302930ded1c1188c5f81feb2bd6c24c4a1941f"),
                ("tokenizer_config.json", 1_505, "ce915a484ffe99d34d38a925d07e291d43846c241431304512c7fadb9287d168"),
            ])
        case .gemma4E2B:
            ManagedCleanupModel(repoID, revision, [
                ("model.safetensors", 3_581_101_896, "1b75a001977eeadfe0c82eabde23d470530c311b6a8c279a3c2382aafc2a2d5b"),
                ("model.safetensors.index.json", 230_329, "a8aa7359c747a0d59368dbff9a1029da86bda139ccc0ae1f1e938db75de7d5ce"),
                ("config.json", 5_955, "61b3440401f0dc0a1c0c63f9bcf1ef65eb4e564f083a772e3904de5a2b45d1a5"),
                ("generation_config.json", 181, "de16fa1d777387d5fe6df54a9565d9c0f1213f7b31f2a2cf44805e27686d9c7c"),
                ("processor_config.json", 902, "1bd0d00776284f369c1eff5fb631e865dfcdca861e0b7d60dbef27fcf37436a8"),
                ("tokenizer.json", 32_170_070, "12bac982b793c44b03d52a250a9f0d0b666813da566b910c24a6da0695fd11e6"),
                ("tokenizer_config.json", 1_498, "e8ca2612e1e9cd7f258aee62c053050019adc92b14a9b3a015c6ec8715b6a2e4"),
            ])
        }
    }

    /// The download size of the 4-bit model.
    var sizeLabel: String { release?.downloadSizeLabel ?? "" }

    var isDownloaded: Bool {
        if let release { return release.isPresent(at: directory) }
        return ["config.json", "model.safetensors", "tokenizer.json"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// Minimum log-probability of the first suggested word, per model: each model's confidence is
    /// on its own scale, so each is calibrated separately on real writing.
    func firstWordGate(_ frequency: CotypistFrequency, midWord: Bool) -> Double {
        // Calibrated separately per model on 600 cut points of real dictations
        // (CotypistModelComparisonTests). All three land on the same values: Balanced keeps about
        // 90–100% of the characters saved while cutting wrong suggestions by about 40%.
        // A model that calibrates differently gets its own cases here.
        switch (frequency, midWord) {
        case (.fewer, _): -1.0
        case (.balanced, false): -1.5
        case (.balanced, true): -2.0
        case (.more, false): -2.5
        case (.more, true): -3.0
        }
    }
}

struct CotypistToken: Sendable { let text: String; let logprob: Double }

struct CotypistCompletion: Sendable {
    enum Stop: Sendable { case endOfText, newline, limit, healFailed }
    let tokens: [CotypistToken]
    let stop: Stop
    let promptMs: Double
    let decodeMs: Double
    let reusedTokens: Int
    var content: String { tokens.map(\.text).joined() }
}

/// Prompt cache and vocabulary index carried between requests. Only touched inside
/// `CotypistEngine.complete`, which the actor serialises.
private final class CotypistState: @unchecked Sendable {
    var cache: [KVCache] = []
    var tokens: [Int] = []
    var vocab: CotypistVocabulary?
}

/// Each token's surface text, indexed by first character — what token healing needs to keep
/// generation consistent with a typed prefix. Handles both vocabularies Cotypist's models use:
/// SentencePiece (`▁` for a space, `<0x0A>` byte fallback; Gemma) and GPT-2 byte-level BPE
/// (every byte mapped to a printable character, `Ġ` space and `Ċ` newline; Qwen).
private final class CotypistVocabulary: @unchecked Sendable {
    let pieces: [String]
    /// Tokens that are or contain a line break.
    let newlines: [Int]
    private let byFirst: [Character: [Int]]

    init(tokenizer: any MLXLMCommon.Tokenizer, size: Int) {
        var raws = [String?](repeating: nil, count: size)
        for id in 0..<size { raws[id] = tokenizer.convertIdToToken(id) }
        // Byte-level vocabularies spell a leading space as `Ġ` in thousands of tokens.
        let byteLevel = raws.lazy.prefix(50_000).filter { $0?.hasPrefix("\u{0120}") == true }.count > 1_000
        var pieces = [String](repeating: "", count: size)
        var newlines: [Int] = []
        var byFirst: [Character: [Int]] = [:]
        for id in 0..<size {
            guard let raw = raws[id] else { continue }
            if raw == "<0x0A>" || raw == "<0x0D>" { newlines.append(id); continue }
            guard !(raw.hasPrefix("<") && raw.hasSuffix(">")) else { continue }
            let piece = byteLevel ? Self.decodeByteLevel(raw) : raw.replacingOccurrences(of: "\u{2581}", with: " ")
            if piece.contains("\n") || piece.contains("\r") { newlines.append(id) }
            guard let first = piece.first else { continue }
            pieces[id] = piece
            byFirst[first, default: []].append(id)
        }
        self.pieces = pieces
        self.newlines = newlines
        self.byFirst = byFirst
    }

    /// GPT-2's byte-to-character table, inverted: printable bytes map to themselves and the rest
    /// to U+0100 onwards, in order.
    private static let byteLevelBytes: [Character: UInt8] = {
        var printable = Array(UInt8(33)...UInt8(126)) + Array(UInt8(161)...UInt8(172)) + Array(UInt8(174)...UInt8(255))
        var table: [Character: UInt8] = [:]
        for byte in printable { table[Character(Unicode.Scalar(byte))] = byte }
        var next: UInt32 = 256
        for byte in UInt8(0)...UInt8(255) where !printable.contains(byte) {
            table[Character(Unicode.Scalar(next)!)] = byte
            next += 1
            printable.append(byte)
        }
        return table
    }()

    /// A byte-level token's text. A token holding part of a multi-byte character decodes with a
    /// replacement character, which no typed text starts with, so it simply never matches.
    private static func decodeByteLevel(_ raw: String) -> String {
        String(decoding: raw.compactMap { byteLevelBytes[$0] }, as: UTF8.self)
    }

    /// Tokens that keep the output consistent with `remaining`: they finish it or are a prefix of it.
    /// Tokens that cover all of `remaining` win: a word is usually one token, and stepping
    /// through a fragment of it (" num" for " numb") puts the model on a path it rarely saw and
    /// derails what follows. Shorter fragments are the fallback for words no token covers.
    func allowed(continuing remaining: String) -> [Int] {
        guard let first = remaining.first else { return [] }
        let candidates = byFirst[first] ?? []
        let covering = candidates.filter { pieces[$0].hasPrefix(remaining) }
        return covering.isEmpty ? candidates.filter { remaining.hasPrefix(pieces[$0]) } : covering
    }
}

actor CotypistEngine {
    private let container: ModelContainer
    private let state = CotypistState()

    init(directory: URL = CotypistModel.defaultModel.directory) async throws {
        // The text-only Gemma class: faster than the multimodal one when no MTP drafter is used
        // (the Gemma drafters on disk are matched to the instruct model, not this base model).
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: CleanupHFTokenizerLoader())
    }

    /// Continues `prompt`. `heal`: text the user already typed past the end of `prompt` (a
    /// half-written word); the first tokens are constrained to reproduce it, so the model completes
    /// the word rather than guessing across a broken token boundary. The content starts with `heal`.
    /// `isCurrent` is checked before and during inference: a request overtaken by newer typing
    /// stops with `CancellationError` rather than holding the engine.
    func complete(prompt: String, maxTokens: Int, heal: String? = nil,
                  isCurrent: @escaping @Sendable () -> Bool = { true }) async throws -> CotypistCompletion {
        let state = self.state
        return try await container.perform { context in
            guard isCurrent() else { throw CancellationError() }
            let start = Date()
            let ids = context.tokenizer.encode(text: prompt, addSpecialTokens: true)
            guard ids.count >= 2 else {
                return CotypistCompletion(tokens: [], stop: .endOfText, promptMs: 0, decodeMs: 0, reusedTokens: 0)
            }

            // Reuse the longest shared prefix; the last prompt token is always re-fed for its logits.
            var shared = 0
            while shared < min(state.tokens.count, ids.count - 1), state.tokens[shared] == ids[shared] { shared += 1 }
            let excess = state.tokens.count - shared
            if state.cache.isEmpty || (excess > 0 && !state.cache.allSatisfy({ $0.isTrimmable })) {
                state.cache = try context.model.newCache(parameters: GenerateParameters())
                state.tokens = []
                shared = 0
            } else if excess > 0 {
                for layer in state.cache { layer.trim(excess) }
                state.tokens.removeLast(excess)
            }
            var position = shared
            while position < ids.count - 1 {
                let end = min(position + 512, ids.count - 1)
                _ = context.model(MLXArray(Array(ids[position..<end])).reshaped(1, -1), cache: state.cache)
                eval(state.cache)
                position = end
            }
            state.tokens = Array(ids[0..<(ids.count - 1)])
            let promptMs = Date().timeIntervalSince(start) * 1000

            let decodeStart = Date()
            // `<turn|>` ends an instruction-tuned Gemma's reply when the prompt uses its chat format.
            let eos = Set([context.tokenizer.eosTokenId].compactMap { $0 }
                + (context.configuration.extraEOSTokens.union(["<turn|>"])).compactMap { context.tokenizer.convertTokenToId($0) })
            var next = ids[ids.count - 1]
            var generated: [Int] = []
            var tokens: [CotypistToken] = []
            var stop = CotypistCompletion.Stop.limit
            var remaining = heal ?? ""
            for _ in 0..<(maxTokens + (heal == nil ? 0 : 6)) {
                guard isCurrent() else { throw CancellationError() }
                let logits = context.model(MLXArray([Int32(next)]).reshaped(1, 1), cache: state.cache)
                state.tokens.append(next)
                let last = logits[0, -1].asType(.float32)
                let logprobs = last - logSumExp(last, axis: -1, keepDims: true)
                let size = logprobs.dim(-1)
                if state.vocab?.pieces.count != size { state.vocab = CotypistVocabulary(tokenizer: context.tokenizer, size: size) }
                let token: Int
                var lineBreakMass = 0.0
                // While healing, a token's confidence is relative to the tokens consistent with the
                // typed prefix: P(rest of word | typed part), not P(whole word), which is tiny for
                // any less common word.
                var healNorm = 0.0
                if remaining.isEmpty && generated.isEmpty {
                    // A suggestion never starts with a line break (inputs are mostly one line). Pick the
                    // best other token; its confidence is rescaled to the non-line-break choices below.
                    let newlines = state.vocab!.newlines
                    lineBreakMass = min(exp(logprobs[MLXArray(newlines.map(Int32.init))]).sum().item(Double.self), 0.999)
                    var mask = [Float](repeating: 0, count: size)
                    for id in newlines { mask[id] = -1e9 }
                    token = argMax(logprobs + MLXArray(mask), axis: -1).item(Int.self)
                } else if remaining.isEmpty {
                    token = argMax(logprobs, axis: -1).item(Int.self)
                } else {
                    // Token healing: only tokens consistent with what the user already typed.
                    let allowed = state.vocab!.allowed(continuing: remaining)
                    if allowed.isEmpty { stop = .healFailed; break }
                    var mask = [Float](repeating: -1e9, count: size)
                    for id in allowed { mask[id] = 0 }
                    token = argMax(logprobs + MLXArray(mask), axis: -1).item(Int.self)
                    healNorm = logSumExp(logprobs[MLXArray(allowed.map(Int32.init))]).item(Double.self)
                    let piece = state.vocab!.pieces[token]
                    remaining = piece.count >= remaining.count ? "" : String(remaining.dropFirst(piece.count))
                }
                let logprob = logprobs[token].item(Double.self) - log(1 - lineBreakMass) - healNorm
                if eos.contains(token) { stop = .endOfText; break }
                // Decode against everything so far so multi-byte characters come out whole.
                let before = context.tokenizer.decode(tokenIds: generated, skipSpecialTokens: true)
                let after = context.tokenizer.decode(tokenIds: generated + [token], skipSpecialTokens: true)
                let piece = String(after.dropFirst(before.count))
                if piece.contains("\n") { stop = .newline; break }
                generated.append(token)
                tokens.append(CotypistToken(text: piece, logprob: logprob))
                next = token
            }
            return CotypistCompletion(tokens: tokens, stop: stop, promptMs: promptMs,
                                      decodeMs: Date().timeIntervalSince(decodeStart) * 1000, reusedTokens: shared)
        }
    }
}
