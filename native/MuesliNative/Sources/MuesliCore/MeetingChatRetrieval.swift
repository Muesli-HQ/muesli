import Foundation
import SQLite3

/// Local, revision-aware passage search. Provider calls never happen here.
public struct MeetingChatRetrieval: Sendable {
    public let databaseURL: URL
    private let useFTS: Bool
    public init(databaseURL: URL, useFTS: Bool = true) { self.databaseURL = databaseURL; self.useFTS = useFTS }

    public func retrieve(question: String, scope: MeetingChatScope, priorQuestions: [String] = [], broadRecap: Bool = false) throws -> MeetingChatEvidence {
        try DictationStore(databaseURL: databaseURL).withChatDatabase { db in
            try MeetingChatSQL.transaction(db: db) {
                let ftsAvailable = useFTS && prepareFTS(db: db)
                var eligible: [Int64: String] = [:]; var afterID: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let page = try MeetingChatSQL.snapshots(scope: scope, db: db, afterID: afterID)
                    guard let last = page.last else { break }
                    afterID = last.meetingID
                    for source in page {
                        guard scope.startDate.map({ source.startDate >= $0 }) ?? true,
                              scope.endDateExclusive.map({ source.startDate < $0 }) ?? true else { continue }
                        let passages = MeetingChatPassages.extract(from: source)
                        guard !passages.isEmpty else { continue }
                        eligible[source.meetingID] = source.revision
                        let cached = try MeetingChatSQL.rows("SELECT revision FROM meeting_chat_passages WHERE meeting_id=? LIMIT 1", [.integer(source.meetingID)], db: db) { MeetingChatSQL.text($0, 0) }.first
                        if cached != source.revision {
                            try MeetingChatSQL.execute("DELETE FROM meeting_chat_passages WHERE meeting_id=?", [.integer(source.meetingID)], db: db)
                            for passage in passages {
                                let searchable = source.title + " " + source.participantNames.joined(separator: " ") + " " + passage.excerpt
                                try MeetingChatSQL.execute("INSERT INTO meeting_chat_passages VALUES(?,?,?,?,?)", [.text(passage.id), .integer(passage.meetingID), .text(passage.revision), .text(searchable), .text(try MeetingChatSQL.encode(passage))], db: db)
                            }
                        }
                    }
                }
                let stopWords: Set<String> = ["what", "when", "where", "who", "how", "did", "do", "we", "i", "the", "a", "an", "is", "was", "were", "about", "and", "to", "of", "in", "it", "that", "this", "my", "our", "please", "tell", "me"]
                let tokens = (question + " " + priorQuestions.suffix(2).joined(separator: " ")).lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !stopWords.contains($0) }
                var candidates: [MeetingChatPassage]
                if broadRecap {
                    candidates = try readPassages("SELECT body FROM meeting_chat_passages ORDER BY meeting_id DESC,id", [], db: db)
                } else if ftsAvailable, !tokens.isEmpty,
                          let matched = try? readPassages("SELECT p.body FROM meeting_chat_fts f JOIN meeting_chat_passages p ON p.id=f.id WHERE meeting_chat_fts MATCH ? ORDER BY bm25(meeting_chat_fts)", [.text(tokens.map { "\"\($0)\"" }.joined(separator: " OR "))], db: db) {
                    candidates = matched
                } else {
                    let terms = tokens.isEmpty ? [question.trimmingCharacters(in: .whitespacesAndNewlines)] : tokens
                    let termsToSearch = terms.filter { !$0.isEmpty }
                    let condition = termsToSearch.isEmpty ? "0" : termsToSearch.map { _ in "text LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
                    let bindings = termsToSearch.map { term -> MeetingChatSQL.Value in
                        let escaped = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                        return .text("%\(escaped)%")
                    }
                    candidates = try readPassages("SELECT body FROM meeting_chat_passages WHERE \(condition) ORDER BY meeting_id DESC,id", bindings, db: db)
                }
                candidates = candidates.filter { eligible[$0.meetingID] == $0.revision }
                let relevanceOrder = Dictionary(uniqueKeysWithValues: candidates.enumerated().map { ($0.element.id, $0.offset) })
                // Prefer original evidence and distribute broad recaps across meetings before adding detail.
                candidates.sort { lhs, rhs in
                    if lhs.kind == .generatedNotes && rhs.kind != .generatedNotes { return false }
                    if rhs.kind == .generatedNotes && lhs.kind != .generatedNotes { return true }
                    if !broadRecap { return relevanceOrder[lhs.id, default: 0] < relevanceOrder[rhs.id, default: 0] }
                    return lhs.startDate == rhs.startDate ? lhs.id < rhs.id : lhs.startDate > rhs.startDate
                }
                if broadRecap {
                    var seen = Set<Int64>(); var first: [MeetingChatPassage] = []; var rest: [MeetingChatPassage] = []
                    for passage in candidates {
                        if seen.insert(passage.meetingID).inserted { first.append(passage) } else { rest.append(passage) }
                    }
                    candidates = first + rest
                }
                var selected: [MeetingChatPassage] = []; var usedBytes = 0
                for var passage in candidates {
                    try Task.checkCancellation()
                    guard usedBytes + passage.excerpt.utf8.count <= 12_000 else { continue }
                    usedBytes += passage.excerpt.utf8.count
                    passage.sourceKey = "S\(selected.count + 1)"; selected.append(passage)
                }
                let represented = Set(selected.map(\.meetingID))
                return MeetingChatEvidence(scope: scope, passages: selected,
                    dependencies: represented.sorted().map { .init(meetingID: $0, revision: eligible[$0]!) },
                    coverage: .init(eligibleMeetingCount: eligible.count, evidenceMeetingCount: represented.count,
                        isPartialRecap: broadRecap && (selected.count < candidates.count || represented.count < eligible.count)))
            }
        }
    }

    private func readPassages(_ sql: String, _ values: [MeetingChatSQL.Value], db: OpaquePointer?) throws -> [MeetingChatPassage] {
        try MeetingChatSQL.rows(sql, values, db: db) { try MeetingChatSQL.decode(MeetingChatPassage.self, MeetingChatSQL.text($0, 0)) }
    }
    private func prepareFTS(db: OpaquePointer?) -> Bool {
        do {
            let existed = try MeetingChatSQL.rows("SELECT name FROM sqlite_master WHERE name='meeting_chat_fts'", db: db) { MeetingChatSQL.text($0, 0) }.first != nil
            try MeetingChatSQL.execute("CREATE VIRTUAL TABLE IF NOT EXISTS meeting_chat_fts USING fts5(id UNINDEXED,text)", db: db)
            try MeetingChatSQL.execute("CREATE TRIGGER IF NOT EXISTS meeting_chat_passage_inserted AFTER INSERT ON meeting_chat_passages BEGIN INSERT INTO meeting_chat_fts(id,text) VALUES(NEW.id,NEW.text); END", db: db)
            try MeetingChatSQL.execute("CREATE TRIGGER IF NOT EXISTS meeting_chat_passage_removed AFTER DELETE ON meeting_chat_passages BEGIN DELETE FROM meeting_chat_fts WHERE id=OLD.id; END", db: db)
            if !existed { try MeetingChatSQL.execute("INSERT INTO meeting_chat_fts(id,text) SELECT id,text FROM meeting_chat_passages", db: db) }
            return true
        } catch { return false }
    }
}
