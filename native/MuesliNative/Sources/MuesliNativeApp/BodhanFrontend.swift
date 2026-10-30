import Accelerate
import Foundation

/// Frozen Bodhan frontend: 16 kHz mono, exact checkpoint window/filterbank.
final class BodhanFrontend {
    private let window: [Float]
    private let filters: [Float]
    private let fft: FFTSetup

    init(constants: URL) throws {
        let data = try Data(contentsOf: constants)
        guard data.count == (400 + 128 * 257) * 4 else {
            throw NSError(domain: "BodhanASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid frontend constants."])
        }
        let floats: [Float] = data.withUnsafeBytes { bytes in
            (0..<(data.count/4)).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0*4, as: UInt32.self))) }
        }
        window = Array(floats.prefix(400))
        filters = Array(floats.dropFirst(400))
        guard let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2)) else {
            throw NSError(domain: "BodhanASR", code: 2)
        }
        fft = setup
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    func compute(_ samples: [Float]) -> (features: [Float], frames: Int) {
        var audio = samples
        if audio.count < 16000 {
            var padded = [Float](repeating: 0, count: 16000)
            let offset = Int((Double(16000-audio.count)/2).rounded(.toNearestOrEven))
            padded.replaceSubrange(offset..<(offset+audio.count), with: audio)
            audio = padded
        }
        let frames = audio.count/160+1
        var emphasized = audio
        for i in 1..<audio.count { emphasized[i] = audio[i] - 0.97 * audio[i-1] }
        var power = [Float](repeating: 0, count: 257*frames)
        var real = [Float](repeating: 0, count: 512)
        var imag = real
        for frame in 0..<frames {
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { im in
                    r.initialize(repeating: 0)
                    im.initialize(repeating: 0)
                    for j in 0..<400 {
                        var source = frame*160+j+56-256
                        if source < 0 { source = -source }
                        if source >= audio.count { source = 2*audio.count-2-source }
                        r[j+56] = emphasized[source]*window[j]
                    }
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    vDSP_fft_zip(fft, &split, 1, 9, FFTDirection(kFFTDirection_Forward))
                    for k in 0..<257 { power[k*frames+frame] = r[k]*r[k]+im[k]*im[k] }
                }
            }
        }
        var mel = [Float](repeating: 0, count: 128*frames)
        vDSP_mmul(filters, 1, power, 1, &mel, 1, 128, vDSP_Length(frames), 257)
        for i in mel.indices { mel[i] = logf(mel[i]+powf(2,-24)) }
        for band in 0..<128 {
            let start = band*frames
            var mean: Float = 0
            mel.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress!+start, 1, &mean, vDSP_Length(frames)) }
            var sum: Float = 0
            for i in start..<(start+frames) { mel[i] -= mean; sum += mel[i]*mel[i] }
            let std = sqrtf(sum/Float(frames-1))+1e-5
            for i in start..<(start+frames) { mel[i] /= std }
        }
        return (mel, frames)
    }
}
