// Evaluation-only port of the Apache-2.0 Hugging Face Gemma4 audio frontend.
// Reference provenance and unvalidated encoder status are recorded in README.md.
import Foundation
import MLX
import Accelerate

public enum GemmaAudioError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): return message } }
}

public struct GemmaAudioFeatures {
    public struct Configuration: Codable, Sendable, Equatable {
        public var sampleRate = 16000
        public var frameLength = 320
        public var hopLength = 160
        public var fftLength = 512
        public var melBins = 128
        public var minimumFrequency: Double = 0
        public var maximumFrequency: Double = 8000
        public var melFloor: Float = 0.001
        public var preemphasis: Float = 0
        public var htkPreemphasis = true
        public var inputScale: Float = 1
        public var perBinMean: [Float]? = nil
        public var perBinStandardDeviation: [Float]? = nil
        public var padToMultiple = 128
        public var maximumSamples = 480000
        public init() {}
    }
    public struct Output {
        public let features: MLXArray // [1, frames, mel bins]
        public let mask: [Bool]
    }
    public let config: Configuration
    private let filters: [Double]
    private let window: [Float]
    public init(configuration c: Configuration = .init()) throws {
        guard c.sampleRate == 16000, c.frameLength > 0, c.hopLength > 0,
              c.fftLength >= c.frameLength, c.fftLength.nonzeroBitCount == 1,
              c.melBins > 0, c.padToMultiple > 0, c.maximumSamples > c.frameLength,
              c.minimumFrequency >= 0, c.maximumFrequency <= Double(c.sampleRate) / 2,
              c.minimumFrequency < c.maximumFrequency, c.melFloor.isFinite, c.melFloor > 0,
              c.inputScale.isFinite, c.preemphasis.isFinite, (0...1).contains(c.preemphasis),
              c.perBinMean.map({ $0.count == c.melBins && $0.allSatisfy(\.isFinite) }) ?? true,
              c.perBinStandardDeviation.map({ $0.count == c.melBins && $0.allSatisfy { $0.isFinite && $0 > 0 } }) ?? true
        else { throw GemmaAudioError.invalid("Unsupported or invalid Gemma audio feature configuration") }
        config = c
        window = (0..<c.frameLength).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(c.frameLength))) }
        let low = 2595 * log10(1 + c.minimumFrequency / 700)
        let high = 2595 * log10(1 + c.maximumFrequency / 700)
        let points = (0..<(c.melBins + 2)).map { i in 700 * (pow(10, (low + Double(i) * (high-low) / Double(c.melBins+1)) / 2595) - 1) }
        var bank = [Double]()
        for bin in 0...(c.fftLength / 2) {
            let frequency = Double(bin) * Double(c.sampleRate) / Double(c.fftLength)
            for mel in 0..<c.melBins {
                let up = (frequency-points[mel]) / (points[mel+1]-points[mel])
                let down = (points[mel+2]-frequency) / (points[mel+2]-points[mel+1])
                bank.append(max(0, min(up, down)))
            }
        }
        filters = bank
    }
    /// Single-clip evaluation. Reject oversize clips instead of silently truncating dictation.
    public func extract(samples: [Float], sampleRate: Int) throws -> Output {
        let c = config
        guard sampleRate == c.sampleRate, !samples.isEmpty, samples.count <= c.maximumSamples,
              samples.allSatisfy(\.isFinite) else {
            throw GemmaAudioError.invalid("Expected finite, nonempty 16 kHz mono audio within the duration limit")
        }
        let paddedCount = ((samples.count + c.padToMultiple - 1) / c.padToMultiple) * c.padToMultiple
        let left = c.frameLength / 2
        let count = max(0, (paddedCount + left - (c.frameLength + 1)) / c.hopLength + 1)
        guard paddedCount + left >= c.frameLength + 1, count > 0 else {
            throw GemmaAudioError.invalid("Clip too short for a Gemma analysis frame")
        }
        func sample(_ i: Int) -> Float { i >= 0 && i < samples.count ? samples[i] * c.inputScale : 0 }
        var frames = [Float](), mask = [Bool]()
        frames.reserveCapacity(count * c.frameLength)
        for frame in 0..<count {
            let start = frame * c.hopLength - left
            let end = start + c.frameLength
            mask.append(end >= 0 && end < samples.count)
            for j in 0..<c.frameLength {
                var value = sample(start+j)
                if c.preemphasis > 0 {
                    if c.htkPreemphasis { value = j == 0 ? value * (1-c.preemphasis) : value - c.preemphasis * sample(start+j-1) }
                    else { value = sample(start+j+1) - c.preemphasis * value }
                }
                frames.append(value * window[j])
            }
        }
        // The reference applies a Float32 window but NumPy computes its FFT and
        // mel projection in Float64. Float32 GPU FFT noise near the log floor is
        // observable, so preserve that precision using native Accelerate.
        guard let setup = vDSP_DFT_zop_CreateSetupD(nil, vDSP_Length(c.fftLength), .FORWARD) else {
            throw GemmaAudioError.invalid("Unable to construct Gemma audio FFT")
        }
        defer { vDSP_DFT_DestroySetupD(setup) }
        let bins = c.fftLength/2+1
        let zeros = [Double](repeating: 0, count: c.fftLength)
        var real = zeros, outReal = zeros, outImaginary = zeros
        var spectrum = [Double](repeating: 0, count: count*bins)
        for frame in 0..<count {
            for i in 0..<c.frameLength { real[i] = Double(frames[frame*c.frameLength+i]) }
            vDSP_DFT_ExecuteD(setup, real, zeros, &outReal, &outImaginary)
            for i in 0..<bins { spectrum[frame*bins+i] = hypot(outReal[i], outImaginary[i]) }
        }
        var mel = [Double](repeating: 0, count: count*c.melBins)
        vDSP_mmulD(spectrum, 1, filters, 1, &mel, 1, vDSP_Length(count), vDSP_Length(c.melBins), vDSP_Length(bins))
        let features = mel.enumerated().map { index, energy -> Float in
            let bin = index % c.melBins
            var value = Foundation.log(energy + Double(c.melFloor))
            if let mean = c.perBinMean { value -= Double(mean[bin]) }
            if let deviation = c.perBinStandardDeviation { value /= Double(deviation[bin]) }
            return mask[index / c.melBins] ? Float(value) : 0
        }
        return Output(features: MLXArray(features).reshaped(1,count,c.melBins), mask: mask)

    }
}
