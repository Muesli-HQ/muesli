import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Subtitle Builder")
struct SubtitleBuilderTests {
    private let cues = [
        SubtitleCue(index: 1, start: 0, end: 3.5, text: "Hello there."),
        SubtitleCue(index: 2, start: 3.5, end: 6, text: "General Kenobi."),
    ]

    @Test("builds valid SRT")
    func srt() {
        let out = SubtitleBuilder.srt(cues: cues)
        let expected = """
        1
        00:00:00,000 --> 00:00:03,500
        Hello there.

        2
        00:00:03,500 --> 00:00:06,000
        General Kenobi.
        """
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("non-empty SRT ends with a trailing blank line")
    func srtTrailingNewline() {
        let out = SubtitleBuilder.srt(cues: cues)
        #expect(out.hasSuffix("\n"))
    }

    @Test("builds valid VTT with header and dot separator")
    func vtt() {
        let out = SubtitleBuilder.vtt(cues: cues)
        #expect(out.hasPrefix("WEBVTT"))
        #expect(out.contains("00:00:00.000 --> 00:00:03.500"))
    }

    @Test("empty cues still produce a WEBVTT header / empty srt")
    func empty() {
        #expect(SubtitleBuilder.srt(cues: []) == "")
        #expect(SubtitleBuilder.vtt(cues: []).hasPrefix("WEBVTT"))
    }
}
