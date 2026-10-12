import Foundation
import SQLite3

/// Opens the explicitly supplied app database per operation; no shared mutable connection.
public struct MeetingChatStore: Sendable {
    public let databaseURL: URL
    public init(databaseURL: URL) { self.databaseURL = databaseURL }
    private func connection<T>(_ operation: (OpaquePointer?) throws -> T) throws -> T {
        try DictationStore(databaseURL: databaseURL).withChatDatabase(operation)
    }
    public func createSession(scope: MeetingChatScope, title: String, anchorMeetingID: Int64? = nil) throws -> MeetingChatSession {
        let now = Date()
        var session = MeetingChatSession(id: UUID(), title: title, scope: scope, createdAt: now, updatedAt: now, contextStartOrdinal: 0)
        session.titleIsAutomatic = true
        var anchor = anchorMeetingID
        if anchor == nil, case .meetings(let ids) = scope.selection, Set(ids).count == 1 { anchor = ids.first }
        return try connection { db in try MeetingChatSQL.transaction(db: db) {
            try MeetingChatSQL.execute("INSERT INTO meeting_chat_sessions VALUES(?,?,?)", [.text(session.id.uuidString), .text(try MeetingChatSQL.encode(session)), .real(now.timeIntervalSince1970)], db: db)
            try saveSelectedMeetings(session, db: db)
            if let anchor { try MeetingChatSQL.linkSession(session.id, meetingID: anchor, role: "anchor", db: db) }
            session.anchorMeetingID = try self.session(session.id, db: db).anchorMeetingID
            return session
        } }
    }
    /// Includes threads anchored to, explicitly scoped to, or with evidence from this meeting.
    /// Scope membership and evidence dependencies remain separate: selection alone is not consultation.
    public func sessions(meetingID: Int64? = nil) throws -> [MeetingChatSession] {
        try connection { db in
            let filter = meetingID == nil ? "" : """
                WHERE EXISTS (SELECT 1 FROM meeting_chat_session_meetings sm WHERE sm.session_id=s.id AND sm.meeting_id=?)
                   OR EXISTS (SELECT 1 FROM meeting_chat_turns t JOIN meeting_chat_dependencies d ON d.turn_id=t.id
                              JOIN meetings m ON m.id=d.meeting_id WHERE t.session_id=s.id AND d.meeting_id=? AND m.deleted_at IS NULL)
                """
            let values: [MeetingChatSQL.Value] = meetingID.map { [.integer($0), .integer($0)] } ?? []
            return try MeetingChatSQL.rows("SELECT s.body,(SELECT meeting_id FROM meeting_chat_session_meetings WHERE session_id=s.id AND role='anchor') FROM meeting_chat_sessions s \(filter) ORDER BY s.updated_at DESC,s.id", values, db: db) {
                var session = try MeetingChatSQL.decode(MeetingChatSession.self, MeetingChatSQL.text($0, 0))
                session.anchorMeetingID = sqlite3_column_type($0, 1) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 1)
                return session
            }
        }
    }
    public func hasChatHistory() throws -> Bool {
        try connection { db in
            !(try MeetingChatSQL.rows("SELECT 1 FROM meeting_chat_turns LIMIT 1", db: db) { _ in true }).isEmpty
        }
    }
    public func turns(sessionID: UUID) throws -> [MeetingChatTurn] {
        try connection { db in try MeetingChatSQL.rows("SELECT body FROM meeting_chat_turns WHERE session_id=? ORDER BY ordinal", [.text(sessionID.uuidString)], db: db) {
            try MeetingChatSQL.decode(MeetingChatTurn.self, MeetingChatSQL.text($0, 0))
        } }
    }
    /// Changing retrieval scope does not erase conversation. Only current, completed
    /// exchanges are reusable, and their inherited dependencies remain deletion-tracked.
    /// Historical citations/excerpts are deliberately not returned as fresh evidence.
    public func historyContext(before turn: MeetingChatTurn, byteLimit: Int = 4_000) throws -> (turns: [MeetingChatTurn], dependencies: [MeetingChatDependency]) {
        try connection { db in
            let candidates = try MeetingChatSQL.rows("SELECT body FROM meeting_chat_turns WHERE session_id=? AND ordinal<? AND state='completed' ORDER BY ordinal DESC LIMIT 50",
                [.text(turn.sessionID.uuidString), .integer(Int64(turn.ordinal))], db: db) {
                try MeetingChatSQL.decode(MeetingChatTurn.self, MeetingChatSQL.text($0, 0))
            }
            var selected: [MeetingChatTurn] = []; var dependencies = Set<MeetingChatDependency>()
            var revisions: [Int64: String] = [:]; var missing = Set<Int64>(); var bytes = 0
            for var previous in candidates {
                try Task.checkCancellation()
                let inherited = try MeetingChatSQL.rows("SELECT meeting_id,revision FROM meeting_chat_dependencies WHERE turn_id=?", [.text(previous.id.uuidString)], db: db) {
                    MeetingChatDependency(meetingID: sqlite3_column_int64($0, 0), revision: MeetingChatSQL.text($0, 1))
                }
                var current = true
                for dependency in inherited {
                    if revisions[dependency.meetingID] == nil, !missing.contains(dependency.meetingID) {
                        if let source = try MeetingChatSQL.snapshots(scope: .init(selection: .meetings([dependency.meetingID])), db: db).first {
                            revisions[dependency.meetingID] = source.revision
                        } else { missing.insert(dependency.meetingID) }
                    }
                    if revisions[dependency.meetingID] != dependency.revision { current = false; break }
                }
                guard current, previous.originalAnswer != nil else { continue }
                let block = MeetingChatHistory.promptBlock(previous)
                guard bytes + block.utf8.count <= byteLimit else { continue }
                bytes += block.utf8.count
                previous.citations = []; previous.editableDraft = nil
                selected.insert(previous, at: 0); dependencies.formUnion(inherited)
            }
            return (selected, Array(dependencies))
        }
    }
    public func updateSession(id: UUID, title: String?, scope: MeetingChatScope?) throws {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            var session = try session(id, db: db)
            if let title { session.title = title; session.titleIsAutomatic = false }
            if let scope, scope != session.scope {
                session.scope = scope
                session.contextStartOrdinal = try nextOrdinal(sessionID: id, db: db)
                try saveSelectedMeetings(session, db: db)
            }
            session.updatedAt = Date()
            try saveSession(session, db: db)
        } }
    }
    public func beginTurn(sessionID: UUID, question: String, scope: MeetingChatScope, provider: String, model: String, attemptID: UUID = UUID()) throws -> MeetingChatTurn {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            var session = try session(sessionID, db: db)
            let turn = MeetingChatTurn(id: UUID(), sessionID: sessionID, ordinal: try nextOrdinal(sessionID: sessionID, db: db), question: question,
                scope: scope, state: .finding, citations: [], provider: provider, model: model,
                attemptID: attemptID, scopeLabel: try scopeLabel(scope, db: db))
            try MeetingChatSQL.execute("INSERT INTO meeting_chat_turns VALUES(?,?,?,?,?)", [.text(turn.id.uuidString), .text(sessionID.uuidString), .integer(Int64(turn.ordinal)), .text(turn.state.rawValue), .text(try MeetingChatSQL.encode(turn))], db: db)
            if turn.ordinal == 0, session.titleIsAutomatic == true {
                session.title = String(question.prefix(64))
            }
            session.updatedAt = Date(); try saveSession(session, db: db)
            return turn
        } }
    }
    public func attachEvidence(turnID: UUID, dependencies: [MeetingChatDependency], attemptID: UUID? = nil) throws {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            guard var turn = try turn(turnID, db: db), turn.state.isPending,
                  attemptID == nil || turn.attemptID == attemptID else { throw MeetingChatError.missingSession }
            let attached = try MeetingChatSQL.rows("SELECT meeting_id,revision FROM meeting_chat_dependencies WHERE turn_id=?", [.text(turnID.uuidString)], db: db) {
                MeetingChatDependency(meetingID: sqlite3_column_int64($0, 0), revision: MeetingChatSQL.text($0, 1))
            }
            guard try sourcesMatch(attached + dependencies, db: db) else { throw MeetingChatError.sourceChanged }
            for dependency in dependencies {
                try MeetingChatSQL.execute("INSERT OR REPLACE INTO meeting_chat_dependencies VALUES(?,?,?)", [.text(turnID.uuidString), .integer(dependency.meetingID), .text(dependency.revision)], db: db)
            }
            turn.state = .writing
            try saveTurn(turn, db: db)
        } }
    }
    public func dependencies(turnID: UUID) throws -> [MeetingChatDependency] {
        try connection { db in try MeetingChatSQL.rows("SELECT meeting_id,revision FROM meeting_chat_dependencies WHERE turn_id=?", [.text(turnID.uuidString)], db: db) {
            MeetingChatDependency(meetingID: sqlite3_column_int64($0, 0), revision: MeetingChatSQL.text($0, 1))
        } }
    }
    public func dependenciesAreCurrent(_ dependencies: [MeetingChatDependency]) throws -> Bool {
        try connection { db in try sourcesMatch(dependencies, db: db) }
    }
    public func finishTurn(turnID: UUID, answer: String, citations: [MeetingChatCitation], dependencies: [MeetingChatDependency], coverage: MeetingChatCoverage? = nil, isDraft: Bool = false, attemptID: UUID? = nil) throws -> Bool {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            guard var turn = try turn(turnID, db: db), turn.state.isPending,
                  attemptID == nil || turn.attemptID == attemptID,
                  try sourcesMatch(dependencies, db: db) else { return false }
            let storedDependencies = try MeetingChatSQL.rows("SELECT meeting_id,revision FROM meeting_chat_dependencies WHERE turn_id=?", [.text(turnID.uuidString)], db: db) {
                MeetingChatDependency(meetingID: sqlite3_column_int64($0, 0), revision: MeetingChatSQL.text($0, 1))
            }
            let allDependencies = Array(Set(storedDependencies + dependencies + citations.map {
                MeetingChatDependency(meetingID: $0.meetingID, revision: $0.revision)
            }))
            guard try sourcesMatch(allDependencies, db: db) else { return false }
            // Persist every consulted source, including dependencies supplied only at completion.
            // Otherwise deleting that meeting could leave its derived answer behind.
            for dependency in allDependencies {
                try MeetingChatSQL.execute("INSERT OR REPLACE INTO meeting_chat_dependencies VALUES(?,?,?)", [.text(turnID.uuidString), .integer(dependency.meetingID), .text(dependency.revision)], db: db)
            }
            turn.state = .completed; turn.originalAnswer = answer; turn.citations = citations; turn.error = nil
            turn.coverage = coverage; turn.isDraft = isDraft
            try saveTurn(turn, db: db)
            return true
        } }
    }
    public func setTurnState(id: UUID, state: MeetingChatTurnState, error: String? = nil, attemptID: UUID? = nil) throws {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            guard var turn = try turn(id, db: db), turn.state != .sourceDeleted else { return }
            guard attemptID == nil || turn.attemptID == attemptID else { return }
            guard state != .writing || turn.state.isPending else { return }
            turn.state = state; turn.error = error
            if state != .completed { turn.originalAnswer = nil; turn.editableDraft = nil; turn.citations = [] }
            try saveTurn(turn, db: db)
        } }
    }
    public func saveDraft(turnID: UUID, text: String) throws {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            guard var turn = try turn(turnID, db: db), turn.state == .completed else { return }
            turn.editableDraft = text; try saveTurn(turn, db: db)
        } }
    }
    public func restartTurn(id: UUID, provider: String, model: String) throws -> MeetingChatTurn? {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            guard var turn = try turn(id, db: db), turn.state != .sourceDeleted else { return nil }
            turn.state = .finding; turn.originalAnswer = nil; turn.editableDraft = nil; turn.citations = []
            turn.error = nil; turn.provider = provider; turn.model = model; turn.coverage = nil
            turn.attemptID = UUID()
            try MeetingChatSQL.execute("DELETE FROM meeting_chat_dependencies WHERE turn_id=?", [.text(id.uuidString)], db: db)
            try saveTurn(turn, db: db); return turn
        } }
    }
    /// Commit a generated title only while this completed attempt remains the newest turn.
    /// Manual and legacy titles are protected, and deleted/changed source content cannot
    /// return through a late title-generation response.
    @discardableResult
    public func updateTitleIfAutomatic(turnID: UUID, attemptID: UUID, title: String) throws -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 100, !title.contains(where: \.isNewline) else { return false }
        return try connection { db in try MeetingChatSQL.transaction(db: db) {
            guard let turn = try turn(turnID, db: db), turn.state == .completed,
                  turn.attemptID == attemptID,
                  turn.ordinal == (try nextOrdinal(sessionID: turn.sessionID, db: db)) - 1 else { return false }
            var session = try session(turn.sessionID, db: db)
            guard session.titleIsAutomatic == true, session.generatedTitleTurnID == nil,
                  session.scope == turn.scope, turn.ordinal >= session.contextStartOrdinal else { return false }
            let dependencies = try MeetingChatSQL.rows("SELECT meeting_id,revision FROM meeting_chat_dependencies WHERE turn_id=?", [.text(turnID.uuidString)], db: db) {
                MeetingChatDependency(meetingID: sqlite3_column_int64($0, 0), revision: MeetingChatSQL.text($0, 1))
            }
            guard try sourcesMatch(dependencies, db: db) else { return false }
            session.title = title
            session.generatedTitleTurnID = turnID
            try saveSession(session, db: db)
            return true
        } }
    }
    public func deleteSession(id: UUID) throws {
        try connection { db in try MeetingChatSQL.execute("DELETE FROM meeting_chat_sessions WHERE id=?", [.text(id.uuidString)], db: db) }
    }
    public func interruptPendingTurns() throws {
        try connection { db in try MeetingChatSQL.execute("UPDATE meeting_chat_turns SET state='interrupted',body=json_set(body,'$.state','interrupted') WHERE state IN ('finding','writing')", db: db) }
    }
    public func sourceMutationVersion() throws -> Int64 {
        try connection { db in try MeetingChatSQL.rows("SELECT version FROM meeting_chat_source_version WHERE id=1", db: db) { sqlite3_column_int64($0, 0) }.first ?? 0 }
    }
    private func scopeLabel(_ scope: MeetingChatScope, db: OpaquePointer?) throws -> String {
        var label: String
        switch scope.selection {
        case .all: label = "All saved meetings"
        case .folder(let id):
            let name = try MeetingChatSQL.rows("SELECT name FROM meeting_folders WHERE id=?", [.integer(id)], db: db) { MeetingChatSQL.text($0, 0) }.first ?? "Folder"
            label = name + " · This folder only"
        case .meetings(let ids): label = "\(ids.count) selected meetings"
        }
        if let start = scope.startDate { label += " · From " + start.formatted(date: .abbreviated, time: .omitted) }
        if let end = scope.endDateExclusive { label += " through " + end.addingTimeInterval(-0.001).formatted(date: .abbreviated, time: .omitted) }
        return label
    }
    public func sourceSnapshots(scope: MeetingChatScope) throws -> [MeetingChatSourceSnapshot] {
        try connection { db in
            var snapshots: [MeetingChatSourceSnapshot] = []; var afterID: Int64 = 0
            while true {
                let page = try MeetingChatSQL.snapshots(scope: scope, db: db, afterID: afterID)
                guard let last = page.last else { break }
                afterID = last.meetingID
                snapshots += page.filter {
                    (scope.startDate == nil || $0.startDate >= scope.startDate!) &&
                    (scope.endDateExclusive == nil || $0.startDate < scope.endDateExclusive!) &&
                    !($0.transcript + $0.manualNotes + $0.generatedNotes).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            return snapshots
        }
    }
    /// Picker metadata is available immediately, even while the derived FTS index is cold.
    /// Filter source availability in SQLite without loading or hashing transcript payloads.
    public func sourceChoices() throws -> [MeetingChatSourceChoice] {
        let whitespace = " \t\n\r\u{000B}\u{000C}\u{0085}\u{00A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}"
        return try connection { db in
            try MeetingChatSQL.rows("""
                SELECT id,title,start_time,folder_id FROM meetings
                WHERE deleted_at IS NULL AND meeting_status NOT IN ('recording','processing') AND (
                  length(trim(COALESCE(raw_transcript,''),?))>0 OR
                  length(trim(COALESCE(manual_notes,''),?))>0 OR
                  (length(trim(COALESCE(formatted_notes,''),?))>0
                   AND formatted_notes NOT GLOB '## Summary failed*' AND formatted_notes NOT GLOB '## Raw Transcript*'))
                """, [.text(whitespace), .text(whitespace), .text(whitespace)], db: db) {
                MeetingChatSourceChoice(id: sqlite3_column_int64($0, 0), title: MeetingChatSQL.text($0, 1),
                    startDate: MeetingChatSQL.parseDate(MeetingChatSQL.text($0, 2)) ?? .distantPast,
                    folderID: sqlite3_column_type($0, 3) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 3))
            }.sorted { $0.startDate == $1.startDate ? $0.id > $1.id : $0.startDate > $1.startDate }
        }
    }
    private func sourcesMatch(_ dependencies: [MeetingChatDependency], db: OpaquePointer?) throws -> Bool {
        for dependency in dependencies {
            let source = try MeetingChatSQL.snapshots(scope: .init(selection: .meetings([dependency.meetingID])), db: db).first
            guard source?.revision == dependency.revision else { return false }
        }
        return true
    }
    private func session(_ id: UUID, db: OpaquePointer?) throws -> MeetingChatSession {
        guard let result = try MeetingChatSQL.rows("SELECT body,(SELECT meeting_id FROM meeting_chat_session_meetings WHERE session_id=meeting_chat_sessions.id AND role='anchor') FROM meeting_chat_sessions WHERE id=?", [.text(id.uuidString)], db: db, map: {
            var session = try MeetingChatSQL.decode(MeetingChatSession.self, MeetingChatSQL.text($0, 0))
            session.anchorMeetingID = sqlite3_column_type($0, 1) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 1)
            return session
        }).first else { throw MeetingChatError.missingSession }
        return result
    }
    private func turn(_ id: UUID, db: OpaquePointer?) throws -> MeetingChatTurn? {
        try MeetingChatSQL.rows("SELECT body FROM meeting_chat_turns WHERE id=?", [.text(id.uuidString)], db: db) {
            try MeetingChatSQL.decode(MeetingChatTurn.self, MeetingChatSQL.text($0, 0))
        }.first
    }
    private func nextOrdinal(sessionID: UUID, db: OpaquePointer?) throws -> Int {
        try MeetingChatSQL.rows("SELECT COALESCE(MAX(ordinal)+1,0) FROM meeting_chat_turns WHERE session_id=?", [.text(sessionID.uuidString)], db: db) {
            Int(sqlite3_column_int64($0, 0))
        }.first ?? 0
    }
    private func saveSelectedMeetings(_ session: MeetingChatSession, db: OpaquePointer?) throws {
        try MeetingChatSQL.execute("DELETE FROM meeting_chat_session_meetings WHERE session_id=? AND role='selected'", [.text(session.id.uuidString)], db: db)
        if case .meetings(let ids) = session.scope.selection {
            for id in Set(ids) { try MeetingChatSQL.linkSession(session.id, meetingID: id, role: "selected", db: db) }
        }
    }
    private func saveSession(_ session: MeetingChatSession, db: OpaquePointer?) throws {
        try MeetingChatSQL.execute("UPDATE meeting_chat_sessions SET body=?,updated_at=? WHERE id=?", [.text(try MeetingChatSQL.encode(session)), .real(session.updatedAt.timeIntervalSince1970), .text(session.id.uuidString)], db: db)
    }
    private func saveTurn(_ turn: MeetingChatTurn, db: OpaquePointer?) throws {
        try MeetingChatSQL.execute("UPDATE meeting_chat_turns SET state=?,body=? WHERE id=?", [.text(turn.state.rawValue), .text(try MeetingChatSQL.encode(turn)), .text(turn.id.uuidString)], db: db)
    }
}
