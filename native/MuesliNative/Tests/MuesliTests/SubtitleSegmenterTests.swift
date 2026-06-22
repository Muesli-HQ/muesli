import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Subtitle Segmenter")
struct SubtitleSegmenterTests {
    @Test("one short line becomes one cue spanning to the next line")
    func basicSpacing() {
        let lines = [
            ParsedTranscriptLine(startSeconds: 0, text: "Hello there."),
            ParsedTranscriptLine(startSeconds: 4, text: "Goodbye."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 6, isWallClock: false)
        #expect(cues.count == 2)
        #expect(cues[0].index == 1)
        #expect(cues[0].start == 0)
        #expect(cues[0].end == 4)
        #expect(cues[1].start == 4)
        #expect(cues[1].end == 6)            // tail clamped to totalDuration
    }

    @Test("a long line splits into multiple short cues with interpolated times")
    func splitsLongLine() {
        // 14 words over 0..7s, maxWords 7 => two cues of 7 words, ~3.5s each.
        let text = (1...14).map { "w\($0)" }.joined(separator: " ")
        let lines = [ParsedTranscriptLine(startSeconds: 0, text: text)]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 7, isWallClock: false, maxWords: 7)
        #expect(cues.count == 2)
        #expect(cues[0].start == 0)
        #expect(abs(cues[0].end - 3.5) < 0.01)
        #expect(abs(cues[1].start - 3.5) < 0.01)
        #expect(cues[1].end == 7)
        #expect(cues[0].text == "w1 w2 w3 w4 w5 w6 w7")
        #expect(cues[1].text == "w8 w9 w10 w11 w12 w13 w14")
        #expect(cues[1].index == 2)          // indices are sequential across splits
    }

    @Test("rebases live wall-clock timestamps to media time zero")
    func rebasesWallClock() {
        // 14:30:00 and 14:30:04 as wall-clock -> 52200s, 52204s; media is 6s long.
        let lines = [
            ParsedTranscriptLine(startSeconds: 52200, text: "Hello there."),
            ParsedTranscriptLine(startSeconds: 52204, text: "Goodbye."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 6, isWallClock: true)
        #expect(cues.first?.start == 0)
        #expect(cues.first?.end == 4)
        #expect(cues.last?.end == 6)
    }

    @Test("does NOT rebase imported elapsed times with a leading offset")
    func keepsLeadingOffset() {
        let lines = [ParsedTranscriptLine(startSeconds: 30, text: "Late start.")]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 300, isWallClock: false)
        #expect(cues.first?.start == 30)   // preserved, not rebased to 0
    }

    @Test("rebases live wall-clock timestamps even when duration is unknown")
    func rebasesWallClockWithoutDuration() {
        // Older/synced live meetings carry wall-clock markers but no known
        // duration (totalDuration 0). The huge leading offset must still rebase.
        let lines = [
            ParsedTranscriptLine(startSeconds: 52200, text: "Hello there."),
            ParsedTranscriptLine(startSeconds: 52204, text: "Goodbye."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 0, isWallClock: true)
        #expect(cues.first?.start == 0)         // rebased to start at zero
        #expect(cues.first?.end == 4)           // content span preserved
        #expect(cues.last!.end < 10)            // far below the 52204s wall-clock
    }

    @Test("rebases a near-midnight live meeting that stays within duration")
    func rebasesMidnightWallClockWithinDuration() {
        // A live meeting started at 00:01:00 stores wall-clock markers
        // [00:01:00] / [00:01:04] (60s, 64s) — numerically below a 600s duration.
        // Because the source is live (isWallClock), they still rebase to media 0.
        let lines = [
            ParsedTranscriptLine(startSeconds: 60, text: "Hello there."),
            ParsedTranscriptLine(startSeconds: 64, text: "Goodbye."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 600, isWallClock: true)
        #expect(cues.first?.start == 0)   // rebased, not 60s late
        #expect(cues.first?.end == 4)
    }

    @Test("does NOT rebase imported elapsed times even when sparse")
    func keepsSparseElapsedWithKnownDuration() {
        // A 1h import silent until 30:00: minStart (1800) dwarfs the speech span,
        // but these are real elapsed media times. An import (isWallClock false)
        // must keep them — the subtitles belong at 30:00, not 0.
        let lines = [
            ParsedTranscriptLine(startSeconds: 1800, text: "Speech starts late."),
            ParsedTranscriptLine(startSeconds: 1804, text: "And continues."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 3600, isWallClock: false)
        #expect(cues.first?.start == 1800)      // NOT rebased to 0
    }

    @Test("does not overlap cues whose lines share a start time")
    func nonOverlappingDuplicateStarts() {
        // Whole-second rounding makes both lines round to start 5; cues must
        // stay non-overlapping with non-decreasing starts.
        let lines = [
            ParsedTranscriptLine(startSeconds: 5, text: "First line here."),
            ParsedTranscriptLine(startSeconds: 5, text: "Second line here."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 12, isWallClock: false)
        #expect(cues.count == 2)
        #expect(cues[1].start >= cues[0].end)   // no overlap
        #expect(cues[0].start <= cues[1].start)  // non-decreasing starts
    }

    @Test("clamps zero-gap cues to a minimum positive duration")
    func clampsMinCueDuration() {
        // Two lines sharing a start time leave no gap; minCueDuration must keep
        // the first cue from collapsing to zero length.
        let lines = [
            ParsedTranscriptLine(startSeconds: 0, text: "First."),
            ParsedTranscriptLine(startSeconds: 0, text: "Second."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 10, isWallClock: false)
        #expect(cues.first!.end > cues.first!.start)
    }

    @Test("preserves leading silence using the meeting start origin")
    func preservesLeadingSilence() {
        // Meeting starts 14:30:00 (origin 52200s); first speech at 14:35:00
        // (52500s). Rebasing against the START — not the first marker — keeps the
        // 300s of leading silence so the first cue lands at 300, not 0.
        let lines = [
            ParsedTranscriptLine(startSeconds: 52500, text: "Hello there."),
            ParsedTranscriptLine(startSeconds: 52504, text: "Goodbye."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 600,
                                          isWallClock: true, wallClockOrigin: 52200)
        #expect(cues.first?.start == 300)   // 52500 - 52200, silence preserved
        #expect(cues.first?.end == 304)
    }

    @Test("falls back to first marker when no origin is supplied")
    func wallClockFallsBackToFirstMarker() {
        // Unparseable start time => nil origin => rebase on the smallest marker so
        // cues still begin near zero rather than 14h into the media.
        let lines = [
            ParsedTranscriptLine(startSeconds: 52500, text: "Hello there."),
            ParsedTranscriptLine(startSeconds: 52504, text: "Goodbye."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 600,
                                          isWallClock: true, wallClockOrigin: nil)
        #expect(cues.first?.start == 0)
        #expect(cues.first?.end == 4)
    }

    @Test("unwraps a live meeting crossing midnight before rebasing")
    func unwrapsMidnightCrossing() {
        // Meeting starts 23:55:00 (origin 86100s). Markers cross midnight:
        // 23:59:58 (86398s) then 00:00:02 wraps to 2s in HH:mm:ss. Unwrapping adds
        // a day to the post-midnight marker so it stays after, not 24h before.
        let lines = [
            ParsedTranscriptLine(startSeconds: 86398, text: "Before midnight."),
            ParsedTranscriptLine(startSeconds: 2, text: "After midnight."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 600,
                                          isWallClock: true, wallClockOrigin: 86100)
        #expect(cues.count == 2)
        #expect(cues[0].start == 298)            // 86398 - 86100
        #expect(cues[1].start == 302)            // (2 + 86400) - 86100, not negative
        #expect(cues[1].start >= cues[0].end)    // monotonic, no 24h blowup
    }

    @Test("lifts a first marker already past midnight using the origin")
    func liftsPostMidnightFirstMarker() {
        // Meeting starts 23:55:00 (origin 86100s). The first — and only — spoken
        // marker is 00:05:00, which parses as 300s. No earlier line exposes the
        // wrap, so the origin floor must push it to the next day: 300 + 86400 -
        // 86100 = 600s of leading silence, not a negative time clamped to 0.
        let lines = [
            ParsedTranscriptLine(startSeconds: 300, text: "Hello after midnight."),
            ParsedTranscriptLine(startSeconds: 320, text: "Still going."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 1200,
                                          isWallClock: true, wallClockOrigin: 86100)
        #expect(cues.first?.start == 600)        // 300 + 86400 - 86100
        #expect(cues.last?.start == 620)
    }

    @Test("does not lift a marker only seconds before the origin")
    func keepsMinorClockSkew() {
        // A marker 1s before the origin is clock skew, not a midnight wrap. The
        // half-day tolerance must leave it alone so it clamps near zero rather
        // than jumping ~24h into the media.
        let lines = [
            ParsedTranscriptLine(startSeconds: 52199, text: "Tiny skew."),
            ParsedTranscriptLine(startSeconds: 52260, text: "One minute in."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 600,
                                          isWallClock: true, wallClockOrigin: 52200)
        #expect(cues.first!.start < 1)           // ~ -1 clamped, not 86399
        #expect(cues.last!.start < 70)           // 52260 - 52200 = 60
    }

    @Test("a small backward step is skew, not a midnight wrap")
    func backwardSkewIsNotMidnight() {
        // Markers normally rise monotonically; a 1s backward step is clock skew,
        // never a real wrap. The half-day tolerance must keep the dipped marker
        // near its neighbours instead of flinging it ~24h into the media.
        let lines = [
            ParsedTranscriptLine(startSeconds: 52260, text: "One minute in."),
            ParsedTranscriptLine(startSeconds: 52259, text: "Tiny dip."),
            ParsedTranscriptLine(startSeconds: 52300, text: "Back on track."),
        ]
        let cues = SubtitleSegmenter.cues(from: lines, totalDuration: 600,
                                          isWallClock: true, wallClockOrigin: 52200)
        #expect(cues.allSatisfy { $0.start < 200 })   // ~60..100s, never 86400+
    }

    @Test("empty input yields no cues")
    func empty() {
        #expect(SubtitleSegmenter.cues(from: [], totalDuration: 10, isWallClock: false).isEmpty)
    }
}
