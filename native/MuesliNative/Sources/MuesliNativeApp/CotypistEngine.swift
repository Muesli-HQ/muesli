import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Cotypist's typeahead model: a base (not instruction-tuned) model continuing the user's text,
/// greedily, with per-token log-probabilities for gating and a prompt cache that survives
/// between requests so typing forward only processes the new tokens.
enum CotypistModel {
    /// mlx-community/gemma-4-e2b-4bit — base Gemma 4 E2B, pinned by revision like Muesli's other models.
    static let repoID = "mlx-community/gemma-4-e2b-4bit"
    static let revision = "a280baf4aece348bd0f561ca43b9d47cc66d8498"
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/muesli/models/typeahead/gemma-4-e2b-4bit/\(revision)")
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

/// Each token's surface text (SentencePiece `▁` / byte-level `Ġ` as a space), indexed by first
/// character — what token healing needs to keep generation consistent with a typed prefix.
private final class CotypistVocabulary: @unchecked Sendable {
    let pieces: [String]
    /// Tokens that are or contain a line break (including the byte-fallback `<0x0A>`).
    let newlines: [Int]
    private let byFirst: [Character: [Int]]

    init(tokenizer: any MLXLMCommon.Tokenizer, size: Int) {
        var pieces = [String](repeating: "", count: size)
        var newlines: [Int] = []
        var byFirst: [Character: [Int]] = [:]
        for id in 0..<size {
            guard let raw = tokenizer.convertIdToToken(id) else { continue }
            if raw.contains("\n") || raw == "<0x0A>" || raw == "<0x0D>" { newlines.append(id) }
            guard !(raw.hasPrefix("<") && raw.hasSuffix(">")) else { continue }
            let piece = raw.replacingOccurrences(of: "\u{2581}", with: " ").replacingOccurrences(of: "\u{0120}", with: " ")
            guard let first = piece.first else { continue }
            pieces[id] = piece
            byFirst[first, default: []].append(id)
        }
        self.pieces = pieces
        self.newlines = newlines
        self.byFirst = byFirst
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

    init(directory: URL = CotypistModel.directory) async throws {
        // The text-only Gemma class: faster than the multimodal one when no MTP drafter is used
        // (the Gemma drafters on disk are matched to the instruct model, not this base model).
        container = try await LLMModelFactory.shared.loadContainer(from: directory, using: CleanupHFTokenizerLoader())
    }

    /// Continues `prompt`. `heal`: text the user already typed past the end of `prompt` (a
    /// half-written word); the first tokens are constrained to reproduce it, so the model completes
    /// the word rather than guessing across a broken token boundary. The content starts with `heal`.
    func complete(prompt: String, maxTokens: Int, heal: String? = nil) async throws -> CotypistCompletion {
        let state = self.state
        return try await container.perform { context in
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
            let eos = Set([context.tokenizer.eosTokenId].compactMap { $0 }
                + context.configuration.extraEOSTokens.compactMap { context.tokenizer.convertTokenToId($0) })
            var next = ids[ids.count - 1]
            var generated: [Int] = []
            var tokens: [CotypistToken] = []
            var stop = CotypistCompletion.Stop.limit
            var remaining = heal ?? ""
            for _ in 0..<(maxTokens + (heal == nil ? 0 : 6)) {
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
