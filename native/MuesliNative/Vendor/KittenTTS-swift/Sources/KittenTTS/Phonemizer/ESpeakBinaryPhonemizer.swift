import Foundation

/// An eSpeak-NG backed phonemizer that produces high-quality IPA output.
///
/// eSpeak-NG uses a comprehensive linguistic database to handle irregular
/// English spellings, stress placement, and phonological rules — producing
/// output that closely matches the training distribution of the KittenTTS
/// ONNX model (which was itself trained on eSpeak-NG phoneme sequences).
///
/// ## Platform support
///
/// | Platform | Behaviour |
/// |----------|-----------|
/// | macOS    | Invokes the `espeak-ng` binary. Requires installation (see below). Throws ``KittenTTSError/espeakNotInstalled`` if the binary is not found. |
/// | iOS / Simulator | Always throws ``KittenTTSError/espeakNotInstalled`` — process execution is not available on iOS. |
///
/// ## macOS setup
///
/// Install eSpeak-NG via Homebrew:
/// ```sh
/// brew install espeak-ng
/// ```
///
/// Then select this phonemizer in your config:
/// ```swift
/// let config = KittenTTSConfig(phonemizer: .espeak)
/// let tts = try await KittenTTS(config)
/// ```
///
/// ## Custom binary path
///
/// If `espeak-ng` is installed in a non-standard location, pass the path
/// explicitly:
/// ```swift
/// let p = try ESpeakBinaryPhonemizer.validated(executablePath: "/opt/custom/bin/espeak-ng")
/// let config = KittenTTSConfig(phonemizer: .custom(p))
/// ```
public final class ESpeakBinaryPhonemizer: KittenPhonemizerProtocol {

    // MARK: - Configuration

    /// The resolved path to the `espeak-ng` binary.
    public let resolvedBinaryPath: String

    // MARK: - Init

    /// Creates a validated eSpeak-NG phonemizer.
    ///
    /// - Parameter executablePath: Override the automatic binary search.
    ///   Pass `nil` to search the standard Homebrew paths and `$PATH`.
    /// - Throws: ``KittenTTSError/espeakNotInstalled`` if the binary cannot
    ///   be found, or on iOS where process execution is unavailable.
    public static func validated(executablePath: String? = nil) throws -> ESpeakBinaryPhonemizer {
        #if os(macOS)
        guard let path = findBinary(explicit: executablePath) else {
            throw KittenTTSError.espeakNotInstalled
        }
        return ESpeakBinaryPhonemizer(binaryPath: path)
        #else
        throw KittenTTSError.espeakNotInstalled
        #endif
    }

    private init(binaryPath: String) {
        self.resolvedBinaryPath = binaryPath
    }

    // MARK: - KittenPhonemizerProtocol

    /// Convert a preprocessed English sentence to an IPA phoneme string.
    ///
    /// Invokes `espeak-ng -v en-us --ipa -q`.
    /// Returns an empty string if the process fails unexpectedly at runtime.
    public func phonemize(_ text: String) -> String {
        #if os(macOS)
        return espeakIPA(for: text) ?? ""
        #else
        return ""
        #endif
    }

    // MARK: - Private

    #if os(macOS)
    /// Invoke `espeak-ng --ipa -q` and return the IPA string, or `nil` on any error.
    private func espeakIPA(for text: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedBinaryPath)
        // -v en-us : American English (matches Kokoro's training language)
        // --ipa    : output IPA phonemes
        // -q       : suppress audio output
        // --       : end of option parsing (safe for arbitrary input text)
        process.arguments = ["-v", "en-us", "--ipa", "-q", "--", text]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError  = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let raw = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return postprocessIPA(raw, originalText: text)
    }

    /// Search for the `espeak-ng` binary — explicit path, fixed candidates, then PATH.
    private static func findBinary(explicit: String?) -> String? {
        if let path = explicit {
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        // Well-known Homebrew / system locations
        let fixed = [
            "/opt/homebrew/bin/espeak-ng",   // Apple Silicon Homebrew (standard)
            "/usr/local/bin/espeak-ng",       // Intel Homebrew (standard)
            "/usr/bin/espeak-ng",             // System install
        ]
        if let found = fixed.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return found
        }
        // Fall back to searching every directory in $PATH so non-standard
        // Homebrew prefixes (e.g. ~/homebrew) are found automatically.
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .components(separatedBy: ":")
        return pathDirs
            .map { $0 + "/espeak-ng" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Reassemble raw multi-line `espeak-ng --ipa` output into a single string,
    /// re-inserting the original text's punctuation marks.
    ///
    /// eSpeak-NG breaks its output into one line per clause/sentence boundary,
    /// where each break corresponds to a punctuation mark (`,.!?;:—…`) in the
    /// original text. We extract those punctuation marks in order and interleave
    /// them back between the IPA lines — matching the `preserve_punctuation=True`
    /// behaviour of the Python `phonemizer` library that was used during training.
    private func postprocessIPA(_ raw: String, originalText: String) -> String {
        let ipaLines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Boundary punctuation that causes espeak to emit a new line — in the
        // same order they appear in the original text.
        let punctSet = CharacterSet(charactersIn: ";:,.!?—…")
        let punctSequence: [String] = originalText.unicodeScalars
            .filter { punctSet.contains($0) }
            .map { String($0) }

        // Each IPA line pairs with the punctuation mark that ended its clause.
        var parts: [String] = []
        for (i, line) in ipaLines.enumerated() {
            parts.append(line)
            if i < punctSequence.count {
                parts.append(punctSequence[i])
            }
        }
        return parts.joined(separator: " ")
    }
    #endif
}
