import Foundation
import FluidAudio
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Buffered transcription model integration")
struct BufferedTranscriptionBackendIntegrationTests {
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
        for seconds in [2, 3, 5, 10, 15] {
            let count = min(samples.count, seconds * 16_000)
            do {
                let started = Date()
                let window = try await transcriber.transcribePreview(samples: Array(samples.prefix(count)), expectedVersion: .v3)
                let elapsed = Date().timeIntervalSince(started)
                print("[buffered-smoke] seconds=\(seconds) chars=\(window.text.count) words=\(window.words.count) end=\(window.words.last?.end ?? 0) decode_ms=\(Int(elapsed * 1000))")
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
        await transcriber.shutdown()
    }
}

private final class BufferedSmokeOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var error: String?
    private var textCount = 0
    var failure: String? { lock.withLock { error } }
    var lastTextCount: Int { lock.withLock { textCount } }
    func receive(_ update: BufferedTranscriptionUpdate) { lock.withLock { textCount = update.text.count } }
    func fail(_ failure: Error) { lock.withLock { error = String(describing: failure) } }
}
