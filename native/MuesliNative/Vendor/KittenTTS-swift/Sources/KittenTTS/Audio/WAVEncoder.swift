import Foundation

/// Encodes raw Float32 PCM samples into a standard 16-bit mono RIFF WAV file.
enum WAVEncoder {

    /// Encode `samples` at `sampleRate` Hz into a RIFF WAV `Data` blob.
    ///
    /// Samples are clamped to `–1.0 … +1.0` and converted to 16-bit signed PCM.
    ///
    /// - Parameters:
    ///   - samples: Float32 PCM samples (mono, normalised to roughly ±1.0).
    ///   - sampleRate: Sample rate in Hz (e.g. 24 000).
    /// - Returns: A complete RIFF WAV file ready to write to disk or pass to `AVAudioPlayer`.
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign  = numChannels * bitsPerSample / 8
        let byteRate    = UInt32(sampleRate) * UInt32(blockAlign)
        let dataBytes   = UInt32(samples.count) * UInt32(blockAlign)

        var d = Data()
        d += "RIFF".data(using: .ascii)!
        d.appendLE32(36 + dataBytes)        // chunk size
        d += "WAVE".data(using: .ascii)!
        d += "fmt ".data(using: .ascii)!
        d.appendLE32(16)                    // fmt chunk size
        d.appendLE16(1)                     // PCM = 1
        d.appendLE16(numChannels)
        d.appendLE32(UInt32(sampleRate))
        d.appendLE32(byteRate)
        d.appendLE16(blockAlign)
        d.appendLE16(bitsPerSample)
        d += "data".data(using: .ascii)!
        d.appendLE32(dataBytes)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            d.appendLE16(UInt16(bitPattern: Int16(clamped * 32_767)))
        }
        return d
    }
}
