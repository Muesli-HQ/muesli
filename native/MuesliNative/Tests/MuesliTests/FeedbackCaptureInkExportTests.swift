import AppKit
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Scrawl ink export", .serialized)
struct FeedbackCaptureInkExportTests {
    @Test func regionalLumaSharesUnchangedMarksAndPreservesThirteenChangedMarks() {
        let strokes = (0..<13).map { feedbackStroke(Int64($0 * 2000)) }
        let marks = FeedbackCaptureInk.marks(strokes)
        let same = (0..<13).map { FeedbackCaptureContext.Thumbnail(t: Int64($0 * 2000 + 100), luma: Array(repeating: 0, count: 64 * 36)) }
        let shared = FeedbackCaptureContext.select(durationMs: 26000, events: [], thumbnails: same, marks: marks)
        #expect(shared.filter { $0.reason == "mark" }.count == 1)
        #expect(shared.first { $0.reason == "mark" }?.markIds.count == 13)
        let changed = same.enumerated().map { i, sample in
            FeedbackCaptureContext.Thumbnail(t: sample.t, luma: Array(repeating: i.isMultiple(of: 2) ? 0 : 255, count: 64 * 36))
        }
        let selected = FeedbackCaptureContext.select(durationMs: 26000, events: [], thumbnails: changed, marks: marks)
        #expect(selected.count == 13 && selected.allSatisfy { $0.reason == "mark" })
        var m = FeedbackCaptureManifest(id: "fixture", createdAtMs: 0, target: feedbackTarget())
        m.strokes = strokes; m.marks = marks
        m.keyframes = FeedbackCaptureContext.keyframes(selected, transcript: nil)
        #expect(m.keyframes.compactMap(\.markId).count == 13)
        FeedbackCaptureContext.linkMarks(&m)
        #expect(m.marks.allSatisfy { $0.frame != nil })
        let summary = FeedbackCaptureContext.summary(m, bundle: URL(fileURLWithPath: "/fixture.capture"))
        #expect(summary.contains("+1 more marked frames in frames/"))
        #expect(summary.components(separatedBy: "✎").count == 14)
        m.keyframes.removeLast(); FeedbackCaptureContext.linkMarks(&m)
        #expect(m.marks.last?.frame == nil)

        var awayLuma = same[0].luma
        for y in 25..<36 { for x in 40..<64 { awayLuma[y * 64 + x] = 255 } }
        let away = FeedbackCaptureContext.select(durationMs: 3000, events: [], thumbnails: [
            same[0], .init(t: same[1].t, luma: awayLuma)
        ], marks: Array(marks.prefix(2))).filter { $0.reason == "mark" }
        #expect(away.count == 1 && away.first?.markIds == ["m1", "m2"])

        let gradualStrokes: [FeedbackCaptureStroke] = (0..<3).map { i in
            let start = Int64(i) * 2000 + 100
            return FeedbackCaptureStroke(t0: start, t1: start + 100,
                fw: 1000, fh: 500, pts: [2500, 2500, 0, 4531, 4444, 100])
        }
        let gradualMarks = FeedbackCaptureInk.marks(gradualStrokes)
        let a = Array(repeating: UInt8(0), count: 64 * 36)
        var b = a, c = a
        // The padded ink region covers 160 cells. Each step changes six disjoint
        // cells (3.75%); the first and last views differ in twelve cells (7.5%).
        for x in 15..<21 { b[8 * 64 + x] = 255 }
        c = b
        for x in 21..<27 { c[8 * 64 + x] = 255 }
        let gradual = FeedbackCaptureContext.select(durationMs: 4500, events: [], thumbnails: [
            .init(t: 200, luma: a), .init(t: 2200, luma: b), .init(t: 4200, luma: c)
        ], marks: gradualMarks).filter { $0.reason == "mark" }
        #expect(gradual.map(\.markIds) == [["m1", "m2"], ["m3"]])
        #expect(gradual.map(\.time) == [2200, 4200])
    }
    @Test func settledPageChangeBetweenNearbyStrokesKeepsTheirFramesSeparate() async throws {
        let before = Array(repeating: UInt8(0), count: 64 * 36)
        var after = before
        for y in 15..<36 { for x in 40..<64 { after[y * 64 + x] = 255 } }
        let thumbnails = [0, 250, 500, 1000].map { FeedbackCaptureContext.Thumbnail(t: Int64($0), luma: before) }
            + [1250, 1500, 1750, 2000].map { FeedbackCaptureContext.Thumbnail(t: Int64($0), luma: after) }
        try await withFeedbackStoreAsync { store, _ in
            var manifest = try store.begin(target: feedbackTarget())
            manifest.durationMs = 2200
            manifest.strokes = [feedbackStroke(500), feedbackStroke(1270)]
            manifest.marks = FeedbackCaptureInk.marks(manifest.strokes)
            let keyframes = try #require(FeedbackCaptureFinalizer.contextStages().first { $0.name == .keyframes })
            try await keyframes.run(&manifest, .init(store: store, finishPasteboardChangeCount: 0, thumbnails: thumbnails))
            #expect(manifest.marks.map(\.t1) == [600, 1370])
            #expect(manifest.keyframes.filter { $0.reason == "mark" }.map(\.t) == [600, 1370])
            #expect(manifest.keyframes.compactMap(\.markId) == ["m1", "m2"])
            #expect(Set(manifest.marks.compactMap(\.frame)).count == 2)
            store.release(id: manifest.id)
        }
    }
    @Test func strokeOnlyFinalizationRetainsRecoveredMarksWithoutFrameLinks() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget())
            m.strokes = [feedbackStroke()]; m.marks = FeedbackCaptureInk.marks(m.strokes); m.durationMs = 200
            let result = try await FeedbackCaptureFinalizer(stages: FeedbackCaptureFinalizer.contextStages()).finish(m,
                context: .init(store: store, finishPasteboardChangeCount: 0), completionState: .recovered)
            #expect(result.state == .recovered && result.strokes == m.strokes)
            #expect(result.keyframes.isEmpty && result.marks.first?.frame == nil)
            let summary = try String(contentsOf: store.mediaURL(id: m.id, path: "summary.md"), encoding: .utf8)
            #expect(summary.contains("✎ marked region"))
            store.release(id: m.id)
        }
    }
    @Test func sharedMarksLinkOnlyWrittenFramesAndNarrationAppearsOnce() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget())
            m.strokes = [feedbackStroke(), feedbackStroke(2000)]
            m.marks = FeedbackCaptureInk.marks(m.strokes)
            m.transcript = .init(source: "fixture", text: "First. Second.", words: [
                .init(t0: 100, t1: 200, text: "First."), .init(t0: 2100, t1: 2200, text: "Second.")
            ], segments: [], estimated: false)
            let first = FeedbackCaptureContext.Thumbnail(t: 200, luma: Array(repeating: 0, count: 64 * 36))
            let last = FeedbackCaptureContext.Thumbnail(t: 2100, luma: first.luma)
            let keyframes = try #require(FeedbackCaptureFinalizer.contextStages().first { $0.name == .keyframes })
            try await keyframes.run(&m, .init(store: store, finishPasteboardChangeCount: 0, thumbnails: [first, last]))
            #expect(m.marks[0].frame != nil && m.marks[0].frame == m.marks[1].frame)
            m.video = "recording.mp4"; m.durationMs = 2750
            try await FeedbackCaptureRendererTests().makeVideo(store.mediaURL(id: m.id, path: "recording.mp4"))
            // The second PNG destination is deliberately unwritable as a file.
            try FileManager.default.createDirectory(at: store.mediaURL(id: m.id, path: "frames/frame-02.png"), withIntermediateDirectories: true)
            let changed = FeedbackCaptureContext.Thumbnail(t: 2100, luma: Array(repeating: 255, count: 64 * 36))
            let result = try await FeedbackCaptureFinalizer(stages: FeedbackCaptureFinalizer.contextStages()).finish(m,
                context: .init(store: store, finishPasteboardChangeCount: 0, thumbnails: [first, changed]))
            #expect(result.keyframes.count == 1)
            #expect(result.marks[0].frame != nil && result.marks[1].frame == nil)
            #expect(result.failures.contains { $0.stage == "render" && $0.message.contains("#2") })
            let summary = try String(contentsOf: store.mediaURL(id: m.id, path: "summary.md"), encoding: .utf8)
            #expect(summary.components(separatedBy: "First.").count == 2)
            #expect(summary.components(separatedBy: "Second.").count == 2)
            let artifactLines = summary.split(separator: "\n").filter { $0.hasPrefix("- #") }
            #expect(summary.contains("✎") && artifactLines.allSatisfy { !$0.contains("frame-02.png") })
            store.release(id: m.id)
        }
    }
    @Test func redInkAvoidsChipAndScalesFromPointDimensions() throws {
        let c = try #require(CGContext(data: nil, width: 1000, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1000, height: 500))
        let stroke = FeedbackCaptureStroke(t0: 0, t1: 100, fw: 500, fh: 250, pts: [200, 400, 0, 5000, 400, 100])
        let image = try FeedbackCaptureRenderer.annotate(try #require(c.makeImage()), index: 1, click: nil, strokes: [stroke])
        let bitmap = NSBitmapImageRep(cgImage: image)
        #expect(bitmap.pixelsWide == 1000 && bitmap.pixelsHigh == 560)
        let red = try #require(bitmap.colorAt(x: 250, y: 80)?.usingColorSpace(.deviceRGB))
        #expect(red.redComponent > 0.9)
        #expect(abs(red.greenComponent - 59.0 / 255) < 0.03)
        #expect(abs(red.blueComponent - 48.0 / 255) < 0.03)
        // A three-point stroke becomes six pixels wide at this 2x export scale.
        for y in [77, 82] {
            let edge = try #require(bitmap.colorAt(x: 250, y: y)?.usingColorSpace(.deviceRGB))
            #expect(edge.redComponent > 0.9)
        }
        for y in [76, 83] {
            let outside = try #require(bitmap.colorAt(x: 250, y: y)?.usingColorSpace(.deviceRGB))
            #expect(outside.redComponent < 0.05)
        }
        let chip = try #require(bitmap.colorAt(x: 16, y: 28)?.usingColorSpace(.deviceRGB))
        #expect(chip.redComponent > 0.9 && chip.greenComponent > 0.9)
    }
    @Test func rendererDecodesAllMarkFramesAndLimitsSheetToTwelve() async throws {
        try await withFeedbackStoreAsync { store, _ in
            var m = try store.begin(target: feedbackTarget())
            let url = try store.mediaURL(id: m.id, path: "recording.mp4")
            try await FeedbackCaptureRendererTests().makeVideo(url)
            m.strokes = (0..<13).map { feedbackStroke(Int64($0 * 100), pin: $0 + 1) }
            m.marks = FeedbackCaptureInk.marks(m.strokes)
            #expect(m.marks.count == 13 && m.marks.compactMap(\.pin) == Array(1...13))
            m.keyframes = m.marks.enumerated().map { i, mark in
                .init(index: i + 1, t: mark.t1, reason: "mark", file: "frames/frame-\(i).png", markId: mark.id, said: "", saidRange: .init(from: 0, to: 0))
            }
            let rendered = try await FeedbackCaptureRenderer.render(m, url: url, cancellation: FeedbackCaptureDecodeCancellation())
            #expect(rendered.frames.count == 13 && rendered.failures.isEmpty)
            for frame in rendered.frames {
                let bitmap = try #require(NSBitmapImageRep(data: frame.png))
                let inkColors = (88..<104).flatMap { y in
                    (56..<72).compactMap { x in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) }
                }
                #expect(inkColors.contains { $0.redComponent > 0.9 && $0.greenComponent < 0.35 && $0.blueComponent < 0.35 },
                    "Rendered frame #\(frame.keyframe.index) must contain its pin, not just the decoded video and chip")
            }
            let firstTwelve = try rendered.frames.prefix(12).map { try #require(NSBitmapImageRep(data: $0.png)?.cgImage) }
            let expectedSheet = try FeedbackCaptureRenderer.contactSheet(firstTwelve)
            let sheetData = try #require(rendered.contactSheet)
            let actualSheet = try #require(NSBitmapImageRep(data: sheetData))
            #expect(actualSheet.pixelsWide == expectedSheet.width && actualSheet.pixelsHigh == expectedSheet.height)
            store.release(id: m.id)
        }
    }
}

@Suite("Scrawl ink input", .serialized)
@MainActor
struct FeedbackCaptureInkInputTests {
    @Test func finishClosesInkAtSharedCutoffAndRejectsRetiredUndo() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let m = try store.begin(target: feedbackTarget())
            let log = try store.mediaURL(id: m.id, path: "events.jsonl")
            let monitor = FeedbackCaptureInputMonitor(target: feedbackTarget(), url: log, origin: { 16000 }, admitted: { true }, onFailure: { Issue.record(Comment(rawValue: $0)) })
            monitor.sample(frame: 16000, x: -960, y: 270, modifiers: [], secureInput: false)
            monitor.sample(frame: 17600, x: -960, y: 270, modifiers: [.shift], secureInput: true)
            monitor.sample(frame: 19200, x: -900, y: 300, modifiers: [.shift], secureInput: true)
            monitor.stop(frame: 20800); await monitor.drain()
            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: m.target)
            #expect(replay.strokes.count == 1 && replay.strokes[0].t1 == 300)
            #expect(replay.inputGaps == [.init(t0: 100, t1: 300)])
            monitor.undo(frame: 22400); await monitor.drain()
            #expect(FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: m.target).strokes.count == 1)
            store.release(id: m.id)
        }
    }
    @Test func pinsAndReleasedDrawingOwnMouseUpAndUndoIsDurable() async throws {
        try await withFeedbackStoreAsync { store, _ in
            let m = try store.begin(target: feedbackTarget())
            let log = try store.mediaURL(id: m.id, path: "events.jsonl")
            let monitor = FeedbackCaptureInputMonitor(target: feedbackTarget(), url: log, origin: { 16000 }, admitted: { true }, onFailure: { Issue.record(Comment(rawValue: $0)) })
            monitor.sample(frame: 16000, x: -960, y: 270, modifiers: [], secureInput: false)
            monitor.receive(.down, frame: 17600, x: -960, y: 270, modifiers: [.shift])
            monitor.receive(.up, frame: 18000, x: -960, y: 270, modifiers: [.shift])
            monitor.sample(frame: 18400, x: -960, y: 270, modifiers: [], secureInput: false)
            monitor.receive(.down, frame: 19200, x: -960, y: 270, modifiers: [.shift])
            monitor.sample(frame: 20000, x: -900, y: 300, modifiers: [.shift], secureInput: false)
            monitor.sample(frame: 20800, x: -900, y: 300, modifiers: [], secureInput: false)
            monitor.receive(.up, frame: 21200, x: -900, y: 300, modifiers: [])
            monitor.undo(frame: 22000)
            monitor.stop(frame: 22400); await monitor.drain()
            let replay = FeedbackCaptureEvents.replay(try Data(contentsOf: log), target: m.target)
            #expect(replay.events.isEmpty && replay.strokes.count == 1)
            #expect(replay.strokes.first?.pin == 1)
            #expect(replay.durationMs == 375)
            store.release(id: m.id)
        }
    }
    @Test func cocoaMappingIgnoresBackingScaleAndHandlesNegativeOrigins() {
        let p = FeedbackCaptureInputMonitor.quartzPoint(cocoa: CGPoint(x: -300, y: 1400), primaryHeight: 1080)
        #expect(p == CGPoint(x: -300, y: -320))
    }
    @Test func drawModifierDefaultsAndCanonicalChoices() throws {
        let old = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(old.feedbackCaptureDrawModifier == .shift)
        #expect(FeedbackCaptureDrawModifier.allCases.map(\.rawValue) == ["shift", "option", "control", "fn"])
        var config = AppConfig(); config.feedbackCaptureDrawModifier = .control
        #expect(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config)).feedbackCaptureDrawModifier == .control)
    }
}
