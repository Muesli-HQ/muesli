import Foundation

/// One subtitle cue with absolute start/end (seconds from media start) and text.
struct SubtitleCue: Equatable {
    var index: Int
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleTimecode {
    enum Style { case srt, vtt }

    /// Cue timecode, e.g. "00:01:23,500" (srt) or "00:01:23.500" (vtt).
    static func string(seconds: Double, style: Style) -> String {
        let clamped = max(0, seconds)
        let totalMillis = Int((clamped * 1000).rounded())
        let ms = totalMillis % 1000
        let totalSeconds = totalMillis / 1000
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        let fractionSeparator = style == .srt ? "," : "."
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, fractionSeparator, ms)
    }

    /// Inline transcript label, e.g. "00:01:23" (no fraction).
    static func inlineLabel(seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalSeconds = Int(clamped.rounded(.down))
        let s = totalSeconds % 60
        let m = (totalSeconds / 60) % 60
        let h = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
