import Foundation

/// Errors thrown by the KittenTTS SDK.
public enum KittenTTSError: LocalizedError, Sendable {

    // MARK: - Input

    /// The input text was empty or contained only whitespace.
    case emptyInput

    // MARK: - Engine

    /// The engine has not been initialised yet. Call ``KittenTTS/init(_:)`` first.
    case engineNotReady

    /// The model file could not be found at the expected path.
    case modelFileNotFound(URL)

    /// The voice embeddings file could not be found at the expected path.
    case voicesFileNotFound(URL)

    /// No embedding exists in the voices file for the requested voice.
    case noVoiceEmbedding(KittenVoice)

    /// The ONNX inference step failed.
    case inferenceFailed(String)

    /// The model produced zero audio samples.
    case emptyOutput

    // MARK: - Download

    /// The model download failed.
    case downloadFailed(String)

    /// The downloaded file data is corrupt or in an unexpected format.
    case invalidModelData(String)

    // MARK: - Phonemizer

    /// The `espeak-ng` binary could not be found (macOS only).
    ///
    /// Install via Homebrew (`brew install espeak-ng`) or pass an explicit
    /// path via ``ESpeakBinaryPhonemizer/validated(executablePath:)``.
    case espeakNotInstalled

    /// The built-in EPhonemizer failed to load its data files.
    case phonemizerLoadFailed(String)

    // MARK: - Audio

    /// The audio session could not be activated.
    case audioSessionFailed(String)

    /// Audio playback failed.
    case playbackFailed(String)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Input text must not be empty."
        case .engineNotReady:
            return "KittenTTS engine is not initialised. Await KittenTTS.init() before calling generate()."
        case .modelFileNotFound(let url):
            return "Model file not found: \(url.lastPathComponent)"
        case .voicesFileNotFound(let url):
            return "Voice embeddings file not found: \(url.lastPathComponent)"
        case .noVoiceEmbedding(let voice):
            return "No embedding found for voice '\(voice.displayName)' (id: \(voice.rawValue))."
        case .inferenceFailed(let msg):
            return "ONNX inference failed: \(msg)"
        case .emptyOutput:
            return "The model produced no audio samples."
        case .downloadFailed(let msg):
            return "Model download failed: \(msg)"
        case .invalidModelData(let msg):
            return "Invalid model data: \(msg)"
        case .espeakNotInstalled:
            return "espeak-ng binary not found. Install via Homebrew: brew install espeak-ng"
        case .phonemizerLoadFailed(let msg):
            return "Phonemizer failed to load: \(msg)"
        case .audioSessionFailed(let msg):
            return "Audio session error: \(msg)"
        case .playbackFailed(let msg):
            return "Playback failed: \(msg)"
        }
    }
}
