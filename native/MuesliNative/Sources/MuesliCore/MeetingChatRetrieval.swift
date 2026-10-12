import Foundation
import SQLite3

/// Local, revision-aware passage search. Provider calls never happen here.
public struct MeetingChatRetrieval: Sendable {
    public let databaseURL: URL
    private let useFTS: Bool
    public init(databaseURL: URL, useFTS: Bool = true) { self.databaseURL = databaseURL; self.useFTS = useFTS }

    public func retrieve(question: String, scope: MeetingChatScope, priorQuestions: [String] = [], broadRecap: Bool = false, includeScopeContext: Bool = false) throws -> MeetingChatEvidence {
        try DictationStore(databaseURL: databaseURL).withChatDatabase { db in
            let ftsAvailable = useFTS && prepareFTS(db: db)
            var metrics = try reconcileIndex(db: db)
            // Warm searches use a read transaction; they neither load meeting text nor take a writer lock.
            try MeetingChatSQL.execute("BEGIN DEFERRED", db: db)
            defer { try? MeetingChatSQL.execute("ROLLBACK", db: db) }
            let (scopeCondition, scopeBindings) = scopeFilter(scope)
            let eligible = Dictionary(uniqueKeysWithValues: try MeetingChatSQL.rows(
                "SELECT s.meeting_id,s.revision FROM meeting_chat_index_state s WHERE \(scopeCondition)", scopeBindings, db: db) {
                    (sqlite3_column_int64($0, 0), MeetingChatSQL.text($0, 1))
                })
                let stopWords: Set<String> = ["what", "when", "where", "who", "how", "did", "do", "we", "i", "the", "a", "an", "is", "was", "were", "about", "and", "to", "of", "in", "it", "that", "this", "my", "our", "please", "tell", "me"]
                let tokens = (question + " " + priorQuestions.suffix(2).joined(separator: " ")).lowercased()
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !stopWords.contains($0) }
                var candidates: [MeetingChatPassage]
                let originalsFirst = "CASE WHEN json_extract(p.body,'$.kind')='generatedNotes' THEN 1 ELSE 0 END"
                let baseJoin = "JOIN meeting_chat_index_state s ON s.meeting_id=p.meeting_id AND s.revision=p.revision"
                if broadRecap {
                    candidates = try readPassages("""
                        SELECT p.body FROM meeting_chat_passages p \(baseJoin) WHERE \(scopeCondition)
                        ORDER BY ROW_NUMBER() OVER (PARTITION BY p.meeting_id,json_extract(p.body,'$.kind') ORDER BY CAST(json_extract(p.body,'$.range.location') AS INTEGER)),s.start_time DESC,\(originalsFirst),p.id LIMIT 257
                        """, scopeBindings, db: db)
                } else if ftsAvailable, !tokens.isEmpty,
                          let matched = try? readPassages("SELECT p.body FROM meeting_chat_fts f JOIN meeting_chat_passages p ON p.seq=f.rowid \(baseJoin) WHERE \(scopeCondition) AND meeting_chat_fts MATCH ? ORDER BY bm25(meeting_chat_fts),\(originalsFirst) LIMIT 257", scopeBindings + [.text(tokens.map { "\"\($0)\"" }.joined(separator: " OR "))], db: db) {
                    candidates = matched
                } else {
                    let terms = tokens.isEmpty ? [question.trimmingCharacters(in: .whitespacesAndNewlines)] : tokens
                    let termsToSearch = terms.filter { !$0.isEmpty }
                    let condition = termsToSearch.isEmpty ? "0" : termsToSearch.map { _ in "p.text LIKE ? ESCAPE '\\'" }.joined(separator: " OR ")
                    let bindings = termsToSearch.map { term -> MeetingChatSQL.Value in
                        let escaped = term.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
                        return .text("%\(escaped)%")
                    }
                    candidates = try readPassages("SELECT p.body FROM meeting_chat_passages p \(baseJoin) WHERE \(scopeCondition) AND (\(condition)) ORDER BY \(originalsFirst),s.start_time DESC,p.id LIMIT 257", scopeBindings + bindings, db: db)
                }
                metrics.decodedCandidateCount = candidates.count
                var candidateLimited = candidates.count > 256
                candidates = Array(candidates.prefix(256)).filter(Self.isContentPassage)
                let supplyingContext: Bool
                if case .meetings(let ids) = scope.selection { supplyingContext = includeScopeContext && !ids.isEmpty } else { supplyingContext = false }
                if supplyingContext {
                    // An explicit attachment supplies context even when the question's
                    // vocabulary never occurs in the meeting. Prioritize lexical matches
                    // before filling remaining space with representative source context.
                    let context = try readPassages("""
                        SELECT p.body FROM meeting_chat_passages p \(baseJoin) WHERE \(scopeCondition)
                        ORDER BY ROW_NUMBER() OVER (PARTITION BY p.meeting_id,json_extract(p.body,'$.kind') ORDER BY CAST(json_extract(p.body,'$.range.location') AS INTEGER)),s.start_time DESC,\(originalsFirst),p.id LIMIT 257
                        """, scopeBindings, db: db)
                    metrics.decodedCandidateCount += context.count
                    candidateLimited = candidateLimited || context.count > 256
                    let content = Array(context.prefix(256)).filter(Self.isContentPassage)
                    var representedKinds = Set<String>()
                    let representatives = content.filter { representedKinds.insert("\($0.meetingID):\($0.kind.rawValue)").inserted }
                    var seen = Set<String>()
                    candidates = (candidates + representatives + content).filter { seen.insert($0.id).inserted }
                }
                let packetLimit = supplyingContext ? 14_000 : 10_000
                var selected: [MeetingChatPassage] = []; var usedBytes = 0; var packetBytes = 0
                for var passage in candidates {
                    try Task.checkCancellation()
                    guard usedBytes + passage.excerpt.utf8.count <= 12_000 else { continue }
                    passage.sourceKey = "S\(selected.count + 1)"
                    let footprint = MeetingChatPassages.promptByteCount(passage)
                    guard packetBytes + footprint <= packetLimit else { continue }
                    packetBytes += footprint
                    usedBytes += passage.excerpt.utf8.count
                    passage.sourceKey = "S\(selected.count + 1)"; selected.append(passage)
                }
                let represented = Set(selected.map(\.meetingID))
                return MeetingChatEvidence(scope: scope, passages: selected,
                    dependencies: represented.sorted().map { .init(meetingID: $0, revision: eligible[$0]!) },
                    coverage: .init(eligibleMeetingCount: eligible.count, evidenceMeetingCount: represented.count,
                        isPartialRecap: (broadRecap || supplyingContext) && (candidateLimited || selected.count < candidates.count || represented.count < eligible.count)), metrics: metrics)
        }
    }

    /// Can be scheduled in the background before the user asks their first question.
    @discardableResult public func prepareIndex() throws -> MeetingChatRetrievalMetrics {
        try DictationStore(databaseURL: databaseURL).withChatDatabase { db in
            if useFTS { _ = prepareFTS(db: db) }
            return try reconcileIndex(db: db)
        }
    }

    private func reconcileIndex(db: OpaquePointer?) throws -> MeetingChatRetrievalMetrics {
        var metrics = MeetingChatRetrievalMetrics()
        while true {
            try Task.checkCancellation()
            let dirty = try MeetingChatSQL.rows("SELECT meeting_id FROM meeting_chat_dirty_sources ORDER BY meeting_id LIMIT 200", db: db) { sqlite3_column_int64($0, 0) }
            guard !dirty.isEmpty else { return metrics }
            try MeetingChatSQL.transaction(db: db) {
                let snapshots = try MeetingChatSQL.snapshots(scope: .init(selection: .meetings(dirty)), db: db)
                metrics.sourceSnapshotCount += snapshots.count
                let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.meetingID, $0) })
                for id in dirty {
                    try Task.checkCancellation()
                    try MeetingChatSQL.execute("DELETE FROM meeting_chat_passages WHERE meeting_id=?", [.integer(id)], db: db)
                    try MeetingChatSQL.execute("DELETE FROM meeting_chat_index_state WHERE meeting_id=?", [.integer(id)], db: db)
                    if let source = byID[id] {
                        metrics.reindexedMeetingCount += 1
                        let passages = MeetingChatPassages.extract(from: source)
                        if !passages.isEmpty {
                            for passage in passages {
                                let searchable = source.title + " " + source.participantNames.joined(separator: " ") + " " + passage.excerpt
                                try MeetingChatSQL.execute("INSERT INTO meeting_chat_passages(id,meeting_id,revision,text,body) VALUES(?,?,?,?,?)", [.text(passage.id), .integer(id), .text(passage.revision), .text(searchable), .text(try MeetingChatSQL.encode(passage))], db: db)
                            }
                            try MeetingChatSQL.execute("INSERT INTO meeting_chat_index_state VALUES(?,?,?,?)", [.integer(id), .text(source.revision), .real(source.startDate.timeIntervalSince1970), source.folderID.map { .integer($0) } ?? .null], db: db)
                        }
                    }
                    try MeetingChatSQL.execute("DELETE FROM meeting_chat_dirty_sources WHERE meeting_id=?", [.integer(id)], db: db)
                }
            }
        }
    }

    private func scopeFilter(_ scope: MeetingChatScope) -> (String, [MeetingChatSQL.Value]) {
        var conditions: [String] = []; var bindings: [MeetingChatSQL.Value] = []
        switch scope.selection {
        case .all: break
        case .folder(let id): conditions.append("s.folder_id=?"); bindings.append(.integer(id))
        case .meetings(let ids):
            conditions.append(ids.isEmpty ? "0" : "s.meeting_id IN (\(ids.map { _ in "?" }.joined(separator: ",")))")
            bindings += ids.map { .integer($0) }
        }
        if let start = scope.startDate { conditions.append("s.start_time>=?"); bindings.append(.real(start.timeIntervalSince1970)) }
        if let end = scope.endDateExclusive { conditions.append("s.start_time<?"); bindings.append(.real(end.timeIntervalSince1970)) }
        return (conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), bindings)
    }

    private static func isContentPassage(_ passage: MeetingChatPassage) -> Bool {
        guard passage.kind != .transcript else { return true }
        // A Markdown section heading is navigation, not sufficient source evidence.
        // Filter at retrieval time so existing caches receive the same behavior.
        let text = passage.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.range(of: #"^#{1,6}\s+[^\r\n]+$"#, options: .regularExpression) == nil
    }

    private func readPassages(_ sql: String, _ values: [MeetingChatSQL.Value], db: OpaquePointer?) throws -> [MeetingChatPassage] {
        try MeetingChatSQL.rows(sql, values, db: db) { try MeetingChatSQL.decode(MeetingChatPassage.self, MeetingChatSQL.text($0, 0)) }
    }
    private func prepareFTS(db: OpaquePointer?) -> Bool {
        do {
            // Keep warm searches read-only. Setup is complete only when the current
            // table and both triggers exist; interrupted/legacy setup is rebuilt.
            func isReady() throws -> Bool {
                let names = try MeetingChatSQL.rows("SELECT name FROM sqlite_master WHERE name IN ('meeting_chat_fts','meeting_chat_passage_inserted_v2','meeting_chat_passage_removed_v2')", db: db) { MeetingChatSQL.text($0, 0) }
                return names.count == 3
            }
            if try isReady() { return true }
            return try MeetingChatSQL.transaction(db: db) {
                // Another connection may have finished setup while we waited.
                if try isReady() { return true }
                for name in ["meeting_chat_passage_inserted", "meeting_chat_passage_removed", "meeting_chat_passage_inserted_v2", "meeting_chat_passage_removed_v2"] {
                    try MeetingChatSQL.execute("DROP TRIGGER IF EXISTS \(name)", db: db)
                }
                try MeetingChatSQL.execute("DROP TABLE IF EXISTS meeting_chat_fts", db: db)
                try MeetingChatSQL.execute("CREATE VIRTUAL TABLE meeting_chat_fts USING fts5(text)", db: db)
                try MeetingChatSQL.execute("CREATE TRIGGER meeting_chat_passage_inserted_v2 AFTER INSERT ON meeting_chat_passages BEGIN INSERT INTO meeting_chat_fts(rowid,text) VALUES(NEW.seq,NEW.text); END", db: db)
                try MeetingChatSQL.execute("CREATE TRIGGER meeting_chat_passage_removed_v2 AFTER DELETE ON meeting_chat_passages BEGIN DELETE FROM meeting_chat_fts WHERE rowid=OLD.seq; END", db: db)
                try MeetingChatSQL.execute("INSERT INTO meeting_chat_fts(rowid,text) SELECT seq,text FROM meeting_chat_passages", db: db)
                return true
            }
        } catch { return false }
    }
}
