import Foundation

// MARK: - Protocol

/// A type that converts normalised English text into an IPA phoneme string
/// compatible with the KittenTTS symbol table.
///
/// Implement this protocol to plug in any G2P engine — a local rule-based
/// system, a neural network, a server-side API, or a compiled C library:
///
/// ```swift
/// struct MyPhonemizer: KittenPhonemizerProtocol {
///     func phonemize(_ text: String) -> String {
///         // your G2P logic here
///     }
/// }
/// let config = KittenTTSConfig(phonemizer: .custom(MyPhonemizer()))
/// let tts = try await KittenTTS(config)
/// ```
///
/// The input `text` has already been processed by ``TextPreprocessor`` (numbers
/// expanded, currencies spelled out, etc.). The returned string must use only
/// Unicode code points present in the KittenTTS symbol table; unknown scalars
/// are silently dropped by ``TextCleaner``.
public protocol KittenPhonemizerProtocol: Sendable {
    /// Convert a preprocessed English sentence to an IPA phoneme string.
    ///
    /// - Parameter text: Normalised text (output of `TextPreprocessor.process(_:)`).
    /// - Returns: IPA string suitable for `TextCleaner.encode(_:)`.
    func phonemize(_ text: String) -> String

    /// Download any data files the phonemizer needs before first use.
    ///
    /// Called by ``KittenTTS/init(_:downloadProgressHandler:)`` alongside the
    /// model download. The phonemizer should cache files in `storageDirectory`
    /// and skip re-downloading if they already exist.
    ///
    /// The default implementation is a no-op (for phonemizers that need no data).
    ///
    /// - Parameters:
    ///   - storageDirectory: Directory where the phonemizer should cache its files.
    ///   - progressHandler: Optional closure called with download progress [0, 1].
    func downloadIfNeeded(
        to storageDirectory: URL,
        progressHandler: ((Double) -> Void)?
    ) async throws
}

extension KittenPhonemizerProtocol {
    public func downloadIfNeeded(
        to storageDirectory: URL,
        progressHandler: ((Double) -> Void)?
    ) async throws {
        // No-op by default — most phonemizers don't need to download anything.
        progressHandler?(1.0)
    }
}

// MARK: - Type selection

/// Selects which phonemizer a ``KittenTTS`` instance uses for G2P conversion.
///
/// Pass this as part of ``KittenTTSConfig``:
///
/// ```swift
/// // Default — high-quality EPhonemizer, works everywhere
/// let config = KittenTTSConfig(phonemizer: .builtin)
///
/// // System eSpeak-NG binary (macOS only, requires brew install espeak-ng)
/// let config = KittenTTSConfig(phonemizer: .espeak)
///
/// // Any custom implementation
/// let config = KittenTTSConfig(phonemizer: .custom(MyPhonemizer()))
/// ```
public enum KittenPhonemizerType: @unchecked Sendable {

    /// Built-in G2P engine (``EPhonemizer``). Works on all platforms with zero
    /// external dependencies. Uses downloaded rule and dictionary data files
    /// to produce high-quality IPA with primary/secondary stress marks and
    /// correct irregular spellings.
    ///
    /// This is the default.
    case builtin

    /// Phonemizer via the system `espeak-ng` binary (macOS only).
    ///
    /// **macOS:** Requires `espeak-ng` to be installed
    /// (`brew install espeak-ng`). Throws
    /// ``KittenTTSError/espeakNotInstalled`` if the binary cannot be found.
    ///
    /// **iOS / Simulator:** Always throws ``KittenTTSError/espeakNotInstalled``
    /// because process execution is unavailable on iOS.
    case espeak

    /// Use a custom phonemizer you supply. Ideal for integrating a
    /// neural G2P model, a CMU dict lookup, or a server-side API.
    ///
    /// ```swift
    /// struct MyPhonemizer: KittenPhonemizerProtocol {
    ///     func phonemize(_ text: String) -> String { … }
    /// }
    /// let config = KittenTTSConfig(phonemizer: .custom(MyPhonemizer()))
    /// ```
    case custom(any KittenPhonemizerProtocol)

    /// Returns a concrete ``KittenPhonemizerProtocol`` instance for this type.
    ///
    /// - Throws: ``KittenTTSError/espeakNotInstalled`` when `.espeak` is
    ///   selected and the `espeak-ng` binary cannot be found (or on iOS).
    public func resolve() throws -> any KittenPhonemizerProtocol {
        switch self {
        case .builtin:       return EPhonemizer()
        case .espeak:        return try ESpeakBinaryPhonemizer.validated()
        case .custom(let p): return p
        }
    }
}
