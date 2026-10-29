import Foundation
import Testing
@testable import MuesliCore

@Suite("Scrawl context")
struct FeedbackCaptureContextTests {
    @Test(arguments: [Int64(1000), 1001])
    func zoomKeepsExplicitEndpointMarkOrNamesItsOmission(videoDuration: Int64) throws {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.durationMs = 1000
        m.strokes = [.init(t0: 1000, t1: 1000, fw: 100, fh: 100, pin: 7, pts: [5000, 5000, 0])]
        m.marks = FeedbackCaptureInk.marks(m.strokes)
        m.events = [.click(t: 1000, x: 0.5, y: 0.5, button: 0)]
        m.transcript = .init(source: "fixture", text: "endpoint", words: [.init(t0: 1000, t1: 1000, text: "endpoint")], segments: [], estimated: false)
        let zoom = try FeedbackCaptureContext.zoom(m, mark: 1, videoDurationMs: videoDuration)
        if videoDuration == 1000 {
            #expect(zoom.failures.map(\.message) == ["Scrawl mark m1 omitted: no playable source time."])
        } else {
            #expect(zoom.frames.first { $0.markIds.contains("m1") }?.t == 1000 && zoom.failures.isEmpty)
        }
        #expect(zoom.words.isEmpty && zoom.frames.allSatisfy { $0.eventIndices.isEmpty })
        let incidental = try FeedbackCaptureContext.zoom(m, at: "0:01", videoDurationMs: videoDuration)
        #expect(incidental.words.isEmpty && incidental.frames.allSatisfy { $0.markIds.isEmpty && $0.eventIndices.isEmpty })
        #expect(incidental.failures.isEmpty)
    }
    @Test func zoomReservesRequestedMarkAndReportsBoundedEvidenceDeterministically() throws {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.durationMs = 10000; m.videoOffsetMs = 900
        m.strokes = (0..<8).map { i in .init(t0: Int64(1000 + i * 100), t1: Int64(1000 + i * 100),
            fw: 100, fh: 100, pin: i + 1, pts: [5000, 5000, 0]) }
        m.strokes.append(.init(t0: 1700, t1: 1700, fw: 100, fh: 100, pin: 9, pts: [2000, 2000, 0]))
        m.marks = FeedbackCaptureInk.marks(m.strokes)
        m.events = [1700, 1700, 1750, 800].map { .click(t: Int64($0), x: 0.5, y: 0.5, button: 0) }
        let zoom = try FeedbackCaptureContext.zoom(m, mark: 8, videoDurationMs: 5000)
        #expect(zoom.times == [1200, 1300, 1400, 1500, 1600, 1700])
        #expect(zoom.frames.last?.markIds == ["m8", "m9"] && zoom.frames.last?.eventIndices == [0, 1])
        #expect(zoom.failures.map(\.message) == [
            "Scrawl mark m2 omitted: six-frame limit.", "Scrawl mark m1 omitted: six-frame limit.",
            "Scrawl click event 3 omitted: six-frame limit.", "Scrawl click event 4 omitted: no playable source time."])
        m.marks = []; m.strokes = []
        m.events = [1700, 2300, 2200, 1800, 2100, 1900, 2000, 800].map { .click(t: Int64($0), x: 0.5, y: 0.5, button: 0) }
        let clicks = try FeedbackCaptureContext.zoom(m, at: "0:02", videoDurationMs: 5000)
        #expect(clicks.frames.flatMap(\.eventIndices) == [0, 3, 5, 6, 4, 2])
        #expect(clicks.failures.count == 2)
        let stroke = FeedbackCaptureStroke(t0: 100, t1: 500, fw: 1, fh: 1, pin: 7, pts: [0, 0, 0, 5000, 5000, 200, 10000, 10000, 400])
        let clipped = try #require(FeedbackCaptureContext.clippedInk(stroke, to: 200...400))
        #expect(clipped.t0 == 100 && clipped.t1 == 500 && clipped.pin == 7 && clipped.pts == [5000, 5000, 200])
        #expect(FeedbackCaptureContext.clippedInk(stroke, to: 101...299) == nil)
    }
    @Test("Scrawl timestamp bounds and evenly spaced samples", arguments: [
        ("0:00", Int64(0), Int64(2000)), ("0:03", 1000, 5000), ("0:10", 8000, 10000)
    ])
    func zoomTimestamp(at: String, start: Int64, end: Int64) throws {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.durationMs = 10000
        let zoom = try FeedbackCaptureContext.zoom(m, at: at, videoDurationMs: 11000)
        #expect(zoom.t0 == start && zoom.t1 == end)
        #expect(zoom.times.count == 6 && Set(zoom.times).count == 6)
        #expect(zoom.times.first == start && zoom.times.last == end)
        let gaps = zip(zoom.times, zoom.times.dropFirst()).map { $1 - $0 }
        #expect(gaps.max()! - gaps.min()! <= 1)
    }
    @Test func zoomRejectsBadSelectorsAndClipsOnlyVideoSampling() throws {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.durationMs = 10000; m.videoOffsetMs = 1250
        for at in ["-1:00", "0:1", "0:60", "1:00", "1:000", " 0:00", "0:00\n", "9223372036854775807:00", "153722867280912:59"] {
            #expect(throws: FeedbackCaptureContext.ZoomError.self) { try FeedbackCaptureContext.zoom(m, at: at, videoDurationMs: 5000) }
        }
        #expect(throws: FeedbackCaptureContext.ZoomError.self) { try FeedbackCaptureContext.zoom(m, videoDurationMs: 5000) }
        #expect(throws: FeedbackCaptureContext.ZoomError.self) { try FeedbackCaptureContext.zoom(m, at: "0:00", mark: 1, videoDurationMs: 5000) }
        for mark in [0, -1] {
            #expect(throws: FeedbackCaptureContext.ZoomError.self) { try FeedbackCaptureContext.zoom(m, mark: mark, videoDurationMs: 5000) }
        }
        #expect(throws: FeedbackCaptureContext.ZoomError.self) { try FeedbackCaptureContext.zoom(m, at: "0:09", videoDurationMs: 5000) }
        #expect(throws: FeedbackCaptureContext.ZoomError.self) { try FeedbackCaptureContext.zoom(m, at: "0:00", videoDurationMs: 0) }
        let clipped = try FeedbackCaptureContext.zoom(m, at: "0:00", videoDurationMs: 5000)
        #expect(clipped.t0 == 0 && clipped.t1 == 2000 && clipped.times.first == 1250)
        m.videoOffsetMs = -500
        #expect(try FeedbackCaptureContext.zoom(m, at: "0:03", videoDurationMs: 3000).times.last == 2499)
        m.durationMs = Int64.max; m.videoOffsetMs = 0
        m.strokes = [.init(t0: Int64.max - 10, t1: Int64.max, fw: 1, fh: 1, pts: [0, 0, 0])]
        m.marks = FeedbackCaptureInk.marks(m.strokes)
        let extreme = try FeedbackCaptureContext.zoom(m, mark: 1, videoDurationMs: Int64.max)
        #expect(extreme.t1 == Int64.max && extreme.times.last == Int64.max - 1)
        m.durationMs = 0
        #expect(throws: FeedbackCaptureContext.ZoomError.self) { try FeedbackCaptureContext.zoom(m, at: "0:00", videoDurationMs: 1) }
    }
    @Test func zoomUsesStableMarkAndAllOverlappingWordsOnceWithOriginalTimes() throws {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.durationMs = 10000
        m.strokes = [.init(t0: 2000, t1: 5000, fw: 100, fh: 100, pin: 7, pts: [5000, 5000, 0])]
        m.marks = FeedbackCaptureInk.marks(m.strokes)
        let words: [FeedbackCaptureTranscript.Span] = [
            .init(t0: 0, t1: 1000, text: "before"), .init(t0: 500, t1: 1001, text: "crossing"),
            .init(t0: 1000, t1: 1000, text: "zero"), .init(t0: 900, t1: 6100, text: "spanning"),
            .init(t0: 5999, t1: 7000, text: "after"), .init(t0: 6000, t1: 6000, text: "outside")]
        m.transcript = .init(source: "fixture", text: "unused full text", words: words, segments: [], estimated: true)
        let zoom = try FeedbackCaptureContext.zoom(m, mark: 1, videoDurationMs: 11000)
        #expect(zoom.t0 == 1000 && zoom.t1 == 6000)
        #expect(zoom.words == Array(words[1...4]))
        #expect(zoom.said == "crossing zero spanning after" && zoom.estimated && zoom.missing == nil)
        #expect(throws: FeedbackCaptureContext.ZoomError.self) { try FeedbackCaptureContext.zoom(m, mark: 7, videoDurationMs: 11000) }
        m.transcript = .unavailable("fixture model missing")
        let missing = try FeedbackCaptureContext.zoom(m, mark: 1, videoDurationMs: 11000)
        #expect(missing.words.isEmpty && missing.said.isEmpty && missing.estimated)
        #expect(missing.missing?.reason == "fixture model missing")
        m.durationMs = 1; m.strokes = []; m.marks = []
        let tiny = try FeedbackCaptureContext.zoom(m, at: "0:00", videoDurationMs: 1)
        #expect(tiny.times == [0])
    }
    typealias Thumbnail = FeedbackCaptureContext.Thumbnail
    func thumbs(_ values: [UInt8]) -> [Thumbnail] {
        values.enumerated().map { .init(t: Int64($0.offset * 250), luma: [UInt8](repeating: $0.element, count: 64 * 36)) }
    }
    @Test("Budget grows after forty seconds and caps at twelve", arguments: [
        [0, 6], [40_000, 6], [40_001, 7], [60_000, 7], [60_001, 8], [600_000, 12]
    ])
    func budget(fixture: [Int]) {
        #expect(FeedbackCaptureContext.budget(durationMs: Int64(fixture[0])) == fixture[1])
    }
    @Test func staticScreenKeepsThreeActionReferencesAndNoPauseCuts() {
        let thumbnails = (0..<160).map { Thumbnail(t: Int64($0 * 250), luma: [UInt8](repeating: 64, count: 64 * 36)) }
        let events = [1000, 10_000, 30_000].map { FeedbackCaptureEvent.click(t: Int64($0), x: 0.5, y: 0.5, button: 0) }
        let selected = FeedbackCaptureContext.select(durationMs: 40_000, events: events, thumbnails: thumbnails)
        #expect(selected.count == 4)
        #expect(selected.compactMap(\.eventIndex) == [0, 1, 2])
        #expect(selected.filter { $0.eventIndex != nil }.map(\.time) == [1250, 10_250, 30_250])
        #expect(selected.filter { $0.eventIndex != nil }.map(\.anchor) == [1000, 10_000, 30_000])
        #expect(selected.filter { $0.eventIndex != nil }.allSatisfy { $0.score == 60 })
    }
    @Test func sceneCandidatesWaitForSettlingAndActionWinsDeduplication() {
        let thumbnails = thumbs([0, 0, 255, 255, 255, 255, 0, 128, 0, 128])
        let scenes = FeedbackCaptureContext.select(durationMs: 2500, events: [], thumbnails: thumbnails)
        #expect(scenes.contains { $0.reason == "scene_change" && $0.anchor == 500 && $0.time == 1000 })
        #expect(!scenes.contains { $0.anchor >= 1500 })
        let actions = FeedbackCaptureContext.select(durationMs: 2500,
            events: [.click(t: 500, x: 0.2, y: 0.2, button: 0)], thumbnails: thumbnails)
        #expect(actions.filter { $0.eventIndex != nil }.map(\.eventIndex) == [0])
        #expect(actions.first { $0.eventIndex == 0 }?.score == 90)
        #expect(actions.filter { $0.reason == "scene_change" }.isEmpty)
    }
    @Test("Partition backs to punctuation, segments or pauses, and never loses a word", arguments: [0, 1, 2])
    func partition(boundary: Int) {
        let words: [FeedbackCaptureTranscript.Span] = [
            .init(t0: 0, t1: 100, text: "First"), .init(t0: 200, t1: 300, text: boundary == 0 ? "clause." : "clause"),
            .init(t0: boundary == 2 ? 1800 : 400, t1: 1900, text: "Then"), .init(t0: 2000, t1: 2100, text: "change"),
            .init(t0: 2200, t1: 2300, text: "this.")
        ]
        let transcript = FeedbackCaptureTranscript(source: "fixture", text: words.map(\.text).joined(separator: " "), words: words,
            segments: boundary == 1 ? [.init(t0: 400, t1: 2300, text: "Then change this.")] : [], estimated: boundary == 2)
        let fixtures: [(anchors: [Int64], from: [Int], to: [Int])] = [
            ([0, 2050, 2051, 99_000], [0, 2, 2, 5], [2, 2, 5, 5]),
            // Inside the word before a clause boundary, then at/inside the final word.
            ([0, 250, 2200, 2250, 99_000], [0, 0, 2, 2, 5], [0, 2, 2, 5, 5])
        ]
        for fixture in fixtures {
            let ranges = FeedbackCaptureContext.partition(transcript: transcript, anchors: fixture.anchors)
            #expect(ranges.map(\.from) == fixture.from)
            #expect(ranges.map(\.to) == fixture.to)
            #expect(ranges.flatMap { Array($0.from..<$0.to) } == Array(words.indices))
            let candidates = fixture.anchors.map {
                FeedbackCaptureContext.Candidate(anchor: $0, time: $0, reason: "click", eventIndex: nil, score: 1)
            }
            let frames = FeedbackCaptureContext.keyframes(candidates, transcript: transcript)
            #expect(frames.map(\.said).filter { !$0.isEmpty }.joined(separator: " ") == transcript.text)
        }
        // Exercise narration lengths once; each clause boundary is covered above.
        if boundary == 0 {
            for count in [0, 1, 10, 70] {
                let words = (0..<count).map { FeedbackCaptureTranscript.Span(t0: Int64($0 * 100), t1: Int64($0 * 100 + 90), text: "w\($0)") }
                let transcript = FeedbackCaptureTranscript(source: "fixture", text: words.map(\.text).joined(separator: " "), words: words, segments: [], estimated: true)
                for anchors: [Int64] in [[0], [0, 50, 70, 80], [0, 120, 900, 2000, 99_000]] {
                    let ranges = FeedbackCaptureContext.partition(transcript: transcript, anchors: anchors)
                    #expect(ranges.flatMap { Array($0.from..<$0.to) } == Array(0..<count))
                    #expect(ranges.count == anchors.count)
                }
            }
        }
    }
    @Test("Narration follows anchor order while keyframes retain display order")
    func keyframesAssignNarrationByAnchorWhileKeepingDisplayOrder() {
        let words: [FeedbackCaptureTranscript.Span] = [
            .init(t0: 0, t1: 100, text: "Before."),
            .init(t0: 500, t1: 600, text: "Start."),
            .init(t0: 1200, t1: 1300, text: "Moving."),
            .init(t0: 2200, t1: 2300, text: "Settled."),
            .init(t0: 5000, t1: 5100, text: "Done.")
        ]
        let transcript = FeedbackCaptureTranscript(source: "fixture", text: words.map(\.text).joined(separator: " "),
            words: words, segments: [], estimated: false)
        let candidates = [
            FeedbackCaptureContext.Candidate(anchor: 0, time: 0, reason: "initial", eventIndex: nil, score: 1),
            FeedbackCaptureContext.Candidate(anchor: 2000, time: 2300, reason: "scene_change", eventIndex: nil, score: 1),
            FeedbackCaptureContext.Candidate(anchor: 1000, time: 5250, reason: "drag", eventIndex: 0, score: 1)
        ]

        let frames = FeedbackCaptureContext.keyframes(candidates, transcript: transcript)

        #expect(frames.map(\.t) == [0, 2300, 5250])
        #expect(frames.map(\.said) == ["Before. Start.", "Settled. Done.", "Moving."])
        #expect(frames.map(\.saidRange) == [
            .init(from: 0, to: 2), .init(from: 3, to: 5), .init(from: 2, to: 3)
        ])
    }
    @Test func partialRenderPresentationRetainsOnlyUnillustratedWordsAndIndependentMetadata() {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.transcript = .init(source: "fixture", text: "First Missing middle Last", words: [
            .init(t0: 0, t1: 100, text: "First"), .init(t0: 200, t1: 300, text: "Missing"),
            .init(t0: 400, t1: 500, text: "middle"), .init(t0: 600, t1: 700, text: "Last")], segments: [], estimated: true)
        m.keyframes = [
            .init(index: 1, t: 0, reason: "initial", file: "frames/frame-01.png", said: "First", saidRange: .init(from: 0, to: 1)),
            .init(index: 3, t: 600, reason: "click", file: "frames/frame-03.png", said: "Last", saidRange: .init(from: 3, to: 4))]
        let partial = FeedbackCaptureContext.unillustratedNarration(m)
        #expect(partial.text == "Missing middle")
        #expect(partial.estimated && partial.missingReason == nil)
        m.keyframes[0].saidRange = .init(from: 0, to: 4)
        #expect(FeedbackCaptureContext.unillustratedNarration(m).text.isEmpty)
        #expect(FeedbackCaptureContext.unillustratedNarration(m).estimated)
        m.transcript = .unavailable("Model unavailable")
        let missing = FeedbackCaptureContext.unillustratedNarration(m)
        #expect(missing.text.isEmpty && !missing.estimated)
        #expect(missing.missingReason == "Model unavailable")
        m.transcript = .init(source: "legacy", text: "Legacy narration", words: [], segments: [], estimated: true)
        #expect(FeedbackCaptureContext.unillustratedNarration(m).text == "Legacy narration")
    }
    @Test func summaryUsesAbsoluteArtifactPathsAndRetainsUnillustratedNarration() {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.durationMs = 33_000
        m.transcript = .init(source: "fixture", text: "Open this. Then stop.", words: [
            .init(t0: 0, t1: 100, text: "Open"), .init(t0: 200, t1: 300, text: "this."),
            .init(t0: 400, t1: 500, text: "Then"), .init(t0: 600, t1: 700, text: "stop.")], segments: [], estimated: false)
        m.events = [.click(t: 0, x: 0.51, y: 0.12, button: 0)]
        m.keyframes = [.init(index: 1, t: 250, reason: "click", file: "frames/frame-01.png", eventIndex: 0,
            said: "Open this.", saidRange: .init(from: 0, to: 2))]
        m.contactSheet = "contact-sheet.png"
        let summary = FeedbackCaptureContext.summary(m, bundle: URL(fileURLWithPath: "/tmp/fixture.capture"))
        #expect(summary.contains("[muesli Scrawl 0:33"))
        #expect(summary.contains("0:33 · Fixture Editor · /tmp/fixture.capture"))
        #expect(summary.contains("/tmp/fixture.capture/contact-sheet.png"))
        #expect(summary.contains("/tmp/fixture.capture/frames/frame-01.png"))
        #expect(summary.contains("[clicked x 0.51, y 0.12]"))
        #expect(summary.contains("Unillustrated narration: “Then stop.”"))
        #expect(summary.components(separatedBy: "Open this.").count == 2)
        #expect(summary.contains("muesli-cli captures zoom \(m.id) --at M:SS"))
    }
    @Test("Summary identifies estimated narration timing even when all words are illustrated")
    func summaryMarksEstimatedTimingForFullyIllustratedNarration() {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.transcript = .init(source: "fixture", text: "Open this.", words: [
            .init(t0: 0, t1: 100, text: "Open"), .init(t0: 200, t1: 300, text: "this.")
        ], segments: [], estimated: true)
        m.keyframes = [.init(index: 1, t: 250, reason: "click", file: "frames/frame-01.png",
            said: "Open this.", saidRange: .init(from: 0, to: 2))]

        let summary = FeedbackCaptureContext.summary(m, bundle: URL(fileURLWithPath: "/tmp/fixture.capture"))

        #expect(summary.contains("Estimated timing: word-to-image matches use approximate timestamps."))
    }
}
