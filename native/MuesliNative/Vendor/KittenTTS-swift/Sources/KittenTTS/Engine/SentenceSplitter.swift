import Foundation

/// Splits text into sentence-sized chunks suitable for progressive TTS generation.
///
/// Used by ``KittenTTS/generateStreaming(_:voice:speed:)`` to break long texts
/// into pieces that can be synthesised and yielded independently.
enum SentenceSplitter {

    /// Split text into sentences, merging very short ones to ensure each chunk
    /// is long enough for natural-sounding speech output.
    ///
    /// - Parameter text: The input text to split.
    /// - Returns: An array of sentence strings. Never empty if `text` is non-empty.
    static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""

        for char in text {
            current.append(char)
            if ".!?".contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }

        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            if sentences.isEmpty {
                sentences.append(remaining)
            } else {
                sentences[sentences.count - 1] += " " + remaining
            }
        }

        // Merge short sentences so each chunk has enough text for
        // natural-sounding TTS output.
        var merged: [String] = []
        var buffer = ""
        for sentence in sentences {
            buffer += (buffer.isEmpty ? "" : " ") + sentence
            if buffer.count >= 200 {
                merged.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            if merged.isEmpty {
                merged.append(buffer)
            } else {
                merged[merged.count - 1] += " " + buffer
            }
        }

        return merged.isEmpty ? [text] : merged
    }
}
