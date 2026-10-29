import AppKit
import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Scrawl finalizer", .serialized)
@MainActor
struct FeedbackCaptureFinalizerTests {
    @Test func orderedStagesContinueAfterFailureAndCopyFollowsPublication() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var manifest = try store.begin(target: feedbackTarget())
            try WavWriter.writeWAV(samples: [Float](repeating: 0.25, count: 1600), to: store.mediaURL(id: manifest.id, path: "narration.wav"))
            manifest.audio = "narration.wav"
            var order: [FeedbackCaptureFinalizer.StageName] = []
            let count = NSPasteboard.general.changeCount
            let context = FeedbackCaptureFinalizer.Context(store: store, finishPasteboardChangeCount: count)
            let finalizer = FeedbackCaptureFinalizer(stages: FeedbackCaptureFinalizer.StageName.allCases.reversed().map { name in
                .init(name: name, run: { m, c in
                    order.append(name)
                    #expect(c.finishPasteboardChangeCount == count)
                    if name == .transcribe { throw ScreenVideoRecorder.error("fixture transcription failure") }
                    if name == .render { m.durationMs = 1234 }
                    if name == .copy {
                        #expect(try c.store.get(id: m.id)?.state == .ready)
                        #expect(try c.store.manifest(id: m.id).durationMs == 1234)
                        #expect(!FileManager.default.fileExists(atPath: try c.store.mediaURL(id: m.id, path: "unfinished.json").path))
                    }
                })
            })
            let result = try await finalizer.finish(manifest, context: context)
            #expect(order == FeedbackCaptureFinalizer.StageName.allCases)
            #expect(result.state == .ready && result.audio == "narration.wav")
            #expect(result.failures.map(\.stage) == ["transcribe"])
            #expect(result.durationMs == 1234)
            #expect(NSPasteboard.general.changeCount == count)
            store.release(id: manifest.id)
        }
    }
    @Test func sliceOneHasNoLaterStagesAndNeverWritesClipboard() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let manifest = try store.begin(target: feedbackTarget())
            let finalizer = FeedbackCaptureFinalizer()
            let count = NSPasteboard.general.changeCount
            #expect(finalizer.stages.isEmpty)
            let result = try await finalizer.finish(manifest, context: .init(store: store, finishPasteboardChangeCount: count))
            #expect(result.state == .failed)
            #expect(NSPasteboard.general.changeCount == count)
            store.release(id: manifest.id)
        }
    }
}
