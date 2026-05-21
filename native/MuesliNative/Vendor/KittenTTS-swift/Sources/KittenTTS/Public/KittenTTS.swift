import Foundation

/// The KittenTTS speech-synthesis engine.
///
/// `KittenTTS` downloads phonemizer data and the model on first use, initialises
/// the ONNX Runtime inference session, and exposes a simple `async` API for
/// generating and playing speech.
///
/// ## Quick start
///
/// ```swift
/// // 1. Create an instance — downloads the model if needed
/// let tts = try await KittenTTS()
///
/// // 2. Generate audio
/// let result = try await tts.generate("Hello from KittenTTS!")
/// print("Duration: \(result.duration)s")
///
/// // 3. Play it
/// try await tts.speak("Good morning!")
///
/// // 4. Save as WAV
/// try result.writeWAV(to: URL(fileURLWithPath: "/tmp/hello.wav"))
/// ```
///
/// ## Custom configuration
///
/// ```swift
/// let config = KittenTTSConfig(defaultVoice: .luna, speed: 1.1)
/// let tts = try await KittenTTS(config) { progress in
///     print("Download progress: \(Int(progress * 100))%")
/// }
/// ```
///
/// ## Checking for cached models
///
/// ```swift
/// if KittenTTS.isModelCached() {
///     let tts = try await KittenTTS()
/// } else {
///     // Show download UI first
/// }
/// ```
public actor KittenTTS {

    // MARK: - Properties

    /// The configuration this instance was initialised with.
    public let config: KittenTTSConfig

    // MARK: - Private state

    private let engine: TTSEngine
    private let audioOutput = AudioOutput()

    // MARK: - Initializer

    /// Initialise KittenTTS, downloading all required files if they are not yet cached.
    ///
    /// This method will:
    /// 1. Download phonemizer data files if needed (e.g. `en_rules`, `en_list`).
    /// 2. Download the ONNX model from Hugging Face if not cached (~57 MB for nano).
    /// 3. Load the ONNX Runtime session and voice embeddings.
    ///
    /// - Parameters:
    ///   - config: Configuration for this session. Defaults to ``KittenTTSConfig()``.
    ///   - downloadProgressHandler: Optional closure called with overall download progress [0, 1]
    ///     on an unspecified background thread. Only invoked when a download is actually needed.
    /// - Throws: ``KittenTTSError`` on download or engine initialisation failure.
    public init(
        _ config: KittenTTSConfig = KittenTTSConfig(),
        downloadProgressHandler: ((Double) -> Void)? = nil
    ) async throws {
        self.config = config

        // Resolve the phonemizer early so we can download its assets
        let phonemizer = try config.phonemizer.resolve()

        // Download phonemizer data files (e.g. en_rules, en_list for EPhonemizer)
        let storageDir = config.resolvedStorageDirectory
        try await phonemizer.downloadIfNeeded(to: storageDir, progressHandler: nil)

        // Ensure model files are present
        let (onnxURL, voicesURL) = try await ModelDownloader.downloadModelIfNeeded(
            for: config,
            progressHandler: downloadProgressHandler
        )

        // Validate files exist after download
        guard FileManager.default.fileExists(atPath: onnxURL.path) else {
            throw KittenTTSError.modelFileNotFound(onnxURL)
        }
        guard FileManager.default.fileExists(atPath: voicesURL.path) else {
            throw KittenTTSError.voicesFileNotFound(voicesURL)
        }

        // Initialise ONNX engine on a background thread (pass pre-resolved phonemizer)
        self.engine = try await Task.detached(priority: .userInitiated) {
            try TTSEngine(modelURL: onnxURL, voicesURL: voicesURL, config: config, phonemizer: phonemizer)
        }.value
    }

    // MARK: - Generation

    /// Synthesise speech for the given text.
    ///
    /// - Parameters:
    ///   - text: The English text to synthesise. Must not be empty.
    ///   - voice: The voice to use. Defaults to ``KittenTTSConfig/defaultVoice``.
    ///   - speed: Speed multiplier (0.5–2.0). Defaults to ``KittenTTSConfig/speed``.
    /// - Returns: A ``KittenTTSResult`` containing raw PCM samples and metadata.
    /// - Throws: ``KittenTTSError/emptyInput`` if `text` is blank,
    ///   or ``KittenTTSError/inferenceFailed(_:)`` on ONNX error.
    public func generate(
        _ text: String,
        voice: KittenVoice? = nil,
        speed: Float? = nil
    ) async throws -> KittenTTSResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KittenTTSError.emptyInput }

        let selectedVoice = voice ?? config.defaultVoice
        let selectedSpeed = min(max(speed ?? config.speed, 0.5), 2.0)
        let effectiveSpeed = selectedSpeed * config.model.speedPrior(for: selectedVoice)

        let output = try await Task.detached(priority: .userInitiated) { [engine] in
            try engine.generate(text: trimmed, voice: selectedVoice, speed: selectedSpeed)
        }.value

        let wordTimings = TimestampJoiner.joinTimestamps(
            inputText: trimmed,
            phonemes: output.phonemes,
            durations: output.durations
        )

        return KittenTTSResult(
            samples: output.samples,
            sampleRate: KittenTTSConfig.outputSampleRate,
            voice: selectedVoice,
            effectiveSpeed: effectiveSpeed,
            inputText: trimmed,
            wordTimings: wordTimings
        )
    }

    /// Synthesise speech for the given text, yielding results sentence by sentence.
    ///
    /// This is the streaming counterpart of ``generate(_:voice:speed:)``. Instead of
    /// waiting for the entire text to finish, it splits the input into sentences and
    /// yields a ``KittenTTSResult`` for each one as soon as it is ready.
    ///
    /// Use this when you want to start audio playback immediately while the rest of
    /// the text is still being synthesised:
    ///
    /// ```swift
    /// for try await chunk in tts.generateStreaming("Long article text...") {
    ///     audioEngine.scheduleBuffer(chunk.samples)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - text: The English text to synthesise. Must not be empty.
    ///   - voice: The voice to use. Defaults to ``KittenTTSConfig/defaultVoice``.
    ///   - speed: Speed multiplier (0.5-2.0). Defaults to ``KittenTTSConfig/speed``.
    /// - Returns: An `AsyncThrowingStream` of ``KittenTTSResult`` values, one per sentence.
    public func generateStreaming(
        _ text: String,
        voice: KittenVoice? = nil,
        speed: Float? = nil
    ) -> AsyncThrowingStream<KittenTTSResult, Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedVoice = voice ?? config.defaultVoice
        let selectedSpeed = min(max(speed ?? config.speed, 0.5), 2.0)

        return AsyncThrowingStream { continuation in
            Task { [engine, config] in
                guard !trimmed.isEmpty else {
                    continuation.finish(throwing: KittenTTSError.emptyInput)
                    return
                }

                let sentences = SentenceSplitter.split(trimmed)
                let effectiveSpeed = selectedSpeed * config.model.speedPrior(for: selectedVoice)

                do {
                    for sentence in sentences {
                        let output = try await Task.detached(priority: .userInitiated) {
                            try engine.generate(text: sentence, voice: selectedVoice, speed: selectedSpeed)
                        }.value
                        let wordTimings = TimestampJoiner.joinTimestamps(
                            inputText: sentence,
                            phonemes: output.phonemes,
                            durations: output.durations
                        )

                        let result = KittenTTSResult(
                            samples: output.samples,
                            sampleRate: KittenTTSConfig.outputSampleRate,
                            voice: selectedVoice,
                            effectiveSpeed: effectiveSpeed,
                            inputText: sentence,
                            wordTimings: wordTimings
                        )
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Synthesise and play speech for the given text.
    ///
    /// This is a convenience wrapper that calls ``generate(_:voice:speed:)`` and then
    /// plays the result through the device speakers. It returns when playback is complete.
    ///
    /// - Parameters:
    ///   - text: The English text to synthesise. Must not be empty.
    ///   - voice: The voice to use. Defaults to ``KittenTTSConfig/defaultVoice``.
    ///   - speed: Speed multiplier (0.5-2.0). Defaults to ``KittenTTSConfig/speed``.
    /// - Returns: The generated ``KittenTTSResult``.
    /// - Throws: ``KittenTTSError`` on synthesis or playback failure.
    @discardableResult
    public func speak(
        _ text: String,
        voice: KittenVoice? = nil,
        speed: Float? = nil
    ) async throws -> KittenTTSResult {
        let result = try await generate(text, voice: voice, speed: speed)
        try await audioOutput.play(samples: result.samples, sampleRate: result.sampleRate)
        return result
    }

    /// Stop any currently active audio playback.
    public func stopSpeaking() {
        audioOutput.stop()
    }

    // MARK: - Static helpers

    /// Returns `true` if the model files for `config` are already cached on disk.
    ///
    /// Use this to decide whether to show a download progress indicator before
    /// creating a ``KittenTTS`` instance.
    ///
    /// ```swift
    /// if KittenTTS.isModelCached() {
    ///     let tts = try await KittenTTS()
    /// }
    /// ```
    public static func isModelCached(for config: KittenTTSConfig = KittenTTSConfig()) -> Bool {
        ModelDownloader.isModelCached(for: config)
    }

    /// Returns `true` if the model files for the given model variant are already cached on disk.
    public static func isModelCached(_ model: KittenModel) -> Bool {
        isModelCached(for: KittenTTSConfig(model: model))
    }

    /// Pre-download and warm up the model without creating a full ``KittenTTS`` instance.
    ///
    /// Call this early in your app's lifecycle (e.g. in `applicationDidFinishLaunching`)
    /// so the engine is ready before the user needs it.
    ///
    /// - Parameter config: Configuration identifying which model to warm up.
    /// - Throws: ``KittenTTSError`` if download or initialisation fails.
    public static func prewarm(config: KittenTTSConfig = KittenTTSConfig()) async throws {
        _ = try await KittenTTS(config)
    }
}
