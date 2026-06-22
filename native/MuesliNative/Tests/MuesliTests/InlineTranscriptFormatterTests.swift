import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Inline Transcript Formatter")
struct InlineTranscriptFormatterTests {
    @Test("prefixes each grouped line with its start timecode")
    func prefixesTimecode() {
        let segments = [
            SpeechSegment(start: 0, end: 2.0, text: "Hello there."),
            SpeechSegment(start: 2.0, end: 4.0, text: "This is a test."),
        ]
        let out = InlineTranscriptFormatter.timestampedTranscript(from: segments)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == "[00:00:00] Hello there.")
        #expect(lines.contains("[00:00:02] This is a test."))
    }

    @Test("groups tiny fragments up to the sentence boundary")
    func groupsFragments() {
        let segments = [
            SpeechSegment(start: 0, end: 0.4, text: "Hello"),
            SpeechSegment(start: 0.4, end: 0.9, text: "there"),
            SpeechSegment(start: 0.9, end: 1.4, text: "world."),
        ]
        let out = InlineTranscriptFormatter.timestampedTranscript(from: segments)
        // One sentence => one line, timestamped at the first fragment's start.
        #expect(out == "[00:00:00] Hello there world.")
    }

    @Test("empty segments produce empty string")
    func empty() {
        #expect(InlineTranscriptFormatter.timestampedTranscript(from: []) == "")
    }

    @Test("falls back to flat text when no usable segments but text exists")
    func fallback() {
        // A single huge no-punctuation segment still yields one timestamped line.
        let segments = [SpeechSegment(start: 0, end: 5, text: "one two three four five")]
        let out = InlineTranscriptFormatter.timestampedTranscript(from: segments)
        #expect(out == "[00:00:00] one two three four five")
    }

    @Test("uses timestamped lines for single-speaker, passes through multi-speaker text")
    func selectionPolicy() {
        let segments = [SpeechSegment(start: 0, end: 2, text: "Hello there.")]
        let single = InlineTranscriptFormatter.transcriptForStorage(
            segments: segments, multiSpeakerText: nil, fallbackText: "Hello there.")
        #expect(single == "[00:00:00] Hello there.")

        let multi = InlineTranscriptFormatter.transcriptForStorage(
            segments: segments,
            multiSpeakerText: "[00:00:00] Speaker 1: Hello there.",
            fallbackText: "Hello there.")
        #expect(multi == "[00:00:00] Speaker 1: Hello there.")

        let none = InlineTranscriptFormatter.transcriptForStorage(
            segments: [], multiSpeakerText: nil, fallbackText: "raw flat text")
        #expect(none == "raw flat text")
    }

    @Test("startOffsetSeconds shifts labels to wall-clock time-of-day")
    func wallClockOffset() {
        // A live meeting started at 14:30:00 (52200s). Elapsed segments at 0s/5s
        // must read as wall-clock [14:30:00] / [14:30:05] so subtitle export's
        // source-based rebase recovers media time.
        let segments = [
            SpeechSegment(start: 0, end: 2, text: "Hello there."),
            SpeechSegment(start: 5, end: 7, text: "Second sentence."),
        ]
        let out = InlineTranscriptFormatter.timestampedTranscript(from: segments, startOffsetSeconds: 52200)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == "[14:30:00] Hello there.")
        #expect(lines.contains("[14:30:05] Second sentence."))
    }

    @Test("splits a long unpunctuated run at the word cap into multiple lines")
    func splitsAtWordCap() {
        // 50 single-word segments with no sentence punctuation: the running word
        // count crosses maxLineWords (40) and flushes mid-stream, so the output
        // breaks into more than one line.
        let segments = (1...50).map {
            SpeechSegment(start: Double($0), end: Double($0) + 0.5, text: "w\($0)")
        }
        let out = InlineTranscriptFormatter.timestampedTranscript(from: segments)
        let lines = out.split(separator: "\n")
        #expect(lines.count > 1)
    }
}
