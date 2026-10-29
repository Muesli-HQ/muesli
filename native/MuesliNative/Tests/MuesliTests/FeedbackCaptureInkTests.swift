import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

func feedbackStroke(_ t: Int64 = 100, pin: Int? = nil, x: Int = 2000) -> FeedbackCaptureStroke {
    .init(t0: t, t1: t + 100, fw: 1000, fh: 500, pin: pin,
          pts: pin == nil ? [x, 2000, 0, x + 1000, 4000, 100] : [x, 2000, 0])
}

@Suite("Scrawl ink")
struct FeedbackCaptureInkTests {
    let target = FeedbackCaptureTarget(displayId: 1, frame: .init(x: -1000, y: -500, width: 1000, height: 500, scale: 2), appName: "Fixture")
    @Test func releaseArmingExclusiveModifierAndStationaryCapitals() {
        var ink = FeedbackCaptureInk(target: target)
        _ = ink.sample(t: 0, x: -900, y: -400, modifiers: [.shift])
        _ = ink.sample(t: 10, x: -800, y: -300, modifiers: [.shift])
        #expect(ink.sample(t: 20, x: -800, y: -300, modifiers: []) == nil)
        _ = ink.sample(t: 30, x: -900, y: -400, modifiers: [.shift, .option])
        #expect(ink.sample(t: 40, x: -800, y: -300, modifiers: []) == nil)
        _ = ink.sample(t: 50, x: -900, y: -400, modifiers: [.shift])
        #expect(ink.sample(t: 60, x: -900, y: -400, modifiers: []) == nil)
        _ = ink.sample(t: 70, x: -900, y: -400, modifiers: [.shift])
        _ = ink.sample(t: 80, x: -890, y: -390, modifiers: [.shift])
        let stroke = ink.sample(t: 90, x: -890, y: -390, modifiers: [])
        #expect(stroke?.pts == [1000, 2000, 0, 1100, 2200, 10])
        #expect(stroke?.fw == 1000 && stroke?.fh == 500)
    }
    @Test func delayedPointerDownKeepsStrokeSamplesMonotonic() throws {
        var ink = FeedbackCaptureInk(target: target)
        _ = ink.sample(t: 0, x: -900, y: -400, modifiers: [])
        _ = ink.sample(t: 10, x: -900, y: -400, modifiers: [.shift])
        _ = ink.sample(t: 20, x: -890, y: -390, modifiers: [.shift])

        #expect(ink.pointer(.down, t: 15, x: -880, y: -380, modifiers: [.shift]).owned)
        #expect(ink.pointer(.up, t: 16, x: -880, y: -380, modifiers: [.shift]).owned)
        let finished = ink.finish(t: 30)
        let stroke = try #require(finished)
        let encoded = try JSONEncoder().encode(stroke)
        let decoded = try JSONDecoder().decode(FeedbackCaptureStroke.self, from: encoded)
        #expect(decoded.pts == [1000, 2000, 0, 1100, 2200, 10])
    }
    @Test(arguments: [5.9, 6.0]) func boundsThreshold(distance: Double) {
        var ink = FeedbackCaptureInk(target: target)
        _ = ink.sample(t: 0, x: -900, y: -400, modifiers: [])
        _ = ink.sample(t: 10, x: -900, y: -400, modifiers: [.shift])
        _ = ink.sample(t: 20, x: -900 + distance, y: -400, modifiers: [.shift])
        #expect((ink.finish(t: 30) != nil) == (distance >= 6))
    }
    @Test func excludedAndOffTargetSamplesFinishStrokesBeforeResuming() {
        var ink = FeedbackCaptureInk(target: target)
        _ = ink.sample(t: 0, x: -900, y: -400, modifiers: [])
        _ = ink.sample(t: 10, x: -900, y: -400, modifiers: [.shift])
        _ = ink.sample(t: 20, x: -890, y: -400, modifiers: [.shift])
        let excluded = ink.sample(t: 30, x: -880, y: -400, modifiers: [.shift], excluded: true)
        #expect(excluded?.t0 == 10 && excluded?.t1 == 30)
        #expect(ink.strokes.count == 1 && ink.liveStroke == nil)

        _ = ink.sample(t: 40, x: -870, y: -400, modifiers: [.shift])
        _ = ink.sample(t: 50, x: -860, y: -400, modifiers: [.shift])
        let outside = ink.sample(t: 60, x: 1, y: 1, modifiers: [.shift])
        #expect(outside?.t0 == 40 && outside?.t1 == 60)
        #expect(ink.strokes.count == 2 && ink.liveStroke == nil)
    }
    @Test func samplingCapAndOutsideTarget() {
        var ink = FeedbackCaptureInk(target: target, modifier: .fn)
        _ = ink.sample(t: 0, x: -900, y: -400, modifiers: [])
        _ = ink.sample(t: 1, x: -900, y: -400, modifiers: [.fn])
        _ = ink.sample(t: 2, x: -893.6, y: -400, modifiers: [.fn])
        #expect(ink.liveStroke?.pts.count == 6)
        let outside = ink.sample(t: 3, x: 1, y: 1, modifiers: [.fn])
        #expect(outside?.t0 == 1 && outside?.t1 == 3)
        #expect(ink.strokes.count == 1 && ink.liveStroke == nil)
        for i in 4...3001 { _ = ink.sample(t: Int64(i), x: i.isMultiple(of: 2) ? -900 : -800, y: -400, modifiers: [.fn]) }
        #expect(ink.finish(t: 3002)?.pts.count == 2400 * 3)
        #expect(ink.strokes.count == 2)
    }
    @Test(arguments: [(11.9, Int64(1000), true), (12.0, Int64(1000), false), (0.0, Int64(1001), false)])
    func pinsOwnTheirGesture(travel: Double, duration: Int64, pins: Bool) {
        var ink = FeedbackCaptureInk(target: target)
        _ = ink.sample(t: 0, x: -900, y: -400, modifiers: [])
        #expect(ink.pointer(.down, t: 10, x: -900, y: -400, modifiers: [.shift]).owned)
        _ = ink.pointer(.moved, t: 20, x: -900 + travel, y: -400, modifiers: [.shift])
        let result = ink.pointer(.up, t: 10 + duration, x: -900, y: -400, modifiers: [.shift])
        #expect(result.owned)
        #expect((result.stroke?.pin == 1) == pins)
    }
    @Test func pinsCanRepeatUntilActualInkBegins() {
        var ink = FeedbackCaptureInk(target: target)
        _ = ink.sample(t: 0, x: -900, y: -400, modifiers: [])
        _ = ink.pointer(.down, t: 10, x: -900, y: -400, modifiers: [.shift])
        #expect(ink.pointer(.up, t: 20, x: -900, y: -400, modifiers: [.shift]).stroke?.pin == 1)
        _ = ink.pointer(.down, t: 30, x: -900, y: -400, modifiers: [.shift])
        #expect(ink.pointer(.up, t: 40, x: -900, y: -400, modifiers: [.shift]).stroke?.pin == 2)
        _ = ink.sample(t: 50, x: -900, y: -400, modifiers: [.shift])
        _ = ink.sample(t: 60, x: -880, y: -380, modifiers: [.shift])
        _ = ink.pointer(.down, t: 70, x: -880, y: -380, modifiers: [.shift])
        #expect(ink.pointer(.up, t: 80, x: -880, y: -380, modifiers: [.shift]).stroke == nil)
        let drawn = ink.finish(t: 90)
        #expect(drawn != nil && drawn?.pin == nil)
        ink.undo()
        #expect(ink.strokes.map(\.pin) == [1, 2])
        ink.undo(); ink.undo()
        #expect(ink.strokes.isEmpty)
    }
    @Test(arguments: [Int64(1199), Int64(1200)]) func groupingGapBoundary(gap: Int64) {
        let boundary = FeedbackCaptureInk.marks([feedbackStroke(100), feedbackStroke(200 + gap)])
        #expect(boundary.count == (gap < 1200 ? 1 : 2))
        let strokes = (0..<7).map { feedbackStroke(Int64($0 * 200)) } + [feedbackStroke(1500, pin: 1), feedbackStroke(2800)]
        let marks = FeedbackCaptureInk.marks(strokes)
        #expect(marks.map(\.strokes.count) == [6, 1, 1, 1])
        #expect(marks.map(\.id) == ["m1", "m2", "m3", "m4"])
        #expect(marks.dropFirst(2).first?.description == "pin 1")
    }
}

@Suite("Scrawl ink overlay")
struct FeedbackCaptureInkOverlayTests {
    let target = FeedbackCaptureTarget(displayId: 1,
        frame: .init(x: -1000, y: -500, width: 1000, height: 500, scale: 2), appName: "Fixture")

    @Test @MainActor func idleTicksDoNotInvalidateOverlayPanels() {
        let overlay = FeedbackCaptureInkOverlay(target: target)
        defer { overlay.stop() }

        #expect(!overlay.update(strokes: [], live: nil, t: 0))
        #expect(!overlay.update(strokes: [], live: nil, t: 8))
    }

    @Test @MainActor func fadingInkInvalidatesOnceWhenItDisappears() {
        let overlay = FeedbackCaptureInkOverlay(target: target)
        defer { overlay.stop() }
        let stroke = FeedbackCaptureStroke(t0: 0, t1: 0, fw: 100, fh: 100,
            pts: [1000, 1000, 0, 9000, 9000, 100])

        #expect(overlay.update(strokes: [stroke], live: nil, t: 650))
        #expect(overlay.update(strokes: [stroke], live: nil, t: 1300))
        #expect(!overlay.update(strokes: [stroke], live: nil, t: 1301))
    }

    @Test @MainActor func pinRingClearsAfterItsShorterVisibilityWindow() {
        let overlay = FeedbackCaptureInkOverlay(target: target)
        defer { overlay.stop() }
        let pin = FeedbackCaptureStroke(t0: 0, t1: 0, fw: 100, fh: 100, pin: 1,
            pts: [1000, 1000, 0])

        #expect(overlay.update(strokes: [pin], live: nil, t: 349))
        #expect(overlay.update(strokes: [pin], live: nil, t: 350))
        #expect(!overlay.update(strokes: [pin], live: nil, t: 351))
    }
}

@Suite("Scrawl ink persistence")
struct FeedbackCaptureInkPersistenceTests {
    @Test(arguments: [false, true])
    func undoMissingOrInvalidStrokePreservesEarlierInk(invalidRecord: Bool) throws {
        let encoder = JSONEncoder()
        let earlier = feedbackStroke(100), missing = feedbackStroke(300), later = feedbackStroke(600)
        var data = Data()
        func append(_ record: FeedbackCaptureJournalRecord) throws {
            data.append(try encoder.encode(record)); data.append(10)
        }
        let click = FeedbackCaptureEvent.click(t: 10, x: 0.1, y: 0.2, button: 0)
        try append(.pointer(click))
        try append(.stroke(earlier))
        // A failed append can omit the entire stroke, or leave a complete invalid record.
        if invalidRecord { data.append(Data("{\"kind\":\"stroke\",\"stroke\":{}}\n".utf8)) }
        try append(.undo(500, stroke: missing))
        try append(.stroke(later))
        try append(.undo(800, stroke: later))
        try append(.gap(t: 900, unavailable: true))
        data.append(Data("{bad}\n{\"kind\":\"stroke\"".utf8))
        let replay = FeedbackCaptureEvents.replay(data, target: feedbackTarget())
        #expect(replay.events == [click])
        #expect(replay.strokes == [earlier], "Undo must not remove unrelated surviving ink when its target was not persisted")
        #expect(replay.durationMs == 900 && replay.gapStart == 900)
        #expect(replay.failures.count == (invalidRecord ? 3 : 2))

        // Older journals still use the time-only undo wire shape.
        var legacy = try encoder.encode(FeedbackCaptureJournalRecord.stroke(earlier)); legacy.append(10)
        legacy.append(Data("{\"kind\":\"undo\",\"t\":500}\n".utf8))
        #expect(FeedbackCaptureEvents.replay(legacy, target: feedbackTarget()).strokes.isEmpty)
    }
    @Test func strokeOnlyRecoveryRetainsContentDurationAndValidatesMarkPaths() throws {
        try withFeedbackStore { store, _, _ in
            var m = try store.begin(target: feedbackTarget())
            var data = try JSONEncoder().encode(FeedbackCaptureJournalRecord.stroke(feedbackStroke(300)))
            data.append(10)
            data.append(try JSONEncoder().encode(FeedbackCaptureJournalRecord.gap(t: 350, unavailable: true))); data.append(10)
            try data.write(to: store.mediaURL(id: m.id, path: "events.jsonl"))
            let result = store.reconcileMedia(m, audioDuration: { _ in nil }, videoDuration: { _ in nil })
            #expect(result.retainsContent && result.manifest.durationMs == 400)
            #expect(result.manifest.strokes.count == 1 && result.manifest.marks.count == 1)
            #expect(result.manifest.inputGaps == [.init(t0: 350, t1: 400)])
            m = result.manifest; m.marks[0].frame = "../escape.png"
            #expect(throws: (any Error).self) { try store.save(m) }
            store.release(id: m.id)
        }
    }
    @Test func additiveManifestAndFlatTriplesRoundTrip() throws {
        var m = FeedbackCaptureManifest(id: "fixture", createdAtMs: 0, target: feedbackTarget())
        m.strokes = [feedbackStroke()]; m.marks = FeedbackCaptureInk.marks(m.strokes)
        let data = try JSONEncoder().encode(m)
        #expect(try JSONDecoder().decode(FeedbackCaptureManifest.self, from: data) == m)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "strokes"); json.removeValue(forKey: "marks")
        let old = try JSONDecoder().decode(FeedbackCaptureManifest.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.strokes.isEmpty && old.marks.isEmpty)
    }
}
