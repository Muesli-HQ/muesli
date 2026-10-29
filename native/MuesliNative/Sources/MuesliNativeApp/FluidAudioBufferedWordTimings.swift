import Foundation
import FluidAudio

/// Matches FluidAudio's word boundaries and spans while retaining the weakest
/// constituent token confidence. An invalid score makes the whole word unknown.
enum FluidAudioBufferedWordTimings {
    static func build(from tokenTimings: [TokenTiming]) -> [BufferedTranscriptionWord] {
        var words: [BufferedTranscriptionWord] = []
        var currentWord = ""
        var wordStart: TimeInterval = 0
        var wordEnd: TimeInterval = 0
        var confidence: Float?

        func flush() {
            let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            words.append(.init(text: trimmed, start: wordStart, end: wordEnd, confidence: confidence))
        }

        for timing in tokenTimings {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }
            let startsNewWord = isWordBoundary(token) || currentWord.isEmpty
            if startsNewWord && !currentWord.isEmpty {
                flush()
                currentWord = ""
            }
            let tokenConfidence: Float? = timing.confidence.isFinite && (0...1).contains(timing.confidence)
                ? timing.confidence : nil
            if startsNewWord {
                currentWord = stripWordBoundaryPrefix(token)
                wordStart = timing.startTime
                confidence = tokenConfidence
            } else {
                currentWord += token
                if let previous = confidence, let tokenConfidence {
                    confidence = min(previous, tokenConfidence)
                } else {
                    confidence = nil
                }
            }
            wordEnd = timing.endTime
        }
        flush()
        return words
    }
}
