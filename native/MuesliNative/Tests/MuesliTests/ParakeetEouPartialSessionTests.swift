import AVFoundation
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Parakeet EOU partial session")
struct ParakeetEouPartialSessionTests {
    @Test("tail mirrors the accumulated transcript until captions commit")
    func tailMirrorsAccumulated() {
        var tail = ParakeetEouPartialSession.TailState()
        #expect(tail.updated(fullText: "hello") == "hello")
        #expect(tail.updated(fullText: "hello world") == "hello world")
    }

    @Test("boundary freezes the prefix and commit drops it")
    func boundaryAndCommit() {
        var tail = ParakeetEouPartialSession.TailState()
        _ = tail.updated(fullText: "one two")
        tail.markBoundary()
        #expect(tail.updated(fullText: "one two three") == "one two three")
        #expect(tail.commit() == " three")
        #expect(tail.updated(fullText: "one two three four") == " three four")
    }

    @Test("commit without a marked boundary is a no-op")
    func commitWithoutBoundary() {
        var tail = ParakeetEouPartialSession.TailState()
        _ = tail.updated(fullText: "one")
        #expect(tail.commit() == nil)
        #expect(tail.updated(fullText: "one two") == "one two")
    }

    @Test("consecutive commits never rewind an earlier commit point")
    func commitsAreMonotonic() {
        var tail = ParakeetEouPartialSession.TailState()
        _ = tail.updated(fullText: "aaaa")
        tail.markBoundary()
        #expect(tail.commit() == "")
        _ = tail.updated(fullText: "aaaabbbb")
        tail.markBoundary()
        _ = tail.updated(fullText: "aaaabbbbcccc")
        #expect(tail.commit() == "cccc")
    }

    @Test("discardTail treats everything decoded so far as covered")
    func discardTail() {
        var tail = ParakeetEouPartialSession.TailState()
        _ = tail.updated(fullText: "before pause")
        tail.markBoundary()
        tail.discardTail()
        #expect(tail.commit() == nil)
        #expect(tail.updated(fullText: "before pause after") == " after")
    }

    @Test("committed prefix longer than the transcript yields an empty tail")
    func overlongPrefixClamps() {
        var tail = ParakeetEouPartialSession.TailState()
        _ = tail.updated(fullText: "full text here")
        tail.markBoundary()
        _ = tail.commit()
        #expect(tail.updated(fullText: "short") == "")
    }

    @Test("PCM buffer carries the samples at 16 kHz mono")
    func pcmBufferConversion() throws {
        let samples: [Float] = [0.0, 0.25, -0.5, 1.0]
        let buffer = try #require(ParakeetEouPartialSession.makePCMBuffer(samples: samples))
        #expect(buffer.format.sampleRate == 16_000)
        #expect(buffer.format.channelCount == 1)
        #expect(buffer.frameLength == 4)
        let channel = try #require(buffer.floatChannelData?[0])
        for (index, sample) in samples.enumerated() {
            #expect(channel[index] == sample)
        }
    }

    @Test("empty sample batches produce no buffer")
    func emptyBatchProducesNoBuffer() {
        #expect(ParakeetEouPartialSession.makePCMBuffer(samples: []) == nil)
    }
}
