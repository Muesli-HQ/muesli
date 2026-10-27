import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import SQLite3
import Testing
@testable import MuesliNativeApp

/// Opt-in comparison of Cotypist model setups on the user's own writing. Not part of normal runs.
///
/// MUESLI_COTYPIST_COMPARISON_REPORT=<output.json> enables it. Inputs:
///  - MUESLI_COTYPIST_COMPARISON_DB: a muesli.db to read dictations from (opened read-only);
///  - MUESLI_COTYPIST_BASE_MODEL / _INSTRUCT_MODEL / _DRAFTER: model directories;
///  - MUESLI_COTYPIST_COMPARISON_SAMPLES (default 120 dictations, two cut points each).
/// Each cut point is a real prefix of the user's text; the rest of the text is what they went on
/// to write. A setup runs exactly as Cotypist does — the same engine, gate and two stages — and is
/// scored on what a user taking correct words one at a time would have accepted.
/// Run in release (`-c release -Xswiftc -enable-testing`): debug timings are not representative.
@Suite("Cotypist model comparison", .serialized)
@MainActor
struct CotypistModelComparisonTests {
    private static let environment = ProcessInfo.processInfo.environment

    struct Sample: Codable {
        let app: String
        let prompt: String
        let truth: String
        let midWord: Bool
    }

    struct Outcome: Codable {
        let shown: String?
        let rejection: String?
        let acceptedChars: Int
        let acceptedWords: Int
        let stage1Ms: Double
        let stage2Ms: Double?
    }

    struct Summary: Codable {
        let setup: String
        let samples: Int
        let shownRate: Double
        let firstWordCorrectWhenShown: Double
        let wordsAcceptedWhenShown: Double
        let charsSavedPerSample: Double
        let boundaryShownRate: Double
        let boundaryCorrect: Double
        let midWordShownRate: Double
        let midWordCorrect: Double
        let stage1P50: Double
        let stage1P90: Double
        let stage2P50: Double
        let stage2P90: Double
    }

    struct MTPSummary: Codable {
        let setup: String
        let prompts: Int
        let plainDecodeMsP50: Double
        let mtpDecodeMsP50: Double
        let draftAcceptance: Double
        let identicalOutput: Double
    }

    enum PromptFormat: String { case raw, chat }

    @Test("compare base and instruct Gemma 4 E2B for typeahead")
    func compare() async throws {
        guard let reportPath = Self.environment["MUESLI_COTYPIST_COMPARISON_REPORT"] else { return }
        if let path = Self.environment["MUESLI_MLX_EVAL_METALLIB"] { GPU.metallib = URL(fileURLWithPath: path) }
        let dbPath = try #require(Self.environment["MUESLI_COTYPIST_COMPARISON_DB"])
        let baseDir = URL(fileURLWithPath: try #require(Self.environment["MUESLI_COTYPIST_BASE_MODEL"]))
        let instructDir = URL(fileURLWithPath: try #require(Self.environment["MUESLI_COTYPIST_INSTRUCT_MODEL"]))
        let drafterDir = Self.environment["MUESLI_COTYPIST_DRAFTER"].map { URL(fileURLWithPath: $0) }
        let count = Int(Self.environment["MUESLI_COTYPIST_COMPARISON_SAMPLES"] ?? "") ?? 120

        let samples = Self.samples(from: try Self.dictations(dbPath: dbPath, limit: count))
        print("[cotypist-eval] \(samples.count) samples")

        var summaries: [Summary] = []
        var outcomes: [String: [Outcome]] = [:]
        for (name, directory, format) in [("base-raw", baseDir, PromptFormat.raw),
                                          ("instruct-raw", instructDir, .raw),
                                          ("instruct-chat", instructDir, .chat)] {
            let engine = try await CotypistEngine(directory: directory)
            _ = try await engine.complete(prompt: "Thanks for the", maxTokens: 2, heal: " qui")
            var results: [Outcome] = []
            for sample in samples {
                results.append(try await Self.run(sample, engine: engine, format: format))
            }
            outcomes[name] = results
            let summary = Self.summarize(name, samples: samples, outcomes: results)
            summaries.append(summary)
            print("[cotypist-eval] \(Self.describe(summary))")
            MLX.GPU.clearCache()
        }

        var mtp: [MTPSummary] = []
        if let drafterDir {
            let prompts = samples.filter { !$0.midWord }.prefix(60).map(\.prompt)
            for (name, directory, format) in [("base-raw", baseDir, PromptFormat.raw),
                                              ("instruct-raw", instructDir, .raw),
                                              ("instruct-chat", instructDir, .chat)] {
                let summary = try await Self.measureMTP(name, target: directory, drafter: drafterDir,
                                                        prompts: prompts.map { Self.prompt($0, app: "", format: format) })
                mtp.append(summary)
                print("[cotypist-eval] MTP \(summary.setup): decode p50 \(Int(summary.plainDecodeMsP50)) → \(Int(summary.mtpDecodeMsP50)) ms, draft acceptance \(Int(summary.draftAcceptance * 100))%, identical \(Int(summary.identicalOutput * 100))%")
                MLX.GPU.clearCache()
            }
        }

        struct Report: Codable {
            let summaries: [Summary]
            let mtp: [MTPSummary]
            let samples: [Sample]
            let outcomes: [String: [Outcome]]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Report(summaries: summaries, mtp: mtp, samples: samples, outcomes: outcomes))
            .write(to: URL(fileURLWithPath: reportPath))
    }

    // MARK: - Running a sample as Cotypist would

    /// The instruct model's chat format: a fixed instruction, then the model's turn already begun
    /// with the user's text so it continues it. The fixed part stays in the prompt cache.
    static func prompt(_ text: String, app: String, format: PromptFormat) -> String {
        switch format {
        case .raw: text
        case .chat:
            "<|turn>user\nContinue this text exactly as its author would, in their words and style. "
                + "Reply with the continuation only." + (app.isEmpty ? "" : "\nApp: \(app)")
                + "<turn|>\n<|turn>model\n" + text
        }
    }

    static func run(_ sample: Sample, engine: CotypistEngine, format: PromptFormat) async throws -> Outcome {
        // As CotypistService.suggestion: split off a half-typed word, trim trailing spaces.
        var text = sample.prompt
        var heal: String?
        if sample.midWord, let split = CotypistService.splitPartialWord(text) { (text, heal) = (split.before, split.heal) }
        let prompt = Self.prompt(text.trimmingCharacters(in: .whitespaces), app: sample.app, format: format)
        let afterSpace = !sample.midWord

        // The previous keystroke's request leaves the prompt cache warm up to about here.
        _ = try await engine.complete(prompt: String(prompt.dropLast(6)), maxTokens: 1)

        let first = try await engine.complete(prompt: prompt, maxTokens: 4, heal: heal)
        let stage1Ms = first.promptMs + first.decodeMs
        let stage1 = CotypistShaper.shape(first, afterSpace: afterSpace, heal: heal, maxTokens: 4, firstWordOnly: true)
        var shown: String?
        switch stage1 {
        case .success(let shaped): shown = shaped.text
        case .failure(.firstWordIncomplete): break
        case .failure(let rejection):
            return Outcome(shown: nil, rejection: rejection.description, acceptedChars: 0, acceptedWords: 0, stage1Ms: stage1Ms, stage2Ms: nil)
        }
        let full = try await engine.complete(prompt: prompt, maxTokens: 10, heal: heal)
        let stage2Ms = full.promptMs + full.decodeMs
        var rejection: String?
        switch CotypistShaper.shape(full, afterSpace: afterSpace, heal: heal, maxTokens: 10, firstWordOnly: false) {
        case .success(let shaped):
            // The helper extends the ghost only when the full suggestion continues the first word.
            if shown == nil || (shaped.text.hasPrefix(shown!) && shaped.text.count > shown!.count) { shown = shaped.text }
        case .failure(let failure): rejection = failure.description
        }
        let (chars, words) = Self.accepted(shown ?? "", truth: sample.truth)
        return Outcome(shown: shown, rejection: shown == nil ? rejection : nil, acceptedChars: chars, acceptedWords: words,
                       stage1Ms: stage1Ms, stage2Ms: stage2Ms)
    }

    /// What a user taking correct words one at a time (⌥→) would accept: whole words of the
    /// suggestion, in order, while each matches what they went on to write.
    static func accepted(_ shown: String, truth: String) -> (chars: Int, words: Int) {
        var rest = Substring(truth)
        var remaining = Substring(shown)
        var chars = 0, words = 0
        while !remaining.isEmpty {
            var end = remaining.startIndex
            while end < remaining.endIndex, remaining[end] == " " { end = remaining.index(after: end) }
            while end < remaining.endIndex, remaining[end] != " " { end = remaining.index(after: end) }
            let piece = remaining[remaining.startIndex..<end]
            guard rest.hasPrefix(piece) else { break }
            let after = rest.dropFirst(piece.count)
            guard after.isEmpty || after.first == " " else { break }  // must end where the word ends
            chars += piece.count
            words += 1
            rest = after
            remaining = remaining[end...]
        }
        return (chars, words)
    }

    // MARK: - Samples

    static func dictations(dbPath: String, limit: Int) throws -> [(text: String, app: String)] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT raw_text, COALESCE(target_app_name, '') FROM dictations
        WHERE deleted_at IS NULL AND source NOT IN ('cua', 'quil') AND word_count BETWEEN 12 AND 150
        ORDER BY timestamp DESC LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var rows: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((String(cString: sqlite3_column_text(statement, 0)), String(cString: sqlite3_column_text(statement, 1))))
        }
        return rows
    }

    /// Two cut points per text, chosen deterministically: after a word (at least 3 words in), and
    /// two letters into a word of 4+ letters.
    static func samples(from texts: [(text: String, app: String)]) -> [Sample] {
        var generator = SplitMix(seed: 7)
        var samples: [Sample] = []
        for (raw, app) in texts {
            let text = raw.replacingOccurrences(of: "\n", with: " ")
            let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard words.count >= 6 else { continue }
            let boundary = Int.random(in: 3...(words.count - 2), using: &generator)
            samples.append(Sample(app: app, prompt: words[..<boundary].joined(separator: " ") + " ",
                                  truth: words[boundary...].joined(separator: " "), midWord: false))
            let candidates = (3..<words.count).filter { words[$0].filter(\.isLetter).count >= 4 && words[$0].first!.isLetter }
            if let index = candidates.randomElement(using: &generator) {
                let word = words[index]
                samples.append(Sample(app: app, prompt: words[..<index].joined(separator: " ") + " " + word.prefix(2),
                                      truth: String(word.dropFirst(2)) + (index + 1 < words.count ? " " + words[(index + 1)...].joined(separator: " ") : ""),
                                      midWord: true))
            }
        }
        return samples
    }

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Summaries

    static func summarize(_ setup: String, samples: [Sample], outcomes: [Outcome]) -> Summary {
        func rate(_ items: [(Sample, Outcome)], _ predicate: (Outcome) -> Bool) -> Double {
            items.isEmpty ? 0 : Double(items.filter { predicate($0.1) }.count) / Double(items.count)
        }
        let pairs = Array(zip(samples, outcomes))
        let shown = pairs.filter { $0.1.shown != nil }
        let boundary = pairs.filter { !$0.0.midWord }, mid = pairs.filter { $0.0.midWord }
        let stage1 = outcomes.map(\.stage1Ms).sorted(), stage2 = outcomes.compactMap(\.stage2Ms).sorted()
        func percentile(_ values: [Double], _ p: Double) -> Double { values.isEmpty ? 0 : values[min(Int(Double(values.count) * p), values.count - 1)] }
        return Summary(
            setup: setup, samples: samples.count,
            shownRate: rate(pairs) { $0.shown != nil },
            firstWordCorrectWhenShown: rate(shown) { $0.acceptedWords > 0 },
            wordsAcceptedWhenShown: shown.isEmpty ? 0 : Double(shown.map(\.1.acceptedWords).reduce(0, +)) / Double(shown.count),
            charsSavedPerSample: Double(outcomes.map(\.acceptedChars).reduce(0, +)) / Double(max(outcomes.count, 1)),
            boundaryShownRate: rate(boundary) { $0.shown != nil },
            boundaryCorrect: rate(boundary.filter { $0.1.shown != nil }) { $0.acceptedWords > 0 },
            midWordShownRate: rate(mid) { $0.shown != nil },
            midWordCorrect: rate(mid.filter { $0.1.shown != nil }) { $0.acceptedWords > 0 },
            stage1P50: percentile(stage1, 0.5), stage1P90: percentile(stage1, 0.9),
            stage2P50: percentile(stage2, 0.5), stage2P90: percentile(stage2, 0.9)
        )
    }

    static func describe(_ s: Summary) -> String {
        func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        return "\(s.setup): shown \(pct(s.shownRate)), correct-when-shown \(pct(s.firstWordCorrectWhenShown)), "
            + String(format: "words/shown %.2f, chars saved/sample %.2f, ", s.wordsAcceptedWhenShown, s.charsSavedPerSample)
            + "boundary \(pct(s.boundaryShownRate))/\(pct(s.boundaryCorrect)), mid-word \(pct(s.midWordShownRate))/\(pct(s.midWordCorrect)), "
            + "stage1 p50 \(Int(s.stage1P50)) p90 \(Int(s.stage1P90)) ms, stage2 p50 \(Int(s.stage2P50)) p90 \(Int(s.stage2P90)) ms"
    }

    // MARK: - MTP

    /// Decode time for a 10-token greedy continuation with and without the Gemma assistant
    /// drafter (block size 3, Muesli's default), through mlx-swift-lm's own generator.
    static func measureMTP(_ setup: String, target: URL, drafter: URL, prompts: [String]) async throws -> MTPSummary {
        let registry = ModelTypeRegistry<LanguageModel>(creators: ["gemma4": { data in
            Gemma4(try JSONDecoder().decode(Gemma4Configuration.self, from: data))
        }])
        let container = try await LLMModelFactory(typeRegistry: registry, modelRegistry: LLMRegistry.shared)
            .loadContainer(from: target, using: CleanupHFTokenizerLoader())
        let config = try JSONDecoder().decode(Gemma4AssistantConfiguration.self, from: Data(contentsOf: drafter.appendingPathComponent("config.json")))
        let draft = Gemma4AssistantDraftModel(config)
        try await loadWeights(modelDirectory: drafter, model: draft)

        func generate(_ prompt: String, block: Int) async throws -> (tokens: [Int], decodeMs: Double, proposed: Int, accepted: Int) {
            try await container.perform { context in
                let ids = context.tokenizer.encode(text: prompt, addSpecialTokens: true)
                let parameters = GenerateParameters(maxTokens: 10, temperature: 0, topK: 1)
                let cache = try context.model.newCache(parameters: parameters)
                _ = context.model(MLXArray(Array(ids.dropLast())).reshaped(1, -1), cache: cache)
                eval(cache)
                let input = LMInput(tokens: MLXArray([Int32(ids.last!)]))
                let stream = block > 1
                    ? try generateTokens(input: input, cache: cache, parameters: parameters, context: context, mtpDrafter: draft, blockSize: block)
                    : try generateTokens(input: input, cache: cache, parameters: parameters, context: context)
                var tokens: [Int] = []
                var info: GenerateCompletionInfo?
                for await event in stream {
                    switch event {
                    case .token(let token): tokens.append(token)
                    case .info(let completion): info = completion
                    }
                }
                return (tokens, (info?.generateTime ?? 0) * 1000, info?.proposedDraftTokens ?? 0, info?.acceptedDraftTokens ?? 0)
            }
        }

        _ = try await generate("Thanks for the", block: 1)
        _ = try await generate("Thanks for the", block: 3)
        var plain: [Double] = [], mtp: [Double] = []
        var proposed = 0, accepted = 0, identical = 0
        for prompt in prompts {
            let a = try await generate(prompt, block: 1)
            let b = try await generate(prompt, block: 3)
            plain.append(a.decodeMs)
            mtp.append(b.decodeMs)
            proposed += b.proposed
            accepted += b.accepted
            if a.tokens == b.tokens { identical += 1 }
        }
        plain.sort(); mtp.sort()
        return MTPSummary(setup: setup, prompts: prompts.count,
                          plainDecodeMsP50: plain.isEmpty ? 0 : plain[plain.count / 2],
                          mtpDecodeMsP50: mtp.isEmpty ? 0 : mtp[mtp.count / 2],
                          draftAcceptance: proposed == 0 ? 0 : Double(accepted) / Double(proposed),
                          identicalOutput: prompts.isEmpty ? 0 : Double(identical) / Double(prompts.count))
    }
}
