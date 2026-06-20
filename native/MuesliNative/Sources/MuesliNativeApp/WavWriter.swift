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

    static func writeWAV(samples: [Float], to url: URL) throws {
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * 32767)
        }

        var data = Data()
        data.append(header(dataSize: UInt32(int16Samples.count * 2)))
        int16Samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url)
    }
}

enum WavReader {
    struct WavData {
        let sampleRate: Int
        let samples: [Float]
    }

    static func readFloatMonoWAV(from url: URL) throws -> WavData {
        let data = try Data(contentsOf: url)
        guard data.count >= 12,
              String(bytes: data[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: data[8..<12], encoding: .ascii) == "WAVE"
        else {
            throw NSError(domain: "WavReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid WAV file: \(url.path)"])
        }

        var sampleRate: Int?
        var channels: Int?
        var bitsPerSample: Int?
        var audioFormat: Int?
        var dataRange: Range<Int>?
        var offset = 12

        while offset + 8 <= data.count {
            guard let chunkID = String(bytes: data[offset..<(offset + 4)], encoding: .ascii),
                  let chunkSize = readUInt32LE(data, at: offset + 4)
            else { break }

            let payloadStart = offset + 8
            let payloadEnd = payloadStart + Int(chunkSize)
            guard payloadEnd <= data.count else { break }

            if chunkID == "fmt " {
                guard Int(chunkSize) >= 16,
                      let parsedFormat = readUInt16LE(data, at: payloadStart),
                      let parsedChannels = readUInt16LE(data, at: payloadStart + 2),
                      let parsedSampleRate = readUInt32LE(data, at: payloadStart + 4),
                      let parsedBits = readUInt16LE(data, at: payloadStart + 14)
                else { break }
                audioFormat = Int(parsedFormat)
                channels = Int(parsedChannels)
                sampleRate = Int(parsedSampleRate)
                bitsPerSample = Int(parsedBits)
            } else if chunkID == "data" {
                dataRange = payloadStart..<payloadEnd
            }

            offset = payloadEnd + (Int(chunkSize) % 2)
        }

        guard audioFormat == 1,
              bitsPerSample == 16,
              let sampleRate,
              let channelCount = channels,
              channelCount > 0,
              let dataRange
        else {
            throw NSError(domain: "WavReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected 16-bit PCM WAV: \(url.path)"])
        }

        var interleaved: [Int16] = []
        let byteCount = dataRange.count - (dataRange.count % 2)
        interleaved.reserveCapacity(byteCount / 2)
        var sampleOffset = dataRange.lowerBound
        while sampleOffset + 1 < dataRange.lowerBound + byteCount {
            let low = UInt16(data[sampleOffset])
            let high = UInt16(data[sampleOffset + 1]) << 8
            interleaved.append(Int16(bitPattern: high | low))
            sampleOffset += 2
        }

        let mono: [Float]
        if channelCount == 1 {
            mono = interleaved.map { Float($0) / 32768.0 }
        } else {
            let frameCount = interleaved.count / channelCount
            mono = (0..<frameCount).map { frame in
                var sum = 0
                for channel in 0..<channelCount {
                    sum += Int(interleaved[frame * channelCount + channel])
                }
                return (Float(sum) / Float(channelCount)) / 32768.0
            }
        }

        return WavData(sampleRate: sampleRate, samples: mono)
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
