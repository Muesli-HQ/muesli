import AVFoundation
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Parakeet sliding-window partial session")
struct ParakeetSlidingWindowPartialSessionTests {
    @Test("volatile hypotheses become the tail text")
    func volatileBecomesTail() {
        #expect(ParakeetSlidingWindowPartialSession.tailText(text: "hello wor", isConfirmed: false) == "hello wor")
    }

    @Test("confirmed updates clear the tail — committed captions cover them")
    func confirmedClearsTail() {
        #expect(ParakeetSlidingWindowPartialSession.tailText(text: "hello world", isConfirmed: true) == "")
    }

    @Test("PCM buffer carries the samples at 16 kHz mono")
    func pcmBufferConversion() throws {
        let samples: [Float] = [0.0, 0.25, -0.5, 1.0]
        let buffer = try #require(ParakeetSlidingWindowPartialSession.makePCMBuffer(samples: samples))
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
        #expect(ParakeetSlidingWindowPartialSession.makePCMBuffer(samples: []) == nil)
    }
}
