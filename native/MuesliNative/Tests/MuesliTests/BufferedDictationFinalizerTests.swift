import AVFoundation
import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@Suite("Buffered dictation finalization")
@MainActor
struct BufferedDictationFinalizerTests {
    private func session(confidence: Float? = 0.99) -> BufferedTranscriptionSession {
        let session = BufferedTranscriptionSession(decode: { _ in
            .init(text: "Hello", words: [.init(text: "Hello", start: 0.2, end: 0.6, confidence: confidence)])
        }, onUpdate: { _ in }, onFailure: { _ in })
        session.enqueue(Array(repeating: 0.1, count: 32_000))
        return session
    }

    @Test func healthyStreamSkipsASRAndCleansExactlyOnce() async throws {
        var cleanups = 0
        var retranscriptions = 0
        let result = try await BufferedDictationFinalizer.transcribe(
            session: session(), recordedSampleCount: 32_000,
            reuse: { text in
                cleanups += 1
                #expect(text == "Hello")
                return .init(text: "Hello!", segments: [])
            }, nonStreaming: {
                retranscriptions += 1
                return .init(text: "fallback", segments: [])
            }
        )
        #expect(result.text == "Hello!")
        #expect(cleanups == 1)
        #expect(retranscriptions == 0)
    }

    @Test(arguments: [Optional<Int>.none, 31_999, 32_001])
    func incompleteCaptureIsReportedWithoutRetranscribing(recordedSamples: Int?) async throws {
        let stream = session()
        do {
            _ = try await BufferedDictationFinalizer.transcribe(
                session: stream, recordedSampleCount: recordedSamples,
                reuse: { _ in Issue.record("Incomplete stream reused"); return .init(text: "", segments: []) },
                nonStreaming: { Issue.record("Incomplete stream retranscribed"); return .init(text: "", segments: []) }
            )
            Issue.record("Missing capture was silently accepted")
        } catch let error as BufferedDictationFinalizer.IncompleteStream {
            #expect(error.reason == "recording_coverage_mismatch")
        }
        #expect(stream.diagnostics.closed)
    }

    @Test(arguments: [Optional<Float>.none, 0.1])
    func uncertaintyDoesNotRetranscribe(confidence: Float?) async throws {
        var cleanups = 0
        let result = try await BufferedDictationFinalizer.transcribe(
            session: session(confidence: confidence), recordedSampleCount: 32_000,
            reuse: { text in cleanups += 1; return .init(text: text, segments: []) },
            nonStreaming: { Issue.record("Uncertainty triggered ASR"); return .init(text: "", segments: []) }
        )
        #expect(result.text == "Hello")
        #expect(cleanups == 1)
    }

    @Test func ordinaryDictationStillTranscribesRecording() async throws {
        var fullPasses = 0
        let result = try await BufferedDictationFinalizer.transcribe(
            session: nil, recordedSampleCount: nil,
            reuse: { _ in Issue.record("No stream exists"); return .init(text: "", segments: []) },
            nonStreaming: { fullPasses += 1; return .init(text: "Normal dictation", segments: []) }
        )
        #expect(result.text == "Normal dictation")
        #expect(fullPasses == 1)
    }

    @Test func decoderFailureRequestsRecoveryWithoutAnotherPass() async throws {
        let stream = BufferedTranscriptionSession(decode: { _ in
            throw BufferedTranscriptionSession.Failure.invalidTimings
        }, onUpdate: { _ in }, onFailure: { _ in })
        stream.enqueue(Array(repeating: 0.1, count: 32_000))
        do {
            _ = try await BufferedDictationFinalizer.transcribe(
                session: stream, recordedSampleCount: 32_000,
                reuse: { _ in Issue.record("Failed stream cleaned up"); return .init(text: "", segments: []) },
                nonStreaming: { Issue.record("Decoder failure triggered ASR"); return .init(text: "", segments: []) }
            )
            Issue.record("Decoder failure was swallowed")
        } catch let error as BufferedDictationFinalizer.IncompleteStream {
            #expect(error.reason == "transcriptionFailed")
        }
    }

    @Test func cleanupCancellationDoesNotRetranscribe() async throws {
        do {
            _ = try await BufferedDictationFinalizer.transcribe(
                session: session(), recordedSampleCount: 32_000,
                reuse: { _ in throw CancellationError() },
                nonStreaming: { Issue.record("Cleanup cancellation triggered ASR"); return .init(text: "", segments: []) }
            )
            Issue.record("Cancellation was swallowed")
        } catch is CancellationError { }
    }

    @Test func tailTimeoutReportsRecoveryWithoutWaitingForDecoderOrRetranscribing() async throws {
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let stream = BufferedTranscriptionSession(decode: { _ in
            var events = gate.stream.makeAsyncIterator()
            _ = await events.next()
            return .init(text: "Late", words: [.init(text: "Late", start: 0.1, end: 0.5, confidence: 1)])
        }, onUpdate: { _ in }, onFailure: { _ in })
        stream.enqueue(Array(repeating: 0.1, count: 32_000))
        var decisions: [String] = []
        do {
            _ = try await BufferedDictationFinalizer.transcribe(
                session: stream, recordedSampleCount: 32_000, drainTimeout: .milliseconds(20),
                onDecision: { decisions.append($0) },
                reuse: { _ in Issue.record("Timed-out decoder reused"); return .init(text: "", segments: []) },
                nonStreaming: { Issue.record("Timeout triggered ASR"); return .init(text: "", segments: []) }
            )
            Issue.record("Timeout was swallowed")
        } catch let error as BufferedDictationFinalizer.IncompleteStream {
            #expect(error.reason == "tail_drain_timeout")
        }
        #expect(decisions.contains { $0.hasPrefix("incomplete:tail_drain_timeout") })
        #expect(stream.diagnostics.closed)
    }

    @Test func sharedCleanupAppliesArtifactsFillersAndCustomDictionary() async {
        let coordinator = TranscriptionCoordinator()
        let result = await coordinator.finalizeDictationTranscript(
            .init(text: "Um, hello muesly.", segments: []), backend: .parakeetMultilingual,
            customWords: [["word": "muesly", "replacement": "Muesli", "matchingThreshold": 1.0]]
        )
        #expect(result.text.contains("Muesli"))
        #expect(!result.text.lowercased().contains("um,"))
        let empty = await coordinator.finalizeDictationTranscript(
            .init(text: "[BLANK_AUDIO]", segments: []), backend: .parakeetMultilingual
        )
        #expect(empty.text.isEmpty)
    }

    @Test func recordingCoverageUsesActualMono16kFrames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for rate in [16_000.0, 48_000.0] {
            let url = directory.appendingPathComponent("\(rate).wav")
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
            buffer.frameLength = 1600
            buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
            do {
                let writer = try AVAudioFile(forWriting: url, settings: format.settings)
                try writer.write(from: buffer)
            }
            #expect(BufferedDictationFinalizer.recordedSampleCount(at: url) == (rate == 16_000 ? 1600 : nil))
        }
    }
}
