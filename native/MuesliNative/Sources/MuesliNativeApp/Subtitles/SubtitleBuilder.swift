import Foundation

enum SubtitleBuilder {
    static func srt(cues: [SubtitleCue]) -> String {
        guard !cues.isEmpty else { return "" }
        let body = cues.map { cue in
            let start = SubtitleTimecode.string(seconds: cue.start, style: .srt)
            let end = SubtitleTimecode.string(seconds: cue.end, style: .srt)
            return "\(cue.index)\n\(start) --> \(end)\n\(cue.text)"
        }.joined(separator: "\n\n")
        // SRT convention: terminate the final cue with a blank line so strict
        // parsers don't drop it.
        return body + "\n"
    }

    static func vtt(cues: [SubtitleCue]) -> String {
        var blocks = ["WEBVTT"]
        for cue in cues {
            let start = SubtitleTimecode.string(seconds: cue.start, style: .vtt)
            let end = SubtitleTimecode.string(seconds: cue.end, style: .vtt)
            blocks.append("\(start) --> \(end)\n\(cue.text)")
        }
        return blocks.joined(separator: "\n\n")
    }
}
