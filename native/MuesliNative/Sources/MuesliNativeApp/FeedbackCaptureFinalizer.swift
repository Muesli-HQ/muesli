import Foundation
import MuesliCore

/// Later slices register only the stages they produce. Copy always follows durable publication.
struct FeedbackCaptureFinalizer {
    enum StageName: Int, CaseIterable, Sendable { case transcribe, keyframes, render, summary, copy }
    struct Context: Sendable {
        let store: FeedbackCaptureStore
        let finishPasteboardChangeCount: Int
    }
    struct Stage {
        let name: StageName
        let run: (inout FeedbackCaptureManifest, Context) async throws -> Void
    }
    var stages: [Stage] = []

    func finish(_ recording: FeedbackCaptureManifest, context: Context, completionState: FeedbackCaptureState = .ready) async throws -> FeedbackCaptureManifest {
        var manifest = recording
        manifest.state = .processing
        let processing = manifest
        try await Task.detached { try context.store.checkpoint(processing); try context.store.save(processing) }.value
        for name in StageName.allCases where name != .copy {
            for stage in stages where stage.name == name {
                do { try await stage.run(&manifest, context) }
                catch { manifest.failures.append(.init(stage: String(describing: name), message: error.localizedDescription)) }
                let checkpoint = manifest
                try await Task.detached { try context.store.checkpoint(checkpoint) }.value
            }
        }
        manifest.state = manifest.audio != nil || manifest.video != nil ? completionState : .failed
        let published = manifest
        try await Task.detached { try context.store.publish(published) }.value
        for stage in stages where stage.name == .copy {
            do { try await stage.run(&manifest, context) }
            catch { manifest.failures.append(.init(stage: "copy", message: error.localizedDescription)) }
            // Persist delivery failures too; the recording was already durable before copy.
            let delivered = manifest
            try await Task.detached { try context.store.publish(delivered) }.value
        }
        return manifest
    }
}

/// One job owns its result continuation. Expiry/cancellation retires publication
/// immediately; native work keeps its own permit/files until it actually returns.
actor FeedbackCaptureTranscriptionJob {
    @TaskLocal static var current: FeedbackCaptureTranscriptionJob?
    private var remaining: Duration = .zero
    private var activeSince: ContinuousClock.Instant?
    private var timerID = UUID()
    private var result: CheckedContinuation<FeedbackCaptureTranscript, Never>?
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func run(timeout: Duration = .seconds(600),
             operation: @escaping @Sendable () async throws -> FeedbackCaptureTranscript) async -> FeedbackCaptureTranscript {
        guard !Task.isCancelled else { return .unavailable("transcription cancelled") }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                result = continuation
                remaining = timeout
                worker = Task(priority: .background) {
                    let value: FeedbackCaptureTranscript
                    do { value = try await Self.$current.withValue(self, operation: operation) }
                    catch is CancellationError { value = .unavailable("transcription cancelled") }
                    catch { value = .unavailable(error.localizedDescription) }
                    complete(value)
                }
            }
        } onCancel: { Task { await self.expire("transcription cancelled") } }
    }

    /// Only the coordinator's preparation/decoding sections consume this job's budget.
    func setActive(_ active: Bool) {
        if let activeSince { remaining -= activeSince.duration(to: .now) }
        activeSince = nil
        timer?.cancel(); timer = nil
        timerID = UUID()
        guard result != nil else { return }
        guard remaining > .zero else { expire("transcription timed out after ten minutes"); return }
        guard active else { return }
        activeSince = .now
        let id = timerID, delay = remaining
        timer = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            if timerID == id { expire("transcription timed out after ten minutes") }
        }
    }

    static func withActiveWork<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        await current?.setActive(true)
        do {
            try Task.checkCancellation()
            let value = try await operation()
            await current?.setActive(false)
            return value
        } catch {
            await current?.setActive(false)
            throw error
        }
    }

    private func expire(_ reason: String) {
        worker?.cancel()
        complete(.unavailable(reason))
    }
    private func complete(_ value: FeedbackCaptureTranscript) {
        guard let result else { return }
        self.result = nil
        timer?.cancel(); timer = nil
        worker = nil
        result.resume(returning: value)
    }
}

extension FeedbackCaptureFinalizer {
    static func transcriptionStage(
        transcribe: @escaping @Sendable (URL) async throws -> FeedbackCaptureTranscript
    ) -> Stage {
        Stage(name: .transcribe) { manifest, context in
            guard manifest.transcript == nil else { return }
            let transcript: FeedbackCaptureTranscript
            if let audio = manifest.audio {
                let url = try context.store.mediaURL(id: manifest.id, path: audio)
                transcript = await FeedbackCaptureTranscriptionJob().run { try await transcribe(url) }
            } else { transcript = .unavailable("narration audio unavailable") }
            manifest.transcript = transcript
            if let missing = transcript.missing {
                manifest.failures.append(.init(stage: "transcribe", message: missing.reason))
            }
        }
    }
}
