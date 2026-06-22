import Testing
import Foundation
@testable import MuesliNativeApp

@Suite("Subtitle Timecode")
struct SubtitleTimecodeTests {
    @Test("formats SRT timecode with comma and milliseconds")
    func srtTimecode() {
        #expect(SubtitleTimecode.string(seconds: 0, style: .srt) == "00:00:00,000")
        #expect(SubtitleTimecode.string(seconds: 83.5, style: .srt) == "00:01:23,500")
        #expect(SubtitleTimecode.string(seconds: 3661.25, style: .srt) == "01:01:01,250")
    }

    @Test("formats VTT timecode with dot")
    func vttTimecode() {
        #expect(SubtitleTimecode.string(seconds: 83.5, style: .vtt) == "00:01:23.500")
    }

    @Test("formats inline label HH:MM:SS without fraction")
    func inlineLabel() {
        #expect(SubtitleTimecode.inlineLabel(seconds: 83) == "00:01:23")
        #expect(SubtitleTimecode.inlineLabel(seconds: 3661) == "01:01:01")
    }

    @Test("clamps negatives to zero")
    func clampsNegative() {
        #expect(SubtitleTimecode.string(seconds: -5, style: .srt) == "00:00:00,000")
    }
}
