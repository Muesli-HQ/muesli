import CoreML
import Foundation
import WhisperKit

/// Preview alignment must exclude the encoder's padded audio. The pinned
/// WhisperKit seeker otherwise aligns short clips against its entire 30 s grid.
final class WhisperPreviewSegmentSeeker: SegmentSeeking {
    private let base = SegmentSeeker()

    func findSeekPointAndSegments(
        decodingResult: DecodingResult, options: DecodingOptions, allSegmentsCount: Int,
        currentSeek: Int, segmentSize: Int, sampleRate: Int, timeToken: Int,
        specialToken: Int, tokenizer: WhisperTokenizer
    ) -> (Int, [TranscriptionSegment]?) {
        base.findSeekPointAndSegments(decodingResult: decodingResult, options: options,
            allSegmentsCount: allSegmentsCount, currentSeek: currentSeek,
            segmentSize: segmentSize, sampleRate: sampleRate, timeToken: timeToken,
            specialToken: specialToken, tokenizer: tokenizer)
    }

    func addWordTimestamps(
        segments: [TranscriptionSegment], alignmentWeights: MLMultiArray,
        tokenizer: WhisperTokenizer, seek: Int, segmentSize: Int,
        prependPunctuations: String, appendPunctuations: String,
        lastSpeechTimestamp: Float, options: DecodingOptions, timings: TranscriptionTimings
    ) throws -> [TranscriptionSegment]? {
        let weights = try Self.cropAlignment(alignmentWeights, sampleCount: segmentSize)
        // Empty sets bypass the pinned seeker's lossy punctuation merge. Its
        // final filter then removes only empty strings, not punctuation tokens.
        guard var result = try base.addWordTimestamps(segments: segments,
            alignmentWeights: weights, tokenizer: tokenizer, seek: seek,
            segmentSize: segmentSize, prependPunctuations: "", appendPunctuations: "",
            lastSpeechTimestamp: lastSpeechTimestamp, options: options, timings: timings) else { return nil }
        for index in result.indices {
            let words = result[index].words ?? []
            let original = result[index].tokens.filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            guard Self.coversTokens(original: original, aligned: words.flatMap(\.tokens),
                                   decode: { tokenizer.decode(tokens: $0) }) else {
                throw BufferedTranscriptionPreviewDeferral.textAlignmentMismatch
            }
            result[index].words = Self.groupPunctuation(words)
        }
        return result
    }

    /// One encoder frame spans 320 samples / 20 ms. Keep only complete real
    /// audio frames, with one frame for a sub-frame clip. No output timestamp is
    /// moved: DTW is recomputed using the surviving attention evidence.
    static func cropAlignment(_ source: MLMultiArray, sampleCount: Int) throws -> MLMultiArray {
        guard source.shape.count == 2, sampleCount > 0,
              source.shape[0].intValue > 0, source.shape[1].intValue > 0,
              source.strides.count == 2, source.strides.allSatisfy({ $0.intValue > 0 }) else {
            throw WhisperError.segmentingFailed("Invalid preview attention shape or audio length")
        }
        let rows = source.shape[0].intValue
        let columns = min(source.shape[1].intValue, max(1, sampleCount / 320))
        let bytes: Int
        switch source.dataType {
        case .float16: bytes = 2
        case .float32, .int32: bytes = 4
        case .double: bytes = 8
        default: throw WhisperError.segmentingFailed("Unsupported preview attention data type")
        }
        let result = try MLMultiArray(shape: [NSNumber(value: rows), NSNumber(value: columns)], dataType: source.dataType)
        let rowStride = source.strides[0].intValue
        let columnStride = source.strides[1].intValue
        let destinationRowStride = result.strides[0].intValue
        for row in 0..<rows {
            let input = source.dataPointer.advanced(by: row * rowStride * bytes)
            let output = result.dataPointer.advanced(by: row * destinationRowStride * bytes)
            if columnStride == 1 {
                memcpy(output, input, columns * bytes)
            } else {
                for column in 0..<columns {
                    memcpy(output.advanced(by: column * bytes),
                           input.advanced(by: column * columnStride * bytes), bytes)
                }
            }
        }
        return result
    }

    /// The upstream splitter may discard whitespace-only tokens. Any missing
    /// lexical or punctuation token, extra token, or reordered token is invalid.
    static func coversTokens(original: [Int], aligned: [Int], decode: ([Int]) -> String) -> Bool {
        func whitespaceOnly(_ tokens: ArraySlice<Int>) -> Bool {
            guard !tokens.isEmpty else { return true }
            let text = decode(Array(tokens))
            return !text.isEmpty && text.allSatisfy(\.isWhitespace)
        }
        var cursor = 0
        for token in aligned {
            guard let next = original[cursor...].firstIndex(of: token) else { return false }
            if !whitespaceOnly(original[cursor..<next]) { return false }
            cursor = next + 1
        }
        return whitespaceOnly(original[cursor...])
    }

    /// Keep punctuation with a lexical neighbor so it cannot become a separate
    /// ownership anchor. Concatenation conserves every original token and byte;
    /// combined spans are the union of the supplied spans, never interpolation.
    static func groupPunctuation(_ words: [WordTiming]) -> [WordTiming] {
        var result: [WordTiming] = []
        var leading: WordTiming?
        for word in words {
            let punctuation = word.word.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }
            if punctuation {
                if !result.isEmpty {
                    result[result.count - 1] = joined(result[result.count - 1], word)
                } else {
                    leading = leading.map { joined($0, word) } ?? word
                }
            } else {
                result.append(leading.map { joined($0, word) } ?? word)
                leading = nil
            }
        }
        if let leading { result.append(leading) }
        return result
    }

    private static func joined(_ lhs: WordTiming, _ rhs: WordTiming) -> WordTiming {
        WordTiming(word: lhs.word + rhs.word, tokens: lhs.tokens + rhs.tokens,
            start: min(lhs.start, rhs.start), end: max(lhs.end, rhs.end),
            probability: min(lhs.probability, rhs.probability))
    }
}
