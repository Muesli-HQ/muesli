import Foundation
import Testing
@testable import MuesliCore

@Suite("Scrawl context")
struct FeedbackCaptureContextTests {
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
        #expect(!summary.contains("captures zoom"))
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
