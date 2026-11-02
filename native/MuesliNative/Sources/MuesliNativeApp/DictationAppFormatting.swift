import Foundation
import MuesliCore

/// Output-only rules. They never change the cleanup prompt or infer a tone.
struct DictationAppFormatting: Codable, Equatable, Sendable {
    enum LetterCase: String, Codable, CaseIterable, Sendable {
        case unchanged, lowercase
        var label: String { self == .unchanged ? "Keep capitalization" : "All lowercase" }
    }
    enum FinalPeriod: String, Codable, CaseIterable, Sendable {
        case keep, remove
        var label: String { self == .keep ? "Keep final period" : "Remove final period" }
    }
    var letterCase: LetterCase = .unchanged
    var finalPeriod: FinalPeriod = .keep

    static let unchanged = Self()
    static let lowercaseChat = Self(letterCase: .lowercase, finalPeriod: .remove)

    var preset: String {
        switch self {
        case .unchanged: return "unchanged"
        case .lowercaseChat: return "lowercase_chat"
        case Self(finalPeriod: .remove): return "no_final_period"
        default: return "custom"
        }
    }

    func apply(to text: String) -> String {
        var result = letterCase == .lowercase ? text.lowercased() : text
        guard finalPeriod == .remove else { return result }
        // Preserve trailing whitespace, ellipses, questions and exclamations.
        // Only the last ASCII period is a formatting target, never internal punctuation.
        let end = result.lastIndex(where: { !$0.isWhitespace })
        if let end, result[end] == ".", end > result.startIndex,
           result[result.index(before: end)] != "." {
            result.remove(at: end)
        }
        return result
    }
}

struct DictationAppFormattingRule: Codable, Equatable, Identifiable, Sendable {
    var bundleID: String
    var appName: String
    var formatting: DictationAppFormatting = .unchanged
    var templateID: String?
    var id: String { bundleID }

    static func apply(_ text: String, bundleID: String?, rules: [Self]) -> String {
        guard let bundleID, let rule = rules.first(where: { $0.bundleID == bundleID }) else { return text }
        return rule.formatting.apply(to: text)
    }

    static func activeRules(_ rules: [Self]) -> [Self] {
        rules.filter { !$0.bundleID.isEmpty && $0.formatting != .unchanged }
    }

    /// Lock the streaming delivery mode at recording start. A live session cannot
    /// retroactively format text already typed if focus later moves to another app.
    static func shouldBufferStreaming(bundleID: String?, rules: [Self]) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return rules.contains { $0.bundleID == bundleID && $0.formatting != .unchanged }
    }
}

/// Templates are reusable starting points. Each app retains its own formatting snapshot.
struct DictationFormattingTemplate: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var formatting: DictationAppFormatting

    static let builtIns: [Self] = [
        .init(id: "unchanged", name: "Original", formatting: .unchanged),
        .init(id: "no_final_period", name: "Casual", formatting: .init(finalPeriod: .remove)),
        .init(id: "lowercase_chat", name: "Lowercase chat", formatting: .lowercaseChat),
    ]

    static let previewText = "Hey Sam, I'll be there at 5. Are you coming? See you soon."

    static func selected(for rule: DictationAppFormattingRule, saved: [Self]) -> Self? {
        if let template = saved.first(where: { $0.id == rule.templateID && $0.formatting == rule.formatting }) {
            return template
        }
        return builtIns.first { $0.formatting == rule.formatting }
    }
}

struct DictationFormattingSuggestion: Identifiable, Equatable {
    let bundleID: String
    let appName: String
    let sessions: Int
    var id: String { bundleID }
    // Suggestions are deliberately narrow. A browser, terminal or unknown app
    // must never inherit a messaging rule merely from its display name.
    var suggestsLowercaseChat: Bool {
        ["net.whatsapp.WhatsApp", "com.apple.MobileSMS", "ru.keepcoder.Telegram", "com.hnc.Discord"].contains(bundleID)
    }

    static func ranked(usage: [InsightsUsage], excluding rules: [DictationAppFormattingRule]) -> [Self] {
        let excluded = Set(rules.map(\.bundleID))
        var seen = Set<String>()
        return usage.sorted {
            if $0.sessions != $1.sessions { return $0.sessions > $1.sessions }
            if $0.words != $1.words { return $0.words > $1.words }
            return $0.id < $1.id
        }.compactMap { row in
            guard row.id.hasPrefix("bundle:"), row.sessions > 0 else { return nil }
            let bundleID = String(row.id.dropFirst("bundle:".count))
            guard !bundleID.isEmpty, !excluded.contains(bundleID), seen.insert(bundleID).inserted else { return nil }
            return Self(bundleID: bundleID, appName: row.name, sessions: row.sessions)
        }
    }
}

// Decode each saved entry independently so an unsupported enum or malformed row
// cannot discard unrelated app rules/templates on the next config save.
struct DictationFormattingEntries<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Element] = []
        while !container.isAtEnd {
            let entry = try container.superDecoder()
            if let value = try? Element(from: entry) { values.append(value) }
        }
        self.values = values
    }
}

extension DictationAppFormatting {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        letterCase = try container.decodeIfPresent(LetterCase.self, forKey: .letterCase) ?? .unchanged
        finalPeriod = try container.decodeIfPresent(FinalPeriod.self, forKey: .finalPeriod) ?? .keep
    }
}

extension DictationAppFormattingRule {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        appName = try container.decode(String.self, forKey: .appName)
        formatting = try container.decodeIfPresent(DictationAppFormatting.self, forKey: .formatting) ?? .unchanged
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID)
    }
}

extension DictationFormattingTemplate {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        formatting = try container.decodeIfPresent(DictationAppFormatting.self, forKey: .formatting) ?? .unchanged
    }
}
