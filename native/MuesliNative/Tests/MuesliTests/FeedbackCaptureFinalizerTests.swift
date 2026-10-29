import AppKit
import Foundation
import Testing
import os
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

    @Test func failedEmptyCaptureDoesNotCopyFailureSummary() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let manifest = try store.begin(target: feedbackTarget())
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString("keep", forType: .string)
            let context = FeedbackCaptureFinalizer.Context(store: store, finishPasteboardChangeCount: pasteboard.changeCount)
            var finalizer = FeedbackCaptureFinalizer(stages: FeedbackCaptureFinalizer.contextStages())
            finalizer.stages.append(FeedbackCaptureFinalizer.copyStage(pasteboard: pasteboard))

            let result = try await finalizer.finish(manifest, context: context)

            #expect(result.state == .failed)
            #expect(context.delivery.result == nil)
            #expect(pasteboard.string(forType: .string) == "keep")
            #expect(FeedbackCaptureController.completionState(result, delivery: context.delivery.result, retainsContent: false)
                == .failed(stage: "Recording", message: "No media captured", retainedMedia: false))
            store.release(id: manifest.id)
        }
    }
}

@Suite("Scrawl context finalization", .serialized)
@MainActor
struct FeedbackCaptureContextFinalizerTests {
    @Test func syntheticCapturePublishesReadableArtifactsAndCopiesTheirSummary() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget())
            m.video = "recording.mp4"; m.videoOffsetMs = 250; m.durationMs = 3000
            try await FeedbackCaptureRendererTests().makeVideo(store.mediaURL(id: m.id, path: "recording.mp4"))
            m.events = [.click(t: 500, x: 0.5, y: 0.5, button: 0), .click(t: 1500, x: 0.8, y: 0.5, button: 0)]
            let words: [FeedbackCaptureTranscript.Span] = [
                .init(t0: 0, t1: 100, text: "Open."), .init(t0: 500, t1: 600, text: "Click"),
                .init(t0: 700, t1: 800, text: "here."), .init(t0: 1500, t1: 1600, text: "Done.")
            ]
            m.transcript = .init(source: "fixture", text: "Open. Click here. Done.", words: words, segments: [], estimated: false)
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
            let context = FeedbackCaptureFinalizer.Context(store: store, finishPasteboardChangeCount: pasteboard.changeCount)
            var finalizer = FeedbackCaptureFinalizer(stages: FeedbackCaptureFinalizer.contextStages())
            finalizer.prepareThumbnails = FeedbackCaptureFinalizer.prepareContextThumbnails
            let captureID = m.id
            finalizer.stages.append(FeedbackCaptureFinalizer.copyStage(pasteboard: pasteboard, load: { url in
                // Copy must observe the durable ready manifest, after publication removed the journal.
                #expect(try store.manifest(id: captureID).state == .ready)
                #expect(!FileManager.default.fileExists(atPath: try store.mediaURL(id: captureID, path: "unfinished.json").path))
                return try String(contentsOf: url, encoding: .utf8)
            }))
            let result = try await finalizer.finish(m, context: context)
            #expect(result.state == .ready && result.failures.isEmpty)
            #expect(result.transcript == m.transcript)
            try #require(!result.keyframes.isEmpty)
            #expect(result.keyframes.contains { !$0.said.isEmpty })
            #expect(try store.manifest(id: m.id) == result)
            let sheet = try #require(result.contactSheet)
            for path in result.keyframes.map(\.file) + [sheet] {
                let data = try Data(contentsOf: store.mediaURL(id: m.id, path: path))
                #expect(NSBitmapImageRep(data: data) != nil)
            }
            let summary = try String(contentsOf: store.mediaURL(id: m.id, path: "summary.md"), encoding: .utf8)
            #expect(!summary.isEmpty)
            #expect(pasteboard.string(forType: .string) == summary && context.delivery.result == .copied)
            store.release(id: m.id)
        }
    }
    @Test func copyReadFailurePreservesPublishedBundleAndNamesDeliveryFailure() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget())
            m.events = [.click(t: 1000, x: 0.5, y: 0.5, button: 0)]
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
            pasteboard.setString("keep", forType: .string)
            let context = FeedbackCaptureFinalizer.Context(store: store, finishPasteboardChangeCount: pasteboard.changeCount)
            let finalizer = FeedbackCaptureFinalizer(stages: [FeedbackCaptureFinalizer.copyStage(pasteboard: pasteboard)])
            let result = try await finalizer.finish(m, context: context)
            #expect(result.state == .ready && context.delivery.result == .failed)
            #expect(result.failures.map(\.stage) == ["copy"])
            #expect(try store.manifest(id: m.id) == result)
            #expect(pasteboard.string(forType: .string) == "keep")
            #expect(FeedbackCaptureController.completionState(result, delivery: .failed, retainsContent: true)
                == .failed(stage: "Copy", message: result.failures[0].message, retainedMedia: true))
            store.release(id: m.id)
        }
    }
    @Test func completionSeparatesClipboardOutcomeFromPartialStageFailures() {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.state = .ready
        m.failures = [.init(stage: "transcribe", message: "fixture"), .init(stage: "keyframes", message: "fixture"),
            .init(stage: "render", message: "fixture")]
        #expect(FeedbackCaptureController.completionState(m, delivery: .copied, retainsContent: true)
            == .copied(partial: "no transcript, frames failed"))
        #expect(FeedbackCaptureController.completionState(m, delivery: .skipped, retainsContent: true)
            == .readyToCopy(partial: "no transcript, frames failed"))
    }
    @Test func eventOnlyCapturePublishesSummaryAndRecoveryNeverCopies() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget())
            m.events = [.click(t: 1000, x: 0.5, y: 0.2, button: 0)]
            var copies = 0
            var finalizer = FeedbackCaptureFinalizer()
            finalizer.stages = FeedbackCaptureFinalizer.contextStages()
            finalizer.stages.append(.init(name: .copy) { _, _ in copies += 1 })
            let result = try await finalizer.finish(m, context: .init(store: store, finishPasteboardChangeCount: 0), completionState: .recovered)
            #expect(result.state == .recovered)
            #expect(copies == 0)
            #expect(try String(contentsOf: store.mediaURL(id: m.id, path: "summary.md"), encoding: .utf8).contains("No transcript"))
            #expect(try store.manifest(id: m.id).events == m.events)
            #expect(!FileManager.default.fileExists(atPath: try store.mediaURL(id: m.id, path: "unfinished.json").path))
            store.release(id: m.id)
        }
    }
    @Test func thumbnailPreparationOverlapsTranscriptionAndJoinsBeforeSelection() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget()); m.audio = "narration.wav"
            let started = OSAllocatedUnfairLock(initialState: false)
            var finalizer = FeedbackCaptureFinalizer()
            finalizer.prepareThumbnails = { _, _ in
                started.withLock { $0 = true }
                return [.init(t: 250, luma: [0])]
            }
            finalizer.stages = [
                .init(name: .transcribe) { manifest, _ in
                    for _ in 0..<100 {
                        if started.withLock({ $0 }) { break }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                    #expect(started.withLock { $0 })
                    manifest.transcript = .unavailable("fixture")
                },
                .init(name: .keyframes) { _, context in #expect(context.thumbnails.map(\.t) == [250]) }
            ]
            let result = try await finalizer.finish(m, context: .init(store: store, finishPasteboardChangeCount: 0))
            #expect(result.transcript?.missing?.reason == "fixture")
            store.release(id: m.id)
        }
    }
    @Test func recoveredThumbnailTimeoutPreservesSavedImages() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget())
            m.events = [.click(t: 500, x: 0.5, y: 0.5, button: 0)]
            m.keyframes = [.init(index: 1, t: 500, reason: "click", file: "frames/frame-01.png", eventIndex: 0,
                said: "Keep this saved scene.", saidRange: .init(from: 0, to: 0))]
            m.contactSheet = "contact-sheet.png"

            let image = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: store.mediaURL(id: m.id, path: "frames"), withIntermediateDirectories: true)
            try png.write(to: store.mediaURL(id: m.id, path: "frames/frame-01.png"))
            try png.write(to: store.mediaURL(id: m.id, path: "contact-sheet.png"))
            try store.checkpoint(m)

            var finalizer = FeedbackCaptureFinalizer(stages: FeedbackCaptureFinalizer.contextStages())
            finalizer.prepareThumbnails = { _, _ in throw ScreenVideoRecorder.error("fixture thumbnail timeout") }
            let result = try await finalizer.finish(m,
                context: .init(store: store, finishPasteboardChangeCount: 0), completionState: .recovered)

            #expect(result.state == .recovered)
            #expect(result.keyframes == m.keyframes)
            #expect(result.contactSheet == m.contactSheet)
            #expect(result.failures.contains { $0.stage == "keyframes" && $0.message.contains("fixture thumbnail timeout") })
            let summary = try String(contentsOf: store.mediaURL(id: m.id, path: "summary.md"), encoding: .utf8)
            #expect(summary.contains("contact-sheet.png"))
            #expect(summary.contains("frames/frame-01.png"))
            #expect(!FileManager.default.fileExists(atPath: try store.mediaURL(id: m.id, path: "unfinished.json").path))

            let loaded = try FeedbackCaptureView.load(id: m.id, store: store)
            #expect(loaded.contactSheet != nil)
            #expect(loaded.frames["frames/frame-01.png"] != nil)
            #expect(!loaded.missingArtifacts.contains("contact-sheet.png"))
            #expect(!loaded.missingArtifacts.contains("frames/frame-01.png"))
            store.release(id: m.id)
        }
    }
    @Test func recoveredThumbnailTimeoutDropsUnreadableSavedImages() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget())
            m.transcript = .init(source: "fixture", text: "Keep this. Missing frame words. Bad frame words.", words: [
                .init(t0: 0, t1: 100, text: "Keep"), .init(t0: 100, t1: 200, text: "this."),
                .init(t0: 200, t1: 300, text: "Missing"), .init(t0: 300, t1: 400, text: "frame"),
                .init(t0: 400, t1: 500, text: "words."), .init(t0: 500, t1: 600, text: "Bad"),
                .init(t0: 600, t1: 700, text: "frame"), .init(t0: 700, t1: 800, text: "words.")
            ], segments: [], estimated: false)
            m.keyframes = [
                .init(index: 1, t: 100, reason: "initial", file: "frames/frame-01.png", said: "Keep this.", saidRange: .init(from: 0, to: 2)),
                .init(index: 2, t: 300, reason: "click", file: "frames/frame-02.png", said: "Missing frame words.", saidRange: .init(from: 2, to: 5)),
                .init(index: 3, t: 600, reason: "click", file: "frames/frame-03.png", said: "Bad frame words.", saidRange: .init(from: 5, to: 8))
            ]
            m.contactSheet = "contact-sheet.png"

            let image = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: store.mediaURL(id: m.id, path: "frames"), withIntermediateDirectories: true)
            try png.write(to: store.mediaURL(id: m.id, path: "frames/frame-01.png"))
            try Data("not a PNG".utf8).write(to: store.mediaURL(id: m.id, path: "frames/frame-03.png"))
            try store.checkpoint(m)

            var finalizer = FeedbackCaptureFinalizer(stages: FeedbackCaptureFinalizer.contextStages())
            finalizer.prepareThumbnails = { _, _ in throw ScreenVideoRecorder.error("fixture thumbnail timeout") }
            let result = try await finalizer.finish(m,
                context: .init(store: store, finishPasteboardChangeCount: 0), completionState: .recovered)

            #expect(result.keyframes.map(\.file) == ["frames/frame-01.png"])
            #expect(result.contactSheet == nil)
            let summary = try String(contentsOf: store.mediaURL(id: m.id, path: "summary.md"), encoding: .utf8)
            #expect(summary.contains("frames/frame-01.png"))
            #expect(!summary.contains("frames/frame-02.png"))
            #expect(!summary.contains("frames/frame-03.png"))
            #expect(!summary.contains("contact-sheet.png"))
            #expect(summary.contains("Unillustrated narration: “Missing frame words. Bad frame words.”"))

            let loaded = try FeedbackCaptureView.load(id: m.id, store: store)
            #expect(loaded.contactSheet == nil)
            #expect(loaded.frames["frames/frame-01.png"] != nil)
            #expect(loaded.missingArtifacts.isEmpty)
            store.release(id: m.id)
        }
    }
    @Test func thumbnailFailureStillProducesAllNarrationInSummary() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget()); m.audio = "narration.wav"
            m.transcript = .init(source: "fixture", text: "Every word survives.", words: [
                .init(t0: 0, t1: 100, text: "Every"), .init(t0: 200, t1: 300, text: "word"),
                .init(t0: 400, t1: 500, text: "survives.")], segments: [], estimated: true)
            var finalizer = FeedbackCaptureFinalizer(stages: FeedbackCaptureFinalizer.contextStages())
            finalizer.prepareThumbnails = { _, _ in throw ScreenVideoRecorder.error("fixture thumbnail failure") }
            let result = try await finalizer.finish(m, context: .init(store: store, finishPasteboardChangeCount: 0))
            #expect(result.state == .ready)
            #expect(result.keyframes.isEmpty)
            #expect(result.failures.contains { $0.stage == "keyframes" && $0.message.contains("fixture thumbnail failure") })
            let summary = try String(contentsOf: store.mediaURL(id: m.id, path: "summary.md"), encoding: .utf8)
            #expect(summary.contains("Unillustrated narration: “Every word survives.”"))
            #expect(!summary.contains("contact-sheet.png"))
            store.release(id: m.id)
        }
    }
    @Test("Automatic copy checks the clipboard at write time", arguments: [false, true])
    func clipboardRace(changed: Bool) async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget()); m.audio = "narration.wav"
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents(); pasteboard.setString("before", forType: .string)
            let count = pasteboard.changeCount
            let overwrite: @MainActor @Sendable () -> Void = {
                pasteboard.clearContents(); pasteboard.setString("new user copy", forType: .string)
            }
            let context = FeedbackCaptureFinalizer.Context(store: store, finishPasteboardChangeCount: count)
            let finalizer = FeedbackCaptureFinalizer(stages: [
                .init(name: .summary) { manifest, context in
                    try Data("durable summary".utf8).write(to: context.store.mediaURL(id: manifest.id, path: "summary.md"), options: .atomic)
                },
                FeedbackCaptureFinalizer.copyStage(pasteboard: pasteboard, load: { url in
                    let summary = try String(contentsOf: url, encoding: .utf8)
                    if changed { await overwrite() }
                    return summary
                })
            ])
            let result = try await finalizer.finish(m, context: context)
            #expect(result.failures.isEmpty)
            #expect(context.delivery.result == (changed ? .skipped : .copied))
            #expect(pasteboard.string(forType: .string) == (changed ? "new user copy" : "durable summary"))
            store.release(id: m.id)
        }
    }
    @Test func explicitCopyReadsDurableSummaryAndRejectsStalePresentation() async throws {
        try await withFeedbackStoreAsync { store, root in
            let m = try store.begin(target: feedbackTarget())
            try Data("saved summary".utf8).write(to: store.mediaURL(id: m.id, path: "summary.md"), options: .atomic)
            let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents(); pasteboard.setString("keep", forType: .string)
            let controller = FeedbackCaptureController(databaseURL: root.appendingPathComponent("muesli.db"), supportDirectory: root,
                observeSystem: false)
            let stale = await controller.copy(id: m.id, expectedPresentationID: controller.presentationID + 1, pasteboard: pasteboard)
            #expect(stale == .skipped && pasteboard.string(forType: .string) == "keep")
            #expect(await controller.copy(id: m.id, pasteboard: pasteboard) == .copied)
            #expect(pasteboard.string(forType: .string) == "saved summary")
            try FileManager.default.removeItem(at: store.mediaURL(id: m.id, path: "summary.md"))
            #expect(await controller.copy(id: m.id, pasteboard: pasteboard) == .failed)
            #expect(pasteboard.string(forType: .string) == "saved summary")
            store.release(id: m.id)
        }
    }
}
