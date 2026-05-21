import Foundation

enum WavWriter {
    static let sampleRate: UInt32 = 16_000
    static let channels: UInt16 = 1
    static let bitsPerSample: UInt16 = 16

    static func header(dataSize: Int) -> Data {
        header(dataSize: UInt32(clamping: dataSize))
    }

    static func header(dataSize: UInt32) -> Data {
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let (chunkSize, overflow) = dataSize.addingReportingOverflow(36)

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: (overflow ? UInt32.max : chunkSize).littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        return header
    }

    /// Write Float32 samples to a temporary 16kHz mono Int16 WAV file.
    static func writeTemporaryWAV(samples: [Float], directoryName: String = "muesli-wav-temp") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")

        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767)
        }

        var data = Data()
        let dataSize = UInt32(int16Samples.count * 2)
        data.append(header(dataSize: dataSize))
        int16Samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }

        try data.write(to: url)
        return url
    }
}
