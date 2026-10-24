import Foundation
import FluidAudio
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Buffered transcription model integration", .serialized)
struct BufferedTranscriptionBackendIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_BUFFERED_PARAKEET_SMOKE"] == "1"
                   && ProcessInfo.processInfo.environment["MUESLI_BUFFERED_SOAK_FIXTURE_DIR"] != nil))
    func parakeetV3ProgressesAcrossMultipleSpeechWindows() async throws {
        let directory = try #require(ProcessInfo.processInfo.environment["MUESLI_BUFFERED_SOAK_FIXTURE_DIR"])
        try #require(ManagedASRModelPlans.parakeetV3().isComplete(), "A validated local v3 installation is required; this test must not download or repair models")
        let converter = AudioConverter()
        var samples: [Float] = []
        for name in ["01-validation-request-21.4s.wav", "02-release-readiness-19.8s.wav", "03-diff-explanation-16.9s.wav"] {
            samples += try converter.resampleAudioFile(URL(fileURLWithPath: directory).appendingPathComponent(name))
            samples += Array(repeating: 0, count: 16_000)
        }
        let transcriber = FluidAudioTranscriber()
        try await transcriber.loadModels(version: .v3)
        let output = BufferedSmokeOutput()
        let session = BufferedTranscriptionSession(decode: {
            try await transcriber.transcribePreview(samples: $0, expectedVersion: .v3)
        }, onUpdate: { output.receive($0) }, onFailure: { output.fail($0) },
        onDiagnostic: { print("[buffered-soak] \($0)") })
        var events = output.stream.makeAsyncIterator()
        var previousEnd = 0
        var committed = ""
        var prefixAt30Seconds = ""
        for end in stride(from: 32_000, through: samples.count, by: 16_000) {
            session.enqueue(Array(samples[previousEnd..<end]))
            previousEnd = end
            let update = try #require(await events.next(), "Soak failed: \(output.failure ?? "unknown")")
            #expect(update.committedText.utf16.starts(with: committed.utf16))
            committed = update.committedText
            if end == 30 * 16_000 { prefixAt30Seconds = committed }
            print("[buffered-soak] seconds=\(end / 16_000) committed=\(committed.count) draft=\(update.tail.count)")
        }
        if previousEnd < samples.count { session.enqueue(Array(samples[previousEnd...])) }
        await session.finish()
        #expect(output.failure == nil)
        #expect(!prefixAt30Seconds.isEmpty)
        #expect(committed.count > prefixAt30Seconds.count)
        #expect(session.diagnostics.receivedSamples == samples.count)
        // Each source ends with one of these phrases. Check every recording's
        // tail survives the seams, rather than merely observing a growing count.
        let finalWords = output.lastText.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        for phrase in ["help them out", "cutting a release", "in that difference"] {
            #expect(finalWords.contains(phrase))
        }
        await transcriber.shutdown()
    }

    /// Opt in with a nonprivate speech fixture and an already installed v3 model.
    /// No downloads are permitted by this test's preconditions.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_BUFFERED_PARAKEET_SMOKE"] == "1"
                   && ProcessInfo.processInfo.environment["MUESLI_BUFFERED_SPEECH_FIXTURE"] != nil))
    func parakeetV3RealAudioProducesTimedPreviews() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["MUESLI_BUFFERED_SPEECH_FIXTURE"])
        try #require(ManagedASRModelPlans.parakeetV3().isComplete(), "A validated local v3 installation is required; this test must not download or repair models")
        let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: fixture))
        #expect(samples.count >= 15 * 16_000)
        let transcriber = FluidAudioTranscriber()
        try await transcriber.loadModels(version: .v3)
        var nonemptyPreviews = 0
        for seconds in [2, 3, 5, 9, 10, 15] {
            let count = min(samples.count, seconds * 16_000)
            do {
                let started = Date()
                let window = try await transcriber.transcribePreview(samples: Array(samples.prefix(count)), expectedVersion: .v3)
                let elapsed = Date().timeIntervalSince(started)
                print("[buffered-smoke] seconds=\(seconds) chars=\(window.text.count) words=\(window.words.count) end=\(window.words.last?.end ?? 0) decode_ms=\(Int(elapsed * 1000))")
                if ProcessInfo.processInfo.environment["MUESLI_BUFFERED_SMOKE_VERBOSE"] == "1" {
                    print("[buffered-smoke] timed_words=\(window.words)")
                }
                // Early prefixes may contain silence or too little context.
                // Empty hypotheses must remain valid and allow later decoding.
                if !window.text.isEmpty {
                    nonemptyPreviews += 1
                    #expect(!window.words.isEmpty)
                }
                #expect(window.words.allSatisfy { $0.start >= 0 && $0.end <= Double(count) / 16_000 + 0.25 })
            } catch {
                Issue.record("Parakeet preview failed at \(seconds) seconds: \(error)")
            }
        }
        #expect(nonemptyPreviews > 0)
        let updates = BufferedSmokeOutput()
        let session = BufferedTranscriptionSession(decode: {
            try await transcriber.transcribePreview(samples: $0, expectedVersion: .v3)
        }, onUpdate: { updates.receive($0) }, onFailure: { updates.fail($0) })
        session.enqueue(Array(samples.prefix(25 * 16_000)))
        await session.finish()
        #expect(updates.failure == nil)
        #expect(updates.lastTextCount > 0)
        #expect(session.diagnostics.decodeCount >= 2)
        print("[buffered-smoke] rolling_received_samples=\(session.diagnostics.receivedSamples) decodes=\(session.diagnostics.decodeCount) updates=\(session.diagnostics.revision)")

        try await assertProgressivePreview(samples: samples, label: "v3") {
            try await transcriber.transcribePreview(samples: $0, expectedVersion: .v3)
        }
        await transcriber.shutdown()
    }

    enum FamilyModel: String, CaseIterable, Sendable {
        case v2, redux, unified

        var plan: ManagedASRModelPlan {
            switch self {
            case .v2: return ManagedASRModelPlans.parakeetV2()
            case .redux: return ManagedASRModelPlans.parakeetRedux()
            case .unified: return ManagedASRModelPlans.parakeetUnified()
            }
        }
    }

    /// Explicitly opt in with a nonprivate speech fixture longer than 15 seconds.
    /// Strict completion markers exclude legacy caches whose failed runtime load
    /// would otherwise trigger an automatic repair/download.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_BUFFERED_PARAKEET_FAMILY_SMOKE"] == "1"
                   && ProcessInfo.processInfo.environment["MUESLI_BUFFERED_SPEECH_FIXTURE"] != nil),
          arguments: FamilyModel.allCases)
    func parakeetFamilyRealAudioProducesProgressivePreviews(model: FamilyModel) async throws {
        try #require(model.plan.isComplete(), "Install and validate \(model.rawValue) locally before opting into this no-download smoke test")
        let fixture = try #require(ProcessInfo.processInfo.environment["MUESLI_BUFFERED_SPEECH_FIXTURE"])
        let fixtureURL = URL(fileURLWithPath: fixture)
        let samples = try AudioConverter().resampleAudioFile(fixtureURL)
        try #require(samples.count > 15 * 16_000, "The public speech fixture must cross the 15-second rolling window")
        if model == .unified {
            let transcriber = ParakeetUnifiedTranscriber()
            do {
                try await transcriber.loadModels()
                try await assertProgressivePreview(samples: samples, label: model.rawValue) {
                    try await transcriber.transcribePreview(samples: $0)
                }
                let final = try await transcriber.transcribe(wavURL: fixtureURL)
                #expect(!final.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                print("[buffered-smoke] model=\(model.rawValue) final_chars=\(final.text.count)")
                await transcriber.shutdown()
            } catch {
                await transcriber.shutdown()
                throw error
            }
        } else {
            let version: AsrModelVersion = model == .v2 ? .v2 : .redux
            let transcriber = FluidAudioTranscriber()
            do {
                try await transcriber.loadModels(version: version)
                try await assertProgressivePreview(samples: samples, label: model.rawValue) {
                    try await transcriber.transcribePreview(samples: $0, expectedVersion: version)
                }
                let final = try await transcriber.transcribe(wavURL: fixtureURL, expectedVersion: version)
                #expect(!final.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                print("[buffered-smoke] model=\(model.rawValue) final_chars=\(final.text.count)")
                await transcriber.shutdown()
            } catch {
                await transcriber.shutdown()
                throw error
            }
        }
    }

    // Exercise successive hypotheses and actual window movement, not just one
    // final decode of a long buffer. Shared by v3 and the additional family models.
    private func assertProgressivePreview(
        samples: [Float], label: String,
        decode: @escaping @Sendable ([Float]) async throws -> BufferedTranscriptionWindow
    ) async throws {
        try #require(samples.count > 15 * 16_000, "The speech fixture must exceed one rolling window")
        let progressive = BufferedSmokeOutput()
        let live = BufferedTranscriptionSession(decode: { chunk in
            progressive.recordDecode(sampleCount: chunk.count)
            let window = try await decode(chunk)
            let duration = Double(chunk.count) / 16_000
            #expect(window.words.allSatisfy { $0.start >= 0 && $0.end <= duration + 0.25 })
            if ProcessInfo.processInfo.environment["MUESLI_BUFFERED_SMOKE_VERBOSE"] == "1" {
                print("[buffered-smoke] model=\(label) progressive_words samples=\(chunk.count) words=\(window.words)")
            }
            return window
        }, onUpdate: { progressive.receive($0) }, onFailure: { progressive.fail($0) })
        defer { live.cancel() }
        var events = progressive.stream.makeAsyncIterator()
        var previousEnd = 0
        var committed = ""
        var committedBeforeRollover = false
        for end in stride(from: 32_000, through: samples.count, by: 16_000) {
            live.enqueue(Array(samples[previousEnd..<end]))
            previousEnd = end
            let update = try #require(await events.next(), "Preview failed: \(progressive.failure ?? "unknown")")
            #expect(update.committedText.utf16.starts(with: committed.utf16))
            committed = update.committedText
            if end < 240_000, !committed.isEmpty { committedBeforeRollover = true }
            print("[buffered-smoke] model=\(label) progressive_seconds=\(end / 16_000) committed=\(committed.count) draft=\(update.tail.count)")
        }
        if previousEnd < samples.count { live.enqueue(Array(samples[previousEnd...])) }
        await live.finish()
        #expect(progressive.failure == nil)
        #expect(committedBeforeRollover)
        #expect(progressive.lastTextCount > 0)
        #expect(progressive.lastText.utf16.starts(with: committed.utf16))
        #expect(live.diagnostics.receivedSamples == samples.count)
        let windows = progressive.decodeSampleCounts
        #expect(zip(windows, windows.dropFirst()).contains { $0.1 < $0.0 }, "The decoder should advance to a shorter rolling window")
        print("[buffered-smoke] model=\(label) received_samples=\(live.diagnostics.receivedSamples) decodes=\(live.diagnostics.decodeCount) final_chars=\(progressive.lastTextCount)")
    }
}

private final class BufferedSmokeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var error: String?
    private var textCount = 0
    private var text = ""
    private var sampleCounts: [Int] = []
    let stream: AsyncStream<BufferedTranscriptionUpdate>
    private let continuation: AsyncStream<BufferedTranscriptionUpdate>.Continuation
    init() {
        let pair = AsyncStream<BufferedTranscriptionUpdate>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }
    var failure: String? { lock.withLock { error } }
    var lastTextCount: Int { lock.withLock { textCount } }
    var lastText: String { lock.withLock { text } }
    var decodeSampleCounts: [Int] { lock.withLock { sampleCounts } }
    func recordDecode(sampleCount: Int) { lock.withLock { sampleCounts.append(sampleCount) } }
    func receive(_ update: BufferedTranscriptionUpdate) {
        lock.withLock {
            textCount = update.text.count
            text = update.text
        }
        continuation.yield(update)
    }
    func fail(_ failure: Error) {
        lock.withLock { error = String(describing: failure) }
        continuation.finish()
    }
}
