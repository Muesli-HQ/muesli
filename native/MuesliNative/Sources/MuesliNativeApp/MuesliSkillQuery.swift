import Foundation
import MuesliCore

/// Slash discovery at the start of a composer line. URL/path fragments and
/// selected/marked text must remain ordinary native editor input.
struct MuesliSkillQuery: Equatable {
    let query: String
    let range: NSRange

    static func find(in text: String, selection: NSRange) -> Self? {
        let ns = text as NSString
        guard selection.length == 0, selection.location != NSNotFound,
              selection.location >= 0, selection.location <= ns.length else { return nil }
        let prefix = ns.substring(to: selection.location)
        let line = prefix.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == "/" else { return nil }
        let query = String(trimmed.dropFirst())
        guard query.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" }),
              query.utf8.count <= 100 else { return nil }
        let length = (String(trimmed) as NSString).length
        return .init(query: query, range: NSRange(location: selection.location - length, length: length))
    }

    var matches: [MuesliHistoryTask] { matches(in: MuesliHistoryTask.allCases) }

    /// Only an actual suggestion may take over Return/Tab/Send.
    func interceptsSubmission(in catalog: [MuesliHistoryTask]) -> Bool { !matches(in: catalog).isEmpty }

    func matches(in catalog: [MuesliHistoryTask]) -> [MuesliHistoryTask] {
        let key = query.lowercased()
        if key.isEmpty || "skills".hasPrefix(key) { return catalog }
        return catalog.filter {
            $0.id.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    func removing(from text: String) -> String {
        let ns = text as NSString
        guard range.location >= 0, range.length >= 0, range.location <= ns.length,
              range.length <= ns.length - range.location, ns.substring(with: range) == "/" + query else { return text }
        return ns.replacingCharacters(in: range, with: "")
    }
}

/// The tag lives in the editor text, so paste, undo and draft restoration all
/// preserve the exact invocation without a second piece of selection state.
struct MuesliSkillInvocation: Identifiable {
    let id = UUID()
    let skill: MuesliHistoryTask
    let tagRange: NSRange
    let prompt: String

    init?(draft: String, catalog: [MuesliHistoryTask] = MuesliHistoryTask.allCases) {
        let parts = draft.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let token = parts.first, token.first == "$",
              let skill = catalog.first(where: { $0.id == token.dropFirst() }) else { return nil }
        self.skill = skill
        tagRange = NSRange(token.startIndex..<token.endIndex, in: draft)
        prompt = parts.dropFirst().first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }


}

/// Only a title explicitly marked by the editor serializes as a skill.
struct SkillTagPresentation {
    static let attribute = NSAttributedString.Key("MuesliComposerSkillID")
    let skill: MuesliHistoryTask
    let rawRange: NSRange
    var title: String { skill == .followUps ? "Follow-ups" : skill.title }
    var visibleRange: NSRange { NSRange(location: rawRange.location, length: title.utf16.count) }

    init?(draft: String, catalog: [MuesliHistoryTask] = MuesliHistoryTask.allCases) {
        guard let invocation = MuesliSkillInvocation(draft: draft, catalog: catalog) else { return nil }
        skill = invocation.skill
        rawRange = invocation.tagRange
    }

    static func displayText(_ draft: String, catalog: [MuesliHistoryTask] = MuesliHistoryTask.allCases) -> String {
        guard let tag = Self(draft: draft, catalog: catalog) else { return draft }
        return (draft as NSString).replacingCharacters(in: tag.rawRange, with: tag.title)
    }

    static func draft(from display: NSAttributedString, catalog: [MuesliHistoryTask] = MuesliHistoryTask.allCases) -> String {
        let text = display.string
        guard let start = text.firstIndex(where: { !$0.isWhitespace }) else { return text }
        let offset = start.utf16Offset(in: text)
        guard let id = display.attribute(attribute, at: offset, effectiveRange: nil) as? String,
              let tag = Self(draft: "$" + id, catalog: catalog), text[start...].hasPrefix(tag.title) else { return text }
        let end = text.index(start, offsetBy: tag.title.count)
        guard end == text.endIndex || text[end].isWhitespace else { return text }
        return text.replacingCharacters(in: start..<end, with: "$" + id)
    }

    func displayRange(for range: NSRange) -> NSRange { map(range, from: rawRange, to: visibleRange) }
    func draftRange(for range: NSRange) -> NSRange { map(range, from: visibleRange, to: rawRange) }

    private func map(_ range: NSRange, from source: NSRange, to target: NSRange) -> NSRange {
        func offset(_ value: Int) -> Int {
            if value <= source.location { return value }
            if value >= NSMaxRange(source) { return value + target.length - source.length }
            return target.location + min(value - source.location, target.length - 1)
        }
        let start = offset(range.location)
        return NSRange(location: start, length: offset(NSMaxRange(range)) - start)
    }
}
