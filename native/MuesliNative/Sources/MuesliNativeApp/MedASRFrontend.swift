import Accelerate
import Foundation
import MuesliCore

enum MedASRError: LocalizedError, Sendable {
    case notLoaded
    case invalidAssets
    case invalidPrediction

    var errorDescription: String? {
        switch self {
        case .notLoaded: "MedASR is not ready. Download and prepare it first."
        case .invalidAssets: "MedASR files are incomplete or incompatible. Delete the model and download it again."
        case .invalidPrediction: "MedASR returned an invalid prediction."
        }
    }
}

/// Google's non-centered HTK/Kaldi frontend, using the exported checkpoint tables.
/// FluidAudio 0.17.3 supplies audio conversion/CTC but cannot inject these tables.
/// Keep this independent of NeMo's centering, preemphasis and Slaney defaults.
final class MedASRFrontend {
    private let window: [Float]
    private let filters: [Float]
    private let fft: vDSP_DFT_Setup

    init(directory: URL) throws {
        window = try Self.readFloats(directory.appendingPathComponent("window.f32"), count: 400)
        filters = try Self.readFloats(directory.appendingPathComponent("mel-filterbank.f32"), count: 128 * 257)
        guard window.allSatisfy({ $0 >= 0 && $0 <= 1 }),
              filters.allSatisfy({ $0 >= 0 }),
              let fft = vDSP_DFT_zop_CreateSetup(nil, 512, .FORWARD)
        else { throw MedASRError.invalidAssets }
        self.fft = fft
    }

    deinit { vDSP_DFT_DestroySetup(fft) }

    static func readFloats(_ url: URL, count: Int) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count == count * MemoryLayout<Float>.size else { throw MedASRError.invalidAssets }
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard values.allSatisfy(\.isFinite) else { throw MedASRError.invalidAssets }
        return values
    }

    /// Time-major [1,1998,128], including the exact log-floor padding features.
    func features(_ samples: [Float]) throws -> [Float] {
        guard samples.count <= MedASRModel.windowSamples, samples.allSatisfy(\.isFinite) else {
            throw MedASRError.invalidAssets
        }
        var result = [Float](repeating: logf(1e-5), count: MedASRModel.featureFrames * 128)
        var real = [Float](repeating: 0, count: 512)
        let imaginary = [Float](repeating: 0, count: 512)
        var realOutput = real
        var imaginaryOutput = real
        var power = [Float](repeating: 0, count: 257)
        var mel = [Float](repeating: 0, count: 128)
        for frame in 0..<MedASRModel.featureFrames {
            try Task.checkCancellation()
            let start = frame * 160
            if start >= samples.count { break }
            for i in 0..<400 {
                real[i] = start + i < samples.count ? samples[start + i] * window[i] : 0
            }
            vDSP_DFT_Execute(fft, real, imaginary, &realOutput, &imaginaryOutput)
            for bin in 0..<257 {
                power[bin] = realOutput[bin] * realOutput[bin] + imaginaryOutput[bin] * imaginaryOutput[bin]
            }
            vDSP_mmul(filters, 1, power, 1, &mel, 1, 128, 1, 257)
            for bin in 0..<128 { result[frame * 128 + bin] = logf(max(mel[bin], 1e-5)) }
        }
        return result
    }
}

/// Bounded overlap windows; hold an exact full window until EOF is known so its
/// last two seconds are never discarded as if another window were guaranteed.
struct MedASRAudioWindows {
    struct Window: Sendable {
        let samples: [Float]
        let leftContext: Int
        let rightContext: Int

        var retainedFrames: Range<Int> {
            let valid = MedASRModel.encodedLength(features: MedASRModel.featureLength(samples: samples.count))
            // Each encoder frame's receptive center is sample 1160 + 640*t.
            let first = max(0, (leftContext - 1160 + 639) / 640)
            let endSample = samples.count - rightContext
            let end = max(first, min(valid, (endSample - 1160 + 639) / 640))
            return first..<end
        }
    }

    private(set) var pending: [Float] = []
    private var hasEmitted = false

    mutating func append(_ samples: [Float]) { pending.append(contentsOf: samples) }

    mutating func next(final: Bool) -> Window? {
        guard pending.count > MedASRModel.windowSamples || (final && !pending.isEmpty) else { return nil }
        let more = pending.count > MedASRModel.windowSamples
        let count = min(pending.count, MedASRModel.windowSamples)
        let window = Window(samples: Array(pending.prefix(count)),
                            leftContext: hasEmitted ? 32_000 : 0,
                            rightContext: more ? 32_000 : 0)
        if more { pending.removeFirst(256_000) } else { pending.removeAll(keepingCapacity: false) }
        hasEmitted = true
        return window
    }
}

struct MedASRCTCAccumulator {
    private(set) var tokenIDs: [Int] = []
    private var previous = -1

    mutating func append(_ frames: [Int]) {
        for token in frames {
            if token != previous && token != MedASRModel.blankID { tokenIDs.append(token) }
            previous = token
        }
    }
}

enum MedASRFormatting {
    static func render(_ text: String) -> String {
        var result = text
        for (control, value) in [
            ("{period}", "."), ("{comma}", ","), ("{colon}", ":"), ("{semicolon}", ";"),
            ("{question mark}", "?"), ("{exclamation point}", "!"),
            ("{new paragraph}", "\n\n"), ("{new line}", "\n"),
        ] { result = result.replacingOccurrences(of: control, with: value) }
        result = result.replacingOccurrences(of: "[ \\t]+([.,:;!?])", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "[ \\t]*\\n[ \\t]*", with: "\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
