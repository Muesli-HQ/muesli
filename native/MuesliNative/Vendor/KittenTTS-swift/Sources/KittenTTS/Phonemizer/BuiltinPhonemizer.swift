/// A simple rule-based English G2P phonemizer.
///
/// Converts normalised English text to IPA phoneme strings using a hand-curated
/// dictionary of ~300 common words with a simplified NRL-style letter-to-sound
/// rule fallback for unknown words.
///
/// This phonemizer requires no external dependencies and works identically on
/// iOS, macOS, and in simulators. It is a lightweight alternative to the
/// default ``EPhonemizer``.
///
/// ```swift
/// let config = KittenTTSConfig(phonemizer: .custom(BuiltinPhonemizer()))
/// ```
public final class BuiltinPhonemizer: KittenPhonemizerProtocol {
    public init() {}

    /// Convert a preprocessed English sentence to an IPA phoneme string
    /// using the internal rule-based G2P engine.
    public func phonemize(_ text: String) -> String {
        Phonemizer.phonemize(text)
    }
}
