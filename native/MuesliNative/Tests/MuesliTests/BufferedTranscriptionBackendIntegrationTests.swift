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
        #expect(ManagedASRModelPlans.parakeetV3().isAvailableLocally())
        guard ManagedASRModelPlans.parakeetV3().isAvailableLocally() else { return }
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
        #expect(ManagedASRModelPlans.parakeetV3().isAvailableLocally())
        guard ManagedASRModelPlans.parakeetV3().isAvailableLocally() else { return }
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

        // Exercise successive hypotheses rather than only a final, full buffer.
        let progressive = BufferedSmokeOutput()
        let live = BufferedTranscriptionSession(decode: {
            let window = try await transcriber.transcribePreview(samples: $0, expectedVersion: .v3)
            if ProcessInfo.processInfo.environment["MUESLI_BUFFERED_SMOKE_VERBOSE"] == "1" {
                print("[buffered-smoke] progressive_words samples=\($0.count) words=\(window.words)")
            }
            return window
        }, onUpdate: { progressive.receive($0) }, onFailure: { progressive.fail($0) })
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
            print("[buffered-smoke] progressive_seconds=\(end / 16_000) committed=\(committed.count) draft=\(update.tail.count)")
        }
        if previousEnd < samples.count { live.enqueue(Array(samples[previousEnd...])) }
        await live.finish()
        #expect(progressive.failure == nil)
        #expect(committedBeforeRollover)
        #expect(progressive.lastTextCount > 0)
        await transcriber.shutdown()
    }
}

private final class BufferedSmokeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var error: String?
    private var textCount = 0
    private var text = ""
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
