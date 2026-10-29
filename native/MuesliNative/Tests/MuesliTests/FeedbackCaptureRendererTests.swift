import AppKit
import AVFoundation
import Foundation
import Testing
import os
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Scrawl renderer", .serialized)
struct FeedbackCaptureRendererTests {
    /// Silent H.264 fixture, with no input devices, audio tracks or player.
    func makeVideo(_ url: URL, samples: [(time: CMTime, value: UInt8)]? = nil) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let samples = samples ?? (0..<12).map { index in
            (time: CMTime(value: Int64(index), timescale: 4), value: index < 6 ? 20 : 200)
        }
        for sample in samples {
            while !input.isReadyForMoreMediaData {
                try #require(writer.status == .writing)
                try await Task.sleep(for: .milliseconds(1))
            }
            var buffer: CVPixelBuffer?
            try #require(CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer) == kCVReturnSuccess)
            let pixel = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<180 {
                for x in 0..<320 {
                    let offset = y * row + x * 4
                    let value = sample.value
                    bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value; bytes[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            try #require(adaptor.append(pixel, withPresentationTime: sample.time))
        }
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }
    @Test func sequentialThumbnailsUseCaptureClockAndFullFramesRecordActualTime() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget())
            let url = try store.mediaURL(id: m.id, path: "recording.mp4")
            try await makeVideo(url)
            m.video = "recording.mp4"; m.videoOffsetMs = 250; m.durationMs = 3000
            let thumbnails = try await FeedbackCaptureRenderer.thumbnails(url: url, videoOffsetMs: 250,
                cancellation: FeedbackCaptureDecodeCancellation())
            try #require(thumbnails.count == 12)
            #expect(thumbnails.first?.t == 250 && thumbnails.last?.t == 3000)
            #expect(thumbnails.allSatisfy { $0.luma.count == 64 * 36 })
            #expect(thumbnails[0].luma[0] < thumbnails[8].luma[0])
            m.events = [.click(t: 500, x: 0.5, y: 0.5, button: 0)]
            m.keyframes = [.init(index: 1, t: 850, reason: "click", file: "frames/frame-01.png", eventIndex: 0,
                said: "", saidRange: .init(from: 0, to: 0))]
            let rendered = try await FeedbackCaptureRenderer.render(m, url: url, cancellation: FeedbackCaptureDecodeCancellation())
            let frame = try #require(rendered.frames.first)
            // Requested video 600 ms lies between samples; returned actualTime is authoritative.
            #expect(frame.keyframe.t >= 750 && frame.keyframe.t <= 1000)
            #expect(frame.keyframe.t != 850)
            let bitmap = try #require(NSBitmapImageRep(data: frame.png))
            #expect(bitmap.pixelsWide == 320 && bitmap.pixelsHigh == 240)
            let ring = try #require(bitmap.colorAt(x: 160 + 14, y: 150)?.usingColorSpace(.deviceRGB))
            #expect(ring.blueComponent > ring.redComponent + 0.15)
            #expect(rendered.contactSheet != nil)
            store.release(id: m.id)
        }
    }
    @Test func sparseFinalFrameRemainsSelectableForLastAction() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let m = try store.begin(target: feedbackTarget())
            let url = try store.mediaURL(id: m.id, path: "recording.mp4")
            let samples: [(time: CMTime, value: UInt8)] = [
                (.zero, 20), (CMTime(value: 1, timescale: 4), 20), (CMTime(value: 2, timescale: 4), 20),
                (CMTime(value: 3, timescale: 4), 20), (CMTime(value: 4, timescale: 4), 20),
                (CMTime(value: 11, timescale: 10), 200)
            ]
            try await makeVideo(url, samples: samples)

            let thumbnails = try await FeedbackCaptureRenderer.thumbnails(url: url, videoOffsetMs: 0,
                cancellation: FeedbackCaptureDecodeCancellation())
            let final = try #require(thumbnails.last)
            let atOneSecond = try #require(thumbnails.first { $0.t == 1000 })
            #expect(thumbnails.map(\.t) == [0, 250, 500, 750, 1000, 1100])
            #expect(final.t == 1100)
            #expect(atOneSecond.luma[0] < final.luma[0])

            let event = FeedbackCaptureEvent.click(t: 850, x: 0.5, y: 0.5, button: 0)
            let candidates = FeedbackCaptureContext.select(durationMs: 1200, events: [event], thumbnails: thumbnails)
            #expect(candidates.first { $0.eventIndex == 0 }?.time == 1100)
            store.release(id: m.id)
        }
    }
    @Test func numberBandPreservesSourcePixelsAndContactSheetHasBoundedLongEdge() throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        // Distinct content in both original top corners models embedded cursors or controls.
        context.setFillColor(red: 0.9, green: 0.1, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 130, width: 60, height: 50))
        context.setFillColor(red: 0.1, green: 0.9, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 260, y: 130, width: 60, height: 50))
        let image = try #require(context.makeImage())
        let annotated = try FeedbackCaptureRenderer.annotate(image, index: 1, click: nil)
        try #require(annotated.width == image.width && annotated.height == image.height + 60)
        let original = NSBitmapImageRep(cgImage: image), bitmap = NSBitmapImageRep(cgImage: annotated)
        for y in 0..<image.height {
            for x in 0..<image.width {
                #expect(bitmap.colorAt(x: x, y: y + 60) == original.colorAt(x: x, y: y))
            }
        }
        let chip = try #require(bitmap.colorAt(x: 16, y: 28)?.usingColorSpace(.deviceRGB))
        #expect(chip.redComponent > 0.8 && chip.greenComponent > 0.8 && chip.blueComponent > 0.8)
        let edgeRing = NSBitmapImageRep(cgImage: try FeedbackCaptureRenderer.annotate(image, index: 2, click: CGPoint(x: 0.8, y: 0)))
        let band = try #require(edgeRing.colorAt(x: 256, y: 59)?.usingColorSpace(.deviceRGB))
        #expect(abs(band.redComponent - 28.0 / 255) < 0.01)
        #expect(abs(band.blueComponent - 34.0 / 255) < 0.01)
        let ringAtSourceEdge = try #require(edgeRing.colorAt(x: 256, y: 60)?.usingColorSpace(.deviceRGB))
        #expect(ringAtSourceEdge.blueComponent > ringAtSourceEdge.redComponent + 0.15)
        let sheet = try FeedbackCaptureRenderer.contactSheet(Array(repeating: annotated, count: 12))
        #expect(max(sheet.width, sheet.height) <= 1600)
        #expect(sheet.width > 320 && sheet.height > 240)
        let sheetBitmap = NSBitmapImageRep(cgImage: sheet)
        let gutter = try #require(sheetBitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(abs(gutter.redComponent - 28.0 / 255) < 0.01)
        #expect(abs(gutter.greenComponent - 29.0 / 255) < 0.01)
        #expect(abs(gutter.blueComponent - 34.0 / 255) < 0.01)
    }
    @Test func renderFailureRetainsNarrationWithoutPublishingMissingFramePaths() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget()); m.video = "recording.mp4"; m.audio = "narration.wav"
            m.durationMs = 1000
            m.transcript = .init(source: "fixture", text: "Keep these words.", words: [
                .init(t0: 0, t1: 100, text: "Keep"), .init(t0: 200, t1: 300, text: "these"),
                .init(t0: 400, t1: 500, text: "words.")], segments: [], estimated: false)
            let finalizer = FeedbackCaptureFinalizer(stages: FeedbackCaptureFinalizer.contextStages())
            let context = FeedbackCaptureFinalizer.Context(store: store, finishPasteboardChangeCount: 0,
                thumbnails: [.init(t: 0, luma: [0])])
            let result = try await finalizer.finish(m, context: context)
            #expect(result.keyframes.isEmpty && result.contactSheet == nil)
            #expect(result.failures.contains { $0.stage == "render" })
            let summary = try String(contentsOf: store.mediaURL(id: m.id, path: "summary.md"), encoding: .utf8)
            #expect(summary.contains("Keep these words."))
            #expect(!summary.contains("frame-01.png"))
            store.release(id: m.id)
        }
    }
    @Test func viewLoadsGeneratedArtifactsAndKeepsLegacyAndMissingStates() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget())
            var loaded = try FeedbackCaptureView.load(id: m.id, store: store)
            #expect(loaded.contactSheet == nil && loaded.frames.isEmpty && loaded.active)
            m.contactSheet = "contact-sheet.png"
            m.keyframes = [.init(index: 1, t: 0, reason: "initial", file: "frames/frame-01.png",
                said: "", saidRange: .init(from: 0, to: 0))]
            try store.checkpoint(m)
            loaded = try FeedbackCaptureView.load(id: m.id, store: store)
            #expect(Set(loaded.missingArtifacts) == Set(["contact-sheet.png", "frames/frame-01.png"]))
            let image = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try FileManager.default.createDirectory(at: store.mediaURL(id: m.id, path: "frames"), withIntermediateDirectories: true)
            try data.write(to: store.mediaURL(id: m.id, path: "contact-sheet.png"))
            try data.write(to: store.mediaURL(id: m.id, path: "frames/frame-01.png"))
            try Data("summary".utf8).write(to: store.mediaURL(id: m.id, path: "summary.md"))
            loaded = try FeedbackCaptureView.load(id: m.id, store: store)
            #expect(loaded.contactSheet?.size.width == 2)
            #expect(loaded.frames.count == 1 && loaded.summaryAvailable && loaded.missingArtifacts.isEmpty)
            store.release(id: m.id)
        }
    }
    @Test func cancelledArtifactLoadingNeverReturnsAStaleSnapshot() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let m = try store.begin(target: feedbackTarget())
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try FeedbackCaptureView.load(id: m.id, store: store)
            }
            do { _ = try await task.value; Issue.record("Cancelled artifact loading returned content") }
            catch { #expect(error is CancellationError) }
            store.release(id: m.id)
        }
    }
    @Test func mediaDeadlineCancelsNativeWorkAndDiscardsLateResult() async throws {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let returned = OSAllocatedUnfairLock(initialState: false)
        let job = FeedbackCaptureMediaJob<Int>()
        let start = ContinuousClock.now
        do {
            _ = try await job.run(timeout: .milliseconds(20), cancel: { cancelled.withLock { $0 = true } }) {
                // Model a native operation that ignores Swift task cancellation.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) { continuation.resume() }
                }
                returned.withLock { $0 = true }
                return 42
            }
            Issue.record("Expired decoding was accepted")
        } catch { #expect(error.localizedDescription.localizedCaseInsensitiveContains("timed out")) }
        #expect(start.duration(to: .now) < .milliseconds(100))
        #expect(cancelled.withLock { $0 })
        try await Task.sleep(for: .milliseconds(160))
        #expect(returned.withLock { $0 })
    }
}
