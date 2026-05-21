import Foundation

/// Configuration for a ``KittenTTS`` session.
///
/// Pass a customised config to ``KittenTTS/init(_:)`` to override any defaults.
///
/// ```swift
/// let config = KittenTTSConfig(
///     model: .nano,
///     defaultVoice: .luna,
///     speed: 1.1
/// )
/// let tts = try await KittenTTS(config)
/// ```
public struct KittenTTSConfig: Sendable {

    // MARK: - Model

    /// The model variant to use. Defaults to ``KittenModel/nano``.
    public var model: KittenModel

    // MARK: - Voice & Speed Defaults

    /// Default voice used when ``KittenTTS/generate(_:voice:speed:)`` omits `voice`.
    ///
    /// Defaults to ``KittenVoice/bella``.
    public var defaultVoice: KittenVoice

    /// Default speed multiplier (0.5 – 2.0) applied when `speed` is omitted from a call.
    ///
    /// This is multiplied by the voice's own ``KittenVoice/defaultSpeed``.
    /// Defaults to `1.0` (natural speed).
    public var speed: Float

    // MARK: - Storage

    /// Directory where downloaded model files are cached.
    ///
    /// If `nil` (the default), the SDK uses
    /// `<Application Support>/KittenTTS/<model.rawValue>/`.
    public var storageDirectory: URL?

    // MARK: - Phonemizer

    /// The G2P engine used to convert text to IPA phoneme sequences.
    ///
    /// Defaults to ``KittenPhonemizerType/builtin`` — the high-quality
    /// ``EPhonemizer`` that downloads its data files on first use.
    /// Supply your own implementation via ``KittenPhonemizerType/custom(_:)``.
    ///
    /// ```swift
    /// // Built-in EPhonemizer (default)
    /// let config = KittenTTSConfig(phonemizer: .builtin)
    ///
    /// // Custom
    /// let config = KittenTTSConfig(phonemizer: .custom(MyPhonemizer()))
    /// ```
    public var phonemizer: KittenPhonemizerType

    // MARK: - Engine Tuning

    /// Number of ONNX Runtime intra-op threads.
    ///
    /// Higher values can speed up inference on multi-core devices.
    /// Defaults to `4`.
    public var ortNumThreads: Int

    /// Maximum number of tokens per inference chunk.
    ///
    /// Long texts are split into chunks of at most this many tokens to prevent
    /// out-of-memory errors on low-memory devices. Defaults to `400`.
    public var maxTokensPerChunk: Int

    // MARK: - Constants

    /// The sample rate (Hz) of all KittenTTS audio output. Fixed at 24 000 Hz.
    public static let outputSampleRate: Int = 24_000

    // MARK: - Initializer

    public init(
        model: KittenModel = .nano,
        defaultVoice: KittenVoice = .bella,
        speed: Float = 1.0,
        phonemizer: KittenPhonemizerType = .builtin,
        storageDirectory: URL? = nil,
        ortNumThreads: Int = 4,
        maxTokensPerChunk: Int = 400
    ) {
        self.model             = model
        self.defaultVoice      = defaultVoice
        self.speed             = min(max(speed, 0.5), 2.0)
        self.phonemizer        = phonemizer
        self.storageDirectory  = storageDirectory
        self.ortNumThreads     = max(1, ortNumThreads)
        self.maxTokensPerChunk = max(50, maxTokensPerChunk)
    }

    // MARK: - Resolved storage URL

    /// The resolved directory on disk where model files for this config are stored.
    var resolvedStorageDirectory: URL {
        if let custom = storageDirectory { return custom.appendingPathComponent(model.rawValue) }
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("KittenTTS", isDirectory: true)
            .appendingPathComponent(model.rawValue, isDirectory: true)
    }
}
