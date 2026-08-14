import Accelerate
import Foundation

private enum Config {
    static let nFFT = 512
    static let hopLength = 160
    static let winLength = 400
    static let nMels = 80
    static let melFrames = 1_024
}

private struct WavAudio {
    let sampleRate: Int
    let samples: [Float]
}

private func readWav(_ url: URL) throws -> WavAudio {
    let data = try Data(contentsOf: url)
    guard data.count > 44 else { throw NSError(domain: "Wav", code: 1) }

    func string(_ offset: Int, _ count: Int) -> String {
        String(data: data[offset..<(offset + count)], encoding: .ascii) ?? ""
    }
    func u16(_ offset: Int) -> UInt16 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }.littleEndian
    }
    func u32(_ offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }

    guard string(0, 4) == "RIFF", string(8, 4) == "WAVE" else {
        throw NSError(domain: "Wav", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not a RIFF/WAVE file"])
    }

    var offset = 12
    var audioFormat: UInt16 = 0
    var channels: UInt16 = 0
    var sampleRate = 0
    var bitsPerSample: UInt16 = 0
    var dataOffset: Int?
    var dataSize = 0

    while offset + 8 <= data.count {
        let id = string(offset, 4)
        let size = Int(u32(offset + 4))
        let payload = offset + 8
        guard payload <= data.count, payload + size <= data.count else {
            throw NSError(domain: "Wav", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Truncated WAV chunk \(id)",
            ])
        }
        if id == "fmt " {
            guard size >= 16 else {
                throw NSError(domain: "Wav", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid fmt chunk size \(size)",
                ])
            }
            audioFormat = u16(payload)
            channels = u16(payload + 2)
            sampleRate = Int(u32(payload + 4))
            bitsPerSample = u16(payload + 14)
        } else if id == "data" {
            dataOffset = payload
            dataSize = size
            break
        }
        offset = payload + size + (size % 2)
    }

    guard let dataOffset else { throw NSError(domain: "Wav", code: 3) }
    guard channels > 0 else { throw NSError(domain: "Wav", code: 4) }
    let channelCount = Int(channels)
    let bytesPerSample = Int(bitsPerSample) / 8
    guard bytesPerSample > 0 else {
        throw NSError(domain: "Wav", code: 9, userInfo: [
            NSLocalizedDescriptionKey: "Invalid bits per sample \(bitsPerSample)",
        ])
    }
    let frameCount = dataSize / bytesPerSample / channelCount
    var samples = [Float](repeating: 0, count: frameCount)

    let isPCM16 = (audioFormat == 1 || audioFormat == 0xfffe) && bitsPerSample == 16
    if isPCM16 {
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                let byteOffset = dataOffset + (frame * channelCount + channel) * 2
                let raw = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self) }.littleEndian
                sum += Float(raw) / 32768.0
            }
            samples[frame] = sum / Float(channelCount)
        }
    } else if audioFormat == 3, bitsPerSample == 32 {
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                let byteOffset = dataOffset + (frame * channelCount + channel) * 4
                let bits = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: byteOffset, as: UInt32.self) }.littleEndian
                sum += Float(bitPattern: bits)
            }
            samples[frame] = sum / Float(channelCount)
        }
    } else {
        throw NSError(domain: "Wav", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Unsupported WAV format=\(audioFormat), bits=\(bitsPerSample)",
        ])
    }

    return WavAudio(sampleRate: sampleRate, samples: samples)
}

private final class SwiftMelSpectrogram {
    private struct PreprocessorConstants {
        let preemphasis: Float
        let logZeroGuard: Float
        let normGuard: Float
        let window: [Float]
        let filterBank: [Float]

        static func load(from url: URL) throws -> PreprocessorConstants {
            let data = try Data(contentsOf: url)
            let headerSize = 8 + 4 * MemoryLayout<Int32>.stride + 3 * MemoryLayout<Float>.stride
            guard data.count >= headerSize,
                  String(data: data[0..<8], encoding: .ascii) == "IASRPC01" else {
                throw NSError(domain: "Constants", code: 1)
            }

            func int32(at offset: Int) -> Int {
                Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }.littleEndian)
            }
            func float32(at offset: Int) -> Float {
                data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
            }

            let nFFT = int32(at: 8)
            let winLength = int32(at: 12)
            let nBins = int32(at: 16)
            let nMels = int32(at: 20)
            let preemphasis = float32(at: 24)
            let logZeroGuard = float32(at: 28)
            let normGuard = float32(at: 32)
            let floatCount = winLength + nMels * nBins
            let expectedSize = headerSize + floatCount * MemoryLayout<Float>.stride
            guard nFFT == Config.nFFT,
                  winLength == Config.winLength,
                  nBins == Config.nFFT / 2 + 1,
                  nMels == Config.nMels,
                  data.count == expectedSize else {
                throw NSError(domain: "Constants", code: 2)
            }

            var values = [Float](repeating: 0, count: floatCount)
            _ = values.withUnsafeMutableBytes { destination in
                data.copyBytes(to: destination, from: headerSize..<expectedSize)
            }
            return PreprocessorConstants(
                preemphasis: preemphasis,
                logZeroGuard: logZeroGuard,
                normGuard: normGuard,
                window: Array(values[0..<winLength]),
                filterBank: Array(values[winLength..<values.count])
            )
        }
    }

    private let filterBank: [Float]
    private let window: [Float]
    private let preemphasis: Float
    private let logZeroGuard: Float
    private let normGuard: Float
    private let fftSetup: FFTSetup
    private let fftLog2n: vDSP_Length
    private let nBins = Config.nFFT / 2 + 1

    init(constantsURL: URL) throws {
        let constants = try PreprocessorConstants.load(from: constantsURL)
        filterBank = constants.filterBank
        window = constants.window
        preemphasis = constants.preemphasis
        logZeroGuard = constants.logZeroGuard
        normGuard = constants.normGuard
        let log2n = vDSP_Length(log2(Double(Config.nFFT)))
        fftLog2n = log2n
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            throw NSError(domain: "Mel", code: 1)
        }
        fftSetup = setup
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func compute(audio: [Float]) -> (mel: [Float], realFrameCount: Int) {
        guard !audio.isEmpty else {
            return ([Float](repeating: 0, count: Config.nMels * Config.melFrames), 0)
        }

        let halfN = Config.nFFT / 2
        let pad = Config.nFFT / 2
        let windowOffset = (Config.nFFT - Config.winLength) / 2
        let emphasized = Self.preemphasize(audio, coefficient: preemphasis)
        let padded = Self.reflectPad(emphasized, left: pad, right: pad)

        let frameCount = padded.count >= Config.nFFT ? 1 + (padded.count - Config.nFFT) / Config.hopLength : 0
        let realFrameCount = min(frameCount, Config.melFrames)
        if realFrameCount == 0 {
            return ([Float](repeating: 0, count: Config.nMels * Config.melFrames), 0)
        }

        var frame = [Float](repeating: 0, count: Config.nFFT)
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)
        var powerSpec = [Float](repeating: 0, count: realFrameCount * nBins)
        var reSq = [Float](repeating: 0, count: halfN - 1)
        var imSq = [Float](repeating: 0, count: halfN - 1)

        padded.withUnsafeBufferPointer { paddedBuffer in
            for frameIndex in 0..<realFrameCount {
                let start = frameIndex * Config.hopLength
                frame.withUnsafeMutableBufferPointer { frameBuffer in
                    vDSP_vclr(frameBuffer.baseAddress!, 1, vDSP_Length(Config.nFFT))
                    vDSP_vmul(
                        paddedBuffer.baseAddress! + start + windowOffset, 1,
                        window, 1,
                        frameBuffer.baseAddress! + windowOffset, 1,
                        vDSP_Length(Config.winLength)
                    )
                }

                realPart.withUnsafeMutableBufferPointer { realBuffer in
                    imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                        var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imagBuffer.baseAddress!)
                        frame.withUnsafeBufferPointer { frameBuffer in
                            frameBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                                vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
                            }
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, fftLog2n, FFTDirection(kFFTDirection_Forward))
                        powerSpec.withUnsafeMutableBufferPointer { powerBuffer in
                            let destination = powerBuffer.baseAddress! + frameIndex * nBins
                            destination[0] = realBuffer[0] * realBuffer[0]
                            destination[halfN] = imagBuffer[0] * imagBuffer[0]
                            vDSP_vsq(realBuffer.baseAddress! + 1, 1, &reSq, 1, vDSP_Length(halfN - 1))
                            vDSP_vsq(imagBuffer.baseAddress! + 1, 1, &imSq, 1, vDSP_Length(halfN - 1))
                            vDSP_vadd(reSq, 1, imSq, 1, destination + 1, 1, vDSP_Length(halfN - 1))
                        }
                    }
                }
            }
        }

        var powerSpecT = [Float](repeating: 0, count: nBins * realFrameCount)
        // powerSpec is [frames, nBins] row-major; vDSP_mtrans M/N are columns/rows here.
        vDSP_mtrans(powerSpec, 1, &powerSpecT, 1, vDSP_Length(nBins), vDSP_Length(realFrameCount))

        var melRaw = [Float](repeating: 0, count: Config.nMels * realFrameCount)
        vDSP_mmul(filterBank, 1, powerSpecT, 1, &melRaw, 1,
                  vDSP_Length(Config.nMels), vDSP_Length(realFrameCount), vDSP_Length(nBins))

        var guardValue = logZeroGuard
        var logMel = [Float](repeating: 0, count: Config.nMels * realFrameCount)
        vDSP_vsadd(melRaw, 1, &guardValue, &logMel, 1, vDSP_Length(logMel.count))
        var vectorLength = Int32(logMel.count)
        vvlogf(&logMel, logMel, &vectorLength)

        var normalized = [Float](repeating: 0, count: Config.nMels * Config.melFrames)
        let realFrameVLength = vDSP_Length(realFrameCount)
        let invNm1 = 1.0 / Float(max(realFrameCount - 1, 1))
        for melIndex in 0..<Config.nMels {
            let sourceOffset = melIndex * realFrameCount
            let destinationOffset = melIndex * Config.melFrames
            var mean: Float = 0
            logMel.withUnsafeBufferPointer { buffer in
                vDSP_meanv(buffer.baseAddress! + sourceOffset, 1, &mean, realFrameVLength)
            }
            var negMean = -mean
            var centered = [Float](repeating: 0, count: realFrameCount)
            logMel.withUnsafeBufferPointer { buffer in
                vDSP_vsadd(buffer.baseAddress! + sourceOffset, 1, &negMean, &centered, 1, realFrameVLength)
            }
            var sumSq: Float = 0
            vDSP_dotpr(centered, 1, centered, 1, &sumSq, realFrameVLength)
            let std = sqrtf(max(sumSq * invNm1, logZeroGuard)) + normGuard
            var invStd = 1.0 / std
            normalized.withUnsafeMutableBufferPointer { buffer in
                vDSP_vsmul(centered, 1, &invStd, buffer.baseAddress! + destinationOffset, 1, realFrameVLength)
            }
        }

        return (normalized, realFrameCount)
    }

    private static func preemphasize(_ audio: [Float], coefficient: Float) -> [Float] {
        var emphasized = [Float](repeating: 0, count: audio.count)
        guard !audio.isEmpty else { return emphasized }
        emphasized[0] = audio[0]
        if audio.count > 1 {
            for index in 1..<audio.count {
                emphasized[index] = audio[index] - coefficient * audio[index - 1]
            }
        }
        return emphasized
    }

    private static func reflectPad(_ input: [Float], left: Int, right: Int) -> [Float] {
        guard input.count > 1 else {
            let value = input.first ?? 0
            return [Float](repeating: value, count: left + input.count + right)
        }
        var padded = [Float](repeating: 0, count: left + input.count + right)
        for index in 0..<left {
            padded[index] = input[reflectIndex(left - index, count: input.count)]
        }
        for index in 0..<input.count {
            padded[left + index] = input[index]
        }
        for index in 0..<right {
            padded[left + input.count + index] = input[reflectIndex(input.count - 2 - index, count: input.count)]
        }
        return padded
    }

    private static func reflectIndex(_ rawIndex: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let period = 2 * count - 2
        var index = rawIndex % period
        if index < 0 { index += period }
        if index >= count {
            index = period - index
        }
        return index
    }
}

guard CommandLine.arguments.count == 4 else {
    fputs("usage: swift dump_swift_mel.swift input_16k.wav output.bin preprocessor_constants.bin\n", stderr)
    exit(2)
}

private let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
private let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
private let constantsURL = URL(fileURLWithPath: CommandLine.arguments[3])
private let wav = try readWav(inputURL)
guard wav.sampleRate == 16_000 else {
    throw NSError(domain: "Wav", code: 6, userInfo: [NSLocalizedDescriptionKey: "Expected 16 kHz WAV, got \(wav.sampleRate)"])
}
private let result = try SwiftMelSpectrogram(constantsURL: constantsURL).compute(audio: wav.samples)
private var header = "shape=80,1024 real_frames=\(result.realFrameCount)\n".data(using: .utf8)!
private let melData = result.mel.withUnsafeBufferPointer { Data(buffer: $0) }
header.append(melData)
try header.write(to: outputURL)
print("wrote \(outputURL.path) real_frames=\(result.realFrameCount)")
