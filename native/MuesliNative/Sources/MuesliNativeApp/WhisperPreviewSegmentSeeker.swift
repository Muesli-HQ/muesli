// Alignment and token-span handling adapted from WhisperKit SegmentSeeker.swift
// (80d96762fa727f816ffceab76a6529cd12c2726f).
// MIT License
// Copyright (c) 2024 argmax, inc.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

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
        let tokens = segments.flatMap(\.tokens)
        guard !tokens.isEmpty else { return segments }
        var logProbs: [Float] = []
        for segment in segments {
            guard segment.tokenLogProbs.count == segment.tokens.count else {
                throw BufferedTranscriptionPreviewDeferral.textAlignmentMismatch
            }
            for (index, token) in segment.tokens.enumerated() {
                guard let probability = segment.tokenLogProbs[index][token] else {
                    throw BufferedTranscriptionPreviewDeferral.textAlignmentMismatch
                }
                logProbs.append(probability)
            }
        }
        // The pinned seeker's filter allocates IOSurface-backed float16 rows,
        // then memcpy copies as if row stride == column count. Real-frame crops
        // such as 750 columns have padded destination rows and become corrupted.
        // Align logical rows directly; keep the upstream word-duration policy.
        let path = try Self.alignmentPath(weights, tokenCount: tokens.count)
        let split = tokenizer.splitToWordTokens(tokenIds: tokens)
        guard split.words.count == split.wordTokens.count,
              split.wordTokens.flatMap({ $0 }) == tokens else {
            throw BufferedTranscriptionPreviewDeferral.textAlignmentMismatch
        }
        let spans = Self.tokenSpans(path)
        guard spans.starts.count == tokens.count, spans.ends.count == tokens.count else {
            throw BufferedTranscriptionPreviewDeferral.invalidWordTimings
        }
        var offset = 0
        var alignment: [WordTiming] = []
        for (word, wordTokens) in zip(split.words, split.wordTokens) {
            guard !wordTokens.isEmpty else { continue }
            let end = offset + wordTokens.count
            let probability = exp(logProbs[offset..<end].reduce(0, +) / Float(wordTokens.count))
            alignment.append(WordTiming(word: word, tokens: wordTokens,
                start: spans.starts[offset], end: spans.ends[end - 1], probability: probability))
            offset = end
        }
        let durations = base.calculateWordDurationConstraints(alignment: alignment)
        alignment = base.truncateLongWordsAtSentenceBoundaries(alignment, maxDuration: durations.max)
        var result = base.updateSegmentsWithWordTimings(segments: segments,
            mergedAlignment: alignment, seek: seek, lastSpeechTimestamp: lastSpeechTimestamp,
            constrainedMedianDuration: durations.median, maxDuration: durations.max, tokenizer: tokenizer)
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

    struct AlignmentPath {
        let textIndices: [Int]
        let timeIndices: [Int]
        let cost: Double
    }

    /// Read through CoreML's callback strides, never physical contiguous offsets.
    /// Token rows start at zero because these previews do not prepend promptTokens.
    static func alignmentPath(_ weights: MLMultiArray, tokenCount: Int) throws -> AlignmentPath {
        guard weights.shape.count == 2, tokenCount > 0,
              tokenCount <= weights.shape[0].intValue, weights.shape[1].intValue > 0 else {
            throw WhisperError.segmentingFailed("Invalid preview token alignment shape")
        }
        let columns = weights.shape[1].intValue
        var values = [Double](repeating: 0, count: tokenCount * columns)
        var supported = true
        weights.withUnsafeMutableBytes { bytes, strides in
            for row in 0..<tokenCount {
                for column in 0..<columns {
                    let index = row * strides[0] + column * strides[1]
                    let value: Double
                    switch weights.dataType {
                    case .float16: value = Double(bytes.bindMemory(to: Float16.self)[index])
                    case .float32: value = Double(bytes.bindMemory(to: Float.self)[index])
                    case .double: value = bytes.bindMemory(to: Double.self)[index]
                    default: supported = false; value = .nan
                    }
                    values[row * columns + column] = value
                }
            }
        }
        guard supported, values.allSatisfy(\.isFinite) else {
            throw BufferedTranscriptionPreviewDeferral.invalidWordTimings
        }
        let width = columns + 1
        var trace = [UInt8](repeating: 2, count: (tokenCount + 1) * width)
        var previous = [Double](repeating: .infinity, count: width)
        previous[0] = 0
        for row in 1...tokenCount {
            trace[row * width] = 1
            var current = [Double](repeating: .infinity, count: width)
            for column in 1...columns {
                let diagonal = previous[column - 1]
                let up = previous[column]
                let left = current[column - 1]
                let minimum = min(diagonal, min(up, left))
                // Keep upstream tie preference when it is a true minimum;
                // diagonal == up < left must never choose the larger left cost.
                trace[row * width + column] = left == minimum ? 2 : (up == minimum ? 1 : 0)
                current[column] = minimum - values[(row - 1) * columns + column - 1]
            }
            previous = current
        }
        var row = tokenCount
        var column = columns
        var text: [Int] = []
        var times: [Int] = []
        while row > 0 || column > 0 {
            text.append(row - 1)
            times.append(column - 1)
            switch trace[row * width + column] {
            case 0: row -= 1; column -= 1
            case 1: row -= 1
            default: column -= 1
            }
        }
        return AlignmentPath(textIndices: Array(text.reversed()), timeIndices: Array(times.reversed()), cost: previous[columns])
    }

    static func tokenSpans(_ path: AlignmentPath) -> (starts: [Float], ends: [Float]) {
        var starts: [Float] = [0]
        var ends: [Float] = []
        var previous = path.textIndices.first ?? 0
        for index in path.textIndices.indices where path.textIndices[index] != previous {
            previous = path.textIndices[index]
            let seconds = Float(path.timeIndices[index]) * Float(WhisperKit.secondsPerTimeToken)
            starts.append(seconds)
            ends.append(seconds)
        }
        ends.append(Float(path.timeIndices.last ?? 0) * Float(WhisperKit.secondsPerTimeToken))
        return (starts, ends)
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
