import Foundation

public enum InsightsWordAnalyzer {
    public static func frequencies(in text: String, limit: Int = 48) -> [InsightsWordFrequency] {
        var counts: [String: Int] = [:]
        InsightsTextAnalysis.accumulate(text, into: &counts)
        return ranked(counts, limit: limit)
    }

    public static func meetingFrequencies(in transcript: String, limit: Int = 48) -> [InsightsWordFrequency] {
        frequencies(in: cleanedMeetingTranscript(transcript), limit: limit)
    }

    static func accumulateMeetingTranscript(_ transcript: String, into counts: inout [String: Int]) {
        InsightsTextAnalysis.accumulate(cleanedMeetingTranscript(transcript), into: &counts)
    }

    static func cleanedMeetingTranscript(_ transcript: String) -> String {
        let withoutSpeakerLabels = transcript.replacingOccurrences(
            of: #"(?im)^\s*(?:\[[^\]\n]+\]\s*)?(?:speaker\s*\d+|you|others)\s*:\s*"#,
            with: "",
            options: .regularExpression
        )
        return withoutSpeakerLabels.replacingOccurrences(
            of: #"(?i)\[(?:blank_audio|music playing|audience laughing|applause|laughter|inaudible|silence)[^\]]*\]"#,
            with: " ",
            options: .regularExpression
        )
    }

    static func accumulate(_ text: String, into counts: inout [String: Int]) {
        InsightsTextAnalysis.accumulate(text, into: &counts)
    }

    static func ranked(_ counts: [String: Int], limit: Int) -> [InsightsWordFrequency] {
        var frequencies = counts.map { word, count in
            InsightsWordFrequency(word: word, count: count)
        }
        frequencies.sort {
            if $0.count == $1.count { return $0.word < $1.word }
            return $0.count > $1.count
        }
        return Array(frequencies.prefix(max(0, limit)))
    }
}
