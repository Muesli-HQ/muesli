import Foundation

/// The result of a ``KittenTTS`` speech-synthesis call.
///
/// A `KittenTTSResult` contains the raw PCM audio and metadata about the
/// synthesis. Use ``wavData()`` to encode the audio as a standard WAV file,
/// or ``writeWAV(to:)`` to save it directly to disk.
///
/// ```swift
/// let result = try await tts.generate("Hello, world!")
/// print("Duration: \(result.duration)s")
/// try result.writeWAV(to: URL(fileURLWithPath: "/tmp/hello.wav"))
/// ```
public struct KittenTTSResult: Sendable {

    // MARK: - Audio Data

    /// Raw Float32 PCM samples at ``sampleRate`` Hz, mono channel.
    ///
    /// Values are normalised to roughly –1.0 … +1.0.
    public let samples: [Float]

    /// Sample rate of the audio. Always ``KittenTTSConfig/outputSampleRate`` (24 000 Hz).
    public let sampleRate: Int

    // MARK: - Metadata

    /// Duration of the audio in seconds.
    public var duration: TimeInterval {
        Double(samples.count) / Double(sampleRate)
    }

    /// The voice used to generate this audio.
    public let voice: KittenVoice

    /// The effective speed multiplier that was applied to the model
    /// (i.e. `voice.defaultSpeed × userSpeed`).
    public let effectiveSpeed: Float

    /// The original input text that was synthesised.
    public let inputText: String

    /// Per-word timestamps derived from the model's predicted phoneme durations.
    ///
    /// Each entry maps a word in ``inputText`` to its start and end time in the
    /// generated audio. Empty when duration data is unavailable (e.g. for
    /// multi-chunk texts that exceed ``KittenTTSConfig/maxTokensPerChunk``).
    public let wordTimings: [KittenWordTiming]

    // MARK: - Export

    /// Encode the audio as a standard 16-bit PCM RIFF WAV file.
    ///
    /// - Returns: WAV-formatted `Data` ready to write to disk or share.
    public func wavData() -> Data {
        WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
    }

    /// Write the audio as a WAV file to the given URL.
    ///
    /// - Parameter url: Destination file URL (e.g. inside the app's Documents folder).
    /// - Throws: `CocoaError` if the file cannot be written.
    public func writeWAV(to url: URL) throws {
        try wavData().write(to: url, options: .atomic)
    }
}
