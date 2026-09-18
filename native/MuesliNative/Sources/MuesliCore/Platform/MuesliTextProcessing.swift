import Foundation

/// Canonical, portable transcript text operations owned by the shared Swift core.
///
/// These are the single source of truth for transcript normalization and word
/// counting on every platform. They are intentionally pure, stateless and free
/// of platform persistence, so they can be exported across the C ABI and called
/// by the Windows application without touching `DictationStore`.
public enum MuesliTextProcessing {
    /// Trim leading and trailing whitespace and collapse every internal run of
    /// whitespace — including newlines and CRLF — to a single ASCII space.
    ///
    /// This is the canonical transcript normalization used by the Windows
    /// application. It matches the existing Windows `Normalize` semantics
    /// (`Regex.Replace(text.Trim(), @"\s+", " ")`) while following the Unicode
    /// `White_Space` property on both platforms.
    public static func normalizeTranscript(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var result = ""
        result.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        var hasContent = false

        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                if hasContent { pendingSpace = true }
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.unicodeScalars.append(scalar)
            hasContent = true
        }

        return result
    }

    /// Whitespace-delimited word count. Punctuation-only tokens count as words,
    /// matching the existing Windows and macOS behavior.
    public static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
