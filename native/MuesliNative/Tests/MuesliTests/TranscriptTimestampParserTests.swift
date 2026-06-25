import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Transcript Timestamp Parser")
struct TranscriptTimestampParserTests {
    @Test("parses HH:MM:SS lines without speaker")
    func parsesPlain() {
        let raw = "[00:00:00] Hello there.\n[00:00:02] Second line."
        let lines = TranscriptTimestampParser.parse(raw)
        #expect(lines.count == 2)
        #expect(lines[0].startSeconds == 0)
        #expect(lines[0].text == "Hello there.")
        #expect(lines[1].startSeconds == 2)
    }

    @Test("parses HH:MM:SS lines with speaker prefix, dropping the label")
    func parsesSpeaker() {
        let raw = "[00:01:05] Speaker 1: How are you?"
        let lines = TranscriptTimestampParser.parse(raw)
        #expect(lines.count == 1)
        #expect(lines[0].startSeconds == 65)
        #expect(lines[0].text == "How are you?")
    }

    @Test("accepts MM:SS as well as HH:MM:SS")
    func parsesShortForm() {
        let raw = "[01:05] Hi."
        let lines = TranscriptTimestampParser.parse(raw)
        #expect(lines[0].startSeconds == 65)
    }

    @Test("ignores lines without a leading timestamp")
    func ignoresUntimed() {
        let raw = "No timestamp here.\n[00:00:03] Timed."
        let lines = TranscriptTimestampParser.parse(raw)
        #expect(lines.count == 1)
        #expect(lines[0].startSeconds == 3)
    }

    @Test("returns empty for transcript with no timestamps")
    func noTimestamps() {
        #expect(TranscriptTimestampParser.parse("Just plain text, no markers.").isEmpty)
    }
}
