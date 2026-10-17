import Foundation

private final class ChineseScalarTransformCache: @unchecked Sendable {
    private let lock = NSLock()
    private var mappings: [UInt32: Bool] = [:]

    func mapping(for scalar: Unicode.Scalar) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return mappings[scalar.value]
    }

    func store(_ mapping: Bool, for scalar: Unicode.Scalar) {
        lock.lock()
        defer { lock.unlock() }
        if mappings.count >= 8_192, mappings[scalar.value] == nil {
            mappings.removeAll(keepingCapacity: true)
        }
        mappings[scalar.value] = mapping
    }
}

/// An explicit output-script preference, separate from the language accepted by ASR models.
public enum ChineseTranscriptionOutput {
    public static let traditionalLanguageCode = "zh-TW"
    public static let whisperPrompt = "以下是普通話的句子。"
    private static let hanRunExpression = try? NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]+"#)
    private static let kanaHangulExpression = try? NSRegularExpression(pattern: #"[\p{Hiragana}\p{Katakana}\p{Hangul}]"#)
    private static let singleHanExpression = try? NSRegularExpression(pattern: #"^\p{Han}$"#)
    // Avoid ICU contextually expanding this shared glyph into a Taiwan vocabulary variant.
    private static let ambiguousSharedScalars = Set("了".unicodeScalars)
    private static let scalarTransformCache = ChineseScalarTransformCache()

    public static func isTraditional(_ language: String?) -> Bool {
        language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == traditionalLanguageCode.lowercased()
    }

    public static func apply(_ text: String, language: String?) -> String {
        guard isTraditional(language), !text.isEmpty else { return text }
        // Preserve Japanese/Korean words without exempting separate Chinese phrases.
        guard let expression = hanRunExpression else { return text }
        var output = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let run = String(output[range])
            guard !containsKanaOrHangul(run) else { continue }
            output.replaceSubrange(range, with: convertHanRun(run))
        }
        return output
    }

    public static func joinsHanBoundary(previous: String, next: String) -> Bool {
        guard let previousScalar = previous.unicodeScalars.last,
              let nextScalar = next.unicodeScalars.first,
              let expression = singleHanExpression else {
            return false
        }
        func isHan(_ scalar: Unicode.Scalar) -> Bool {
            let value = String(scalar)
            let range = NSRange(value.startIndex..., in: value)
            return expression.firstMatch(in: value, range: range)?.range == range
        }
        return isHan(previousScalar) && isHan(nextScalar)
    }

    private static func transform(_ text: String, _ id: String) -> String {
        text.applyingTransform(StringTransform(id), reverse: false) ?? text
    }

    private static func convertHanRun(_ text: String) -> String {
        let source = Array(text.unicodeScalars)
        let nativeToHans = Array(transform(text, "Hant-Hans").unicodeScalars)
        guard nativeToHans.count == source.count else {
            return convertHanRunPerScalar(text, source: source)
        }
        let traditional = source.indices.map { nativeToHans[$0] != source[$0] }

        // Supply Simplified context so mixed 頭发 still resolves the phrase 头发→頭髮.
        // Overlay original Traditional glyphs: ICU can otherwise rewrite even 剃髮.
        let candidate = Array(transform(String(String.UnicodeScalarView(nativeToHans)), "Hans-Hant").unicodeScalars)
        guard candidate.count == source.count else { return convertHanRunPerScalar(text, source: source) }
        let simplified = source.indices.map { index in
            guard !traditional[index], !ambiguousSharedScalars.contains(source[index]), candidate[index] != source[index] else { return false }
            if let mapsToDifferentScalar = scalarTransformCache.mapping(for: source[index]) {
                return mapsToDifferentScalar
            }
            let scalar = String(source[index])
            // Full-run conversion can make shared glyphs such as 了 context-sensitive.
            // Cache scalar checks across transcript and preview conversions.
            let mapsToDifferentScalar = transform(scalar, "Hans-Hant") != scalar
            scalarTransformCache.store(mapsToDifferentScalar, for: source[index])
            return mapsToDifferentScalar
        }
        guard simplified.contains(true) else { return text }
        let converted = source.indices.map { index -> String in
            if traditional[index] || ambiguousSharedScalars.contains(source[index]) {
                return String(source[index])
            }
            return String(candidate[index])
        }
        return converted.joined()
    }

    private static func convertHanRunPerScalar(_ text: String, source: [Unicode.Scalar]) -> String {
        let traditional = source.map { transform(String($0), "Hant-Hans") != String($0) }
        let simplified = source.indices.map {
            !traditional[$0]
                && !ambiguousSharedScalars.contains(source[$0])
                && transform(String(source[$0]), "Hans-Hant") != String(source[$0])
        }
        guard simplified.contains(true) else { return text }

        // If ICU expands or contracts a run, scalar positions no longer align.
        // Keep the original per-scalar conversion fallback for that uncommon case.
        let candidate = Array(transform(transform(text, "Hant-Hans"), "Hans-Hant").unicodeScalars)
        return source.indices.map { index -> String in
            if traditional[index] || ambiguousSharedScalars.contains(source[index]) {
                return String(source[index])
            }
            if candidate.count == source.count { return String(candidate[index]) }
            return simplified[index] ? transform(String(source[index]), "Hans-Hant") : String(source[index])
        }.joined()
    }

    private static func containsKanaOrHangul(_ text: String) -> Bool {
        guard let expression = kanaHangulExpression else { return true }
        let range = NSRange(text.startIndex..., in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }
}
