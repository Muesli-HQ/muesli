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
