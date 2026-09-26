import Foundation
import Testing
@testable import MuesliNativeApp

private struct FixtureVoiceExtractor: OwnerVoiceExtracting {
    let vector: [Float]
    func extract(samples: [Float]) async throws -> OwnerVoiceWindow {
        OwnerVoiceWindow(embedding: vector, speechSeconds: Double(samples.count) / 16_000, hasOverlap: false)
    }
}

private actor SuspendedVoiceExtractor: OwnerVoiceExtracting {
    private var extraction: CheckedContinuation<OwnerVoiceWindow, Error>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    func extract(samples: [Float]) async throws -> OwnerVoiceWindow {
        try await withCheckedThrowingContinuation { continuation in
            extraction = continuation
            didStart = true
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if didStart { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: OwnerVoiceWindow) {
        extraction?.resume(returning: result)
        extraction = nil
    }
}

@Suite("Owner voice enrollment")
struct OwnerVoiceEnrollmentTests {
    private var reference: [Float] { [1] + [Float](repeating: 0, count: 255) }
    private var speech: [Float] { (0..<160_000).map { sin(Float($0) * 0.13) * 0.1 } }

    @Test("acceptance measures speech and requires multiple bounded windows")
    @MainActor func acceptedSpeech() async throws {
        let enrollment = OwnerVoiceEnrollment(extractor: FixtureVoiceExtractor(vector: reference))
        enrollment.begin()
        #expect(try await enrollment.accept(samples: speech, elapsed: 10) == nil)
        #expect(enrollment.acceptedSpeechSeconds == 10)
        let profile = try #require(try await enrollment.accept(samples: speech, elapsed: 20))
        #expect(profile.references.count == 2)
        #expect(profile.acceptedSpeechSeconds == 20)
    }

    @Test("silence and clipping do not advance accepted speech")
    @MainActor func rejectBadAudio() async throws {
        let enrollment = OwnerVoiceEnrollment(extractor: FixtureVoiceExtractor(vector: reference))
        enrollment.begin()
        #expect(try await enrollment.accept(samples: [Float](repeating: 0, count: 160_000), elapsed: 10) == nil)
        #expect(try await enrollment.accept(samples: [Float](repeating: 1, count: 160_000), elapsed: 20) == nil)
        #expect(enrollment.acceptedSpeechSeconds == 0)
        #expect(throws: OwnerVoiceEnrollmentError.self) { try enrollment.checkDeadline(elapsed: 60) }
    }

    @Test("capture start invalidates publication before the extractor returns")
    @MainActor func captureStartCancelsPendingEnrollment() async {
        let enrollment = OwnerVoiceEnrollment(extractor: FixtureVoiceExtractor(vector: reference))
        enrollment.begin()
        enrollment.cancelForCaptureStart()
        #expect(!enrollment.isRecording)
        #expect(!enrollment.pendingPublicationIsValid)
    }

    @Test("late extraction cannot publish after cancellation or a newer attempt")
    @MainActor func suspendedExtractionIsInvalidated() async throws {
        let extractor = SuspendedVoiceExtractor()
        let enrollment = OwnerVoiceEnrollment(extractor: extractor)
        enrollment.begin()
        let pending = Task { try await enrollment.accept(samples: speech, elapsed: 10) }
        await extractor.waitUntilStarted()
        enrollment.cancelForCaptureStart()
        enrollment.begin()
        await extractor.finish(.init(embedding: reference, speechSeconds: 10, hasOverlap: false))
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(enrollment.acceptedSpeechSeconds == 0)
    }

    @Test("oversized window is rejected before inference")
    @MainActor func boundedWindow() async {
        let enrollment = OwnerVoiceEnrollment(extractor: FixtureVoiceExtractor(vector: reference))
        enrollment.begin()
        await #expect(throws: OwnerVoiceEnrollmentError.self) {
            _ = try await enrollment.accept(samples: [Float](repeating: 0.1, count: 160_001), elapsed: 10)
        }
    }
    @Test("capture cancellation leaves unchanged profile identity generation intact")
    @MainActor func idleCaptureCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceProfileStore(supportDirectory: root)
        try store.replace(OwnerVoiceProfile(modelIdentity: "fixture", references: [reference, reference], acceptedSpeechSeconds: 20))
        let voice = OwnerVoiceController(coordinator: TranscriptionCoordinator(), supportDirectory: root,
                                        captureIsActive: { false }, onChange: { _ in })
        let generation = voice.generation.value
        voice.cancelForCaptureStart()
        #expect(voice.generation.value == generation)
        #expect(voice.profile != nil)
    }

    @Test("unavailable profile storage reports a retryable setup error")
    @MainActor func unavailableProfileStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)

        let voice = OwnerVoiceController(coordinator: TranscriptionCoordinator(), supportDirectory: root,
                                         captureIsActive: { false }, onChange: { _ in })

        #expect(voice.profile == nil)
        #expect(voice.status == "Voice profile storage is unavailable. Try again after restarting.")
    }

    @Test("failed profile deletion keeps the profile visible and retryable")
    @MainActor func failedDeleteCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceProfileStore(supportDirectory: root)
        try store.replace(OwnerVoiceProfile(modelIdentity: "fixture", references: [reference, reference], acceptedSpeechSeconds: 20))
        let voice = OwnerVoiceController(coordinator: TranscriptionCoordinator(), supportDirectory: root,
                                         captureIsActive: { false }, onChange: { _ in })
        let profileDirectory = store.profileURL.deletingLastPathComponent()

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: profileDirectory.path)
        voice.delete()
        #expect(voice.profile != nil)
        #expect(voice.status == "Could not delete the stored profile. Please retry.")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profileDirectory.path)

        voice.delete()
        #expect(voice.profile == nil)
        #expect(!FileManager.default.fileExists(atPath: store.profileURL.path))
    }

}
