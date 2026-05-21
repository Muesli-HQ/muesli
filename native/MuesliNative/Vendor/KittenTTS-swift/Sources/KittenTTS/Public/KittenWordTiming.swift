import Foundation

/// Timing information for a single word in the synthesised audio.
///
/// Word timings are derived from the model's predicted phoneme durations
/// and allow precise synchronisation of text highlighting with audio playback.
///
/// ```swift
/// let result = try await tts.generate("Hello world")
/// for timing in result.wordTimings {
///     print("\(timing.word): \(timing.startTime)s – \(timing.endTime)s")
/// }
/// ```
public struct KittenWordTiming: Sendable, Equatable {
    /// Zero-based index of this word in the input text (split by whitespace).
    public let wordIndex: Int
    /// The word text from the original input.
    public let word: String
    /// Start time in seconds within the generated audio.
    public let startTime: Double
    /// End time in seconds within the generated audio.
    public let endTime: Double

    public init(wordIndex: Int, word: String, startTime: Double, endTime: Double) {
        self.wordIndex = wordIndex
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Computes per-word timestamps from the model's predicted phoneme durations.
///
/// This is a Swift port of `KPipeline.join_timestamps` from the Python Kokoro
/// pipeline. The algorithm walks the duration tensor (one entry per input token)
/// and maps contiguous phoneme spans back to words in the original text.
///
/// The conversion factor from duration frames to seconds is 1/80:
/// the model operates at 24 kHz with a hop-based framing that yields
/// 1 frame = 1/40 s; the algorithm tracks half-frames, so the final
/// divisor is 80.
enum TimestampJoiner {

    /// Join per-token durations with the phoneme string to produce word-level timestamps.
    ///
    /// - Parameters:
    ///   - inputText: The original (un-preprocessed) text, used to extract word strings.
    ///   - phonemes: The IPA phoneme string (spaces delimit word boundaries).
    ///   - durations: The `duration` output from the ONNX model (`Int64`, one per input token
    ///     including start/end/pad tokens).
    /// - Returns: An array of ``KittenWordTiming`` values, one per word. Empty if
    ///   durations are unavailable or the text could not be aligned.
    static func joinTimestamps(
        inputText: String,
        phonemes: String,
        durations: [Int64]
    ) -> [KittenWordTiming] {
        let magicDivisor: Double = 80.0

        // Split phonemes by space to get per-word phoneme groups.
        let phonemeGroups = phonemes.components(separatedBy: " ").filter { !$0.isEmpty }
        guard !phonemeGroups.isEmpty, durations.count >= 3 else { return [] }

        // Split original text into words for display strings.
        let words = inputText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        var timings: [KittenWordTiming] = []

        // Initial offset from the start token (index 0 in durations).
        var left  = 2.0 * Double(max(0, Int(durations[0]) - 3))
        var right = left
        var i = 1 // current index into durations (skip start token)

        for (groupIdx, group) in phonemeGroups.enumerated() {
            let phonemeCount = group.unicodeScalars.count
            guard i + phonemeCount <= durations.count else { break }

            let startTs = left / magicDivisor

            // Sum durations for this word's phoneme tokens.
            var tokenDur: Int64 = 0
            for j in i..<(i + phonemeCount) {
                tokenDur += durations[j]
            }

            // Space token follows all words except the last.
            let hasSpace = (groupIdx < phonemeGroups.count - 1)
            let spaceDur: Int64 = (hasSpace && i + phonemeCount < durations.count)
                ? durations[i + phonemeCount]
                : 0

            left  = right + Double(2 * tokenDur) + Double(spaceDur)
            let endTs = left / magicDivisor
            right = left + Double(spaceDur)

            let wordString = groupIdx < words.count ? words[groupIdx] : group
            timings.append(KittenWordTiming(
                wordIndex: groupIdx,
                word: wordString,
                startTime: startTs,
                endTime: endTs
            ))

            i += phonemeCount + (hasSpace ? 1 : 0)
        }

        return timings
    }
}
