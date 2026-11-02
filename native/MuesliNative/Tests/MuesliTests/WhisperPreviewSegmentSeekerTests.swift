import CoreML
import Foundation
import Testing
import WhisperKit
@testable import MuesliNativeApp

@Suite("Whisper preview alignment")
struct WhisperPreviewSegmentSeekerTests {
    private typealias Seeker = WhisperPreviewSegmentSeeker

    @Test("float16 alignment ignores poisoned physical row padding")
    func paddedFloat16Alignment() throws {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 24 * MemoryLayout<Float16>.stride,
                                                       alignment: MemoryLayout<Float16>.alignment)
        let values = storage.bindMemory(to: Float16.self, capacity: 24)
        values.initialize(repeating: 1000, count: 24)
        let padded = try MLMultiArray(dataPointer: storage, shape: [3, 3], dataType: .float16,
                                     strides: [8, 1], deallocator: { $0.deallocate() })
        let logical: [[Float16]] = [[1, 1, 1], [5, 2, 1], [1, 5, 2]]
        for row in 0..<3 {
            for column in 0..<3 { padded[[NSNumber(value: row), NSNumber(value: column)]] = NSNumber(value: Float(logical[row][column])) }
        }
        let path = try Seeker.alignmentPath(padded, tokenCount: 3)
        #expect(path.textIndices == [0, 1, 1, 2, 2])
        #expect(path.timeIndices == [0, 0, 1, 1, 2])
        #expect(path.cost == -15)
        let cropped = try Seeker.cropAlignment(padded, sampleCount: 960)
        let croppedPath = try Seeker.alignmentPath(cropped, tokenCount: 3)
        #expect(croppedPath.textIndices == path.textIndices)
        #expect(croppedPath.timeIndices == path.timeIndices)
    }

    @Test("IOSurface 750-column alignment matches logical contiguous rows")
    func ioSurfaceAlignment() throws {
        let padded = try MLMultiArray(shape: [41, 750], dataType: .float16, initialValue: Float16(0))
        let contiguous = try MLMultiArray(shape: [41, 750], dataType: .float16)
        for row in 0..<41 {
            for column in 0..<750 {
                let value = NSNumber(value: Float(row == column / 19 ? 1 : 0))
                let index = [NSNumber(value: row), NSNumber(value: column)]
                padded[index] = value
                contiguous[index] = value
            }
        }
        let a = try Seeker.alignmentPath(padded, tokenCount: 41)
        let b = try Seeker.alignmentPath(contiguous, tokenCount: 41)
        #expect(a.textIndices == b.textIndices)
        #expect(a.timeIndices == b.timeIndices)
        #expect(a.cost == b.cost)
    }

    @Test("DTW ties select an actual minimum and zero matrices stay bounded")
    func tiesAndZeros() throws {
        let weights = try MLMultiArray(shape: [3, 3], dataType: .float32)
        let values: [Float] = [-1, 1, -1, -1, -1, -1, -1, -1, -1]
        for index in values.indices { weights[index] = NSNumber(value: values[index]) }
        #expect(try Seeker.alignmentPath(weights, tokenCount: 3).cost == 2)
        for index in values.indices { weights[index] = 0 }
        let zero = try Seeker.alignmentPath(weights, tokenCount: 3)
        #expect(zero.cost == 0)
        #expect(zero.textIndices.first == 0 && zero.timeIndices.first == 0)
        #expect(zero.textIndices.last == 2 && zero.timeIndices.last == 2)
        #expect(Set(zero.textIndices) == Set(0..<3))
        #expect(Seeker.tokenSpans(zero).starts.count == 3)
        #expect(Seeker.tokenSpans(zero).ends.count == 3)
        #expect(throws: WhisperError.self) { try Seeker.alignmentPath(weights, tokenCount: 4) }
        #expect(throws: WhisperError.self) { try Seeker.alignmentPath(weights, tokenCount: 0) }
        weights[0] = NSNumber(value: Float.nan)
        #expect(throws: BufferedTranscriptionPreviewDeferral.self) { try Seeker.alignmentPath(weights, tokenCount: 3) }
    }

    @Test("short audio excludes padded attention and preserves dtype", arguments: [MLMultiArrayDataType.float16, .float32, .double])
    func cropsPaddedAudio(dataType: MLMultiArrayDataType) throws {
        let weights = try MLMultiArray(shape: [2, 1500], dataType: dataType)
        for row in 0..<2 {
            for column in 0..<1500 {
                weights[[NSNumber(value: row), NSNumber(value: column)]] = NSNumber(value: row * 1500 + column)
            }
        }
        let cropped = try Seeker.cropAlignment(weights, sampleCount: 16_000 * 2)
        #expect(cropped.shape.map(\.intValue) == [2, 100])
        #expect(cropped.dataType == dataType)
        for row in 0..<2 {
            for column in 0..<100 {
                let index = [NSNumber(value: row), NSNumber(value: column)]
                #expect(cropped[index] == weights[index])
            }
        }
    }

    @Test("crop reads noncontiguous source strides and returns contiguous weights")
    func stridedSource() throws {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: 16 * MemoryLayout<Float>.stride,
                                                       alignment: MemoryLayout<Float>.alignment)
        let floats = storage.bindMemory(to: Float.self, capacity: 16)
        for index in 0..<16 { floats[index] = Float(index) }
        let weights = try MLMultiArray(dataPointer: storage, shape: [2, 4], dataType: .float32,
                                      strides: [8, 2], deallocator: { $0.deallocate() })
        let cropped = try Seeker.cropAlignment(weights, sampleCount: 1000)
        #expect(cropped.shape.map(\.intValue) == [2, 3])
        #expect(cropped.strides.map(\.intValue) == [3, 1])
        #expect((0..<6).map { cropped[$0].floatValue } == [0, 2, 4, 8, 10, 12])
    }

    @Test("frame cutoff never includes a wholly padded future frame")
    func frameBoundaries() throws {
        let weights = try MLMultiArray(shape: [1, 1500], dataType: .float32)
        for (samples, columns) in [(1, 1), (319, 1), (320, 1), (639, 1), (640, 2), (480_000, 1500), (960_000, 1500)] {
            #expect(try Seeker.cropAlignment(weights, sampleCount: samples).shape[1].intValue == columns)
        }
        #expect(throws: WhisperError.self) { try Seeker.cropAlignment(weights, sampleCount: 0) }
        let invalid = try MLMultiArray(shape: [1, 2, 3], dataType: .float32)
        #expect(throws: WhisperError.self) { try Seeker.cropAlignment(invalid, sampleCount: 16000) }
    }

    @Test("consecutive punctuation retains its lexical predecessor and original token order")
    func punctuationRun() {
        let input = [word("hello", 1, 0.2, 0.6), word("!", 2, 0.6, 0.62), word("?", 3, 0.62, 0.64)]
        let grouped = Seeker.groupPunctuation(input)
        #expect(grouped.map(\.word) == ["hello!?"])
        #expect(grouped.flatMap(\.tokens) == [1, 2, 3])
        #expect(grouped.first?.start == 0.2)
        #expect(grouped.first?.end == 0.64)
    }

    @Test("Unicode punctuation, combining marks and repeated words preserve exact text")
    func multilingualCoverage() {
        let input = [word("“", 1, 0, 0), word("cafe\u{301}", 2, 0.1, 0.4),
                     word("”、", 3, 0.4, 0.42), word(" go", 4, 0.5, 0.8),
                     word(" go", 5, 0.9, 1.1), word("؟", 6, 1.1, 1.1)]
        let grouped = Seeker.groupPunctuation(input)
        #expect(grouped.map(\.word).joined().utf8.elementsEqual(input.map(\.word).joined().utf8))
        #expect(grouped.flatMap(\.tokens) == input.flatMap(\.tokens))
        #expect(grouped.map(\.word) == ["“cafe\u{301}”、", " go", " go؟"])
        #expect(grouped.last?.end == 1.1)
    }

    @Test("punctuation-only and empty alignments do not silently lose tokens")
    func punctuationOnly() {
        #expect(Seeker.groupPunctuation([]).isEmpty)
        let grouped = Seeker.groupPunctuation([word("!", 1, 0, 0), word("?", 2, 0, 0)])
        #expect(grouped.map(\.word) == ["!?"])
        #expect(grouped.flatMap(\.tokens) == [1, 2])
    }

    @Test("coverage allows only whitespace omission, rejecting lexical loss, duplication and reordering")
    func tokenCoverage() {
        let spellings = [1: "hello", 2: "!", 3: "?", 4: " ", 5: "你好", 6: ""]
        let decode: ([Int]) -> String = { $0.map { spellings[$0] ?? "unknown" }.joined() }
        #expect(Seeker.coversTokens(original: [4, 1, 2, 3, 4], aligned: [1, 2, 3], decode: decode))
        #expect(Seeker.coversTokens(original: [1, 1], aligned: [1, 1], decode: decode))
        for aligned in [[2, 3], [1, 2], [1, 1, 2, 3], [1, 3, 2]] {
            #expect(!Seeker.coversTokens(original: [1, 2, 3], aligned: aligned, decode: decode))
        }
        #expect(!Seeker.coversTokens(original: [5], aligned: [], decode: decode))
        #expect(!Seeker.coversTokens(original: [6], aligned: [], decode: decode))
    }

    private func word(_ text: String, _ token: Int, _ start: Float, _ end: Float) -> WordTiming {
        WordTiming(word: text, tokens: [token], start: start, end: end, probability: 0.9)
    }
}
