import Foundation
import SQLite3

/// Opens the explicitly supplied app database per operation; no shared mutable connection.
public struct MeetingChatStore: Sendable {
    public let databaseURL: URL
    public init(databaseURL: URL) { self.databaseURL = databaseURL }
    private func connection<T>(_ operation: (OpaquePointer?) throws -> T) throws -> T {
        try DictationStore(databaseURL: databaseURL).withChatDatabase(operation)
    }
    public func createSession(scope: MeetingChatScope, title: String) throws -> MeetingChatSession {
        let now = Date()
        let session = MeetingChatSession(id: UUID(), title: title, scope: scope, createdAt: now, updatedAt: now, contextStartOrdinal: 0)
        try connection { db in
            try MeetingChatSQL.execute("INSERT INTO meeting_chat_sessions VALUES(?,?,?)", [.text(session.id.uuidString), .text(try MeetingChatSQL.encode(session)), .real(now.timeIntervalSince1970)], db: db)
        }
        return session
    }
    public func sessions() throws -> [MeetingChatSession] {
        try connection { db in try MeetingChatSQL.rows("SELECT body FROM meeting_chat_sessions ORDER BY updated_at DESC", db: db) {
            try MeetingChatSQL.decode(MeetingChatSession.self, MeetingChatSQL.text($0, 0))
        } }
    }
    public func turns(sessionID: UUID) throws -> [MeetingChatTurn] {
        try connection { db in try MeetingChatSQL.rows("SELECT body FROM meeting_chat_turns WHERE session_id=? ORDER BY ordinal", [.text(sessionID.uuidString)], db: db) {
            try MeetingChatSQL.decode(MeetingChatTurn.self, MeetingChatSQL.text($0, 0))
        } }
    }
    public func updateSession(id: UUID, title: String?, scope: MeetingChatScope?) throws {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            var session = try session(id, db: db)
            if let title { session.title = title }
            if let scope, scope != session.scope {
                session.scope = scope
                session.contextStartOrdinal = try nextOrdinal(sessionID: id, db: db)
            }
            session.updatedAt = Date()
            try saveSession(session, db: db)
        } }
    }
    public func beginTurn(sessionID: UUID, question: String, scope: MeetingChatScope, provider: String, model: String) throws -> MeetingChatTurn {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            var session = try session(sessionID, db: db)
            let turn = MeetingChatTurn(id: UUID(), sessionID: sessionID, ordinal: try nextOrdinal(sessionID: sessionID, db: db), question: question,
                scope: scope, state: .finding, citations: [], provider: provider, model: model,
                attemptID: UUID(), scopeLabel: try scopeLabel(scope, db: db))
            try MeetingChatSQL.execute("INSERT INTO meeting_chat_turns VALUES(?,?,?,?,?)", [.text(turn.id.uuidString), .text(sessionID.uuidString), .integer(Int64(turn.ordinal)), .text(turn.state.rawValue), .text(try MeetingChatSQL.encode(turn))], db: db)
            session.updatedAt = Date(); try saveSession(session, db: db)
            return turn
        } }
    }
    public func attachEvidence(turnID: UUID, dependencies: [MeetingChatDependency], attemptID: UUID? = nil) throws {
        try connection { db in try MeetingChatSQL.transaction(db: db) {
            guard var turn = try turn(turnID, db: db), turn.state.isPending,
                  attemptID == nil || turn.attemptID == attemptID else { throw MeetingChatError.missingSession }
            guard try sourcesMatch(dependencies, db: db) else { throw MeetingChatError.sourceChanged }
            try MeetingChatSQL.execute("DELETE FROM meeting_chat_dependencies WHERE turn_id=?", [.text(turnID.uuidString)], db: db)
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
            guard try sourcesMatch(storedDependencies, db: db) else { return false }
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
    public func sourceChoices() throws -> [MeetingChatSourceChoice] {
        try connection { db in try MeetingChatSQL.rows("SELECT s.meeting_id,m.title,s.start_time,s.folder_id FROM meeting_chat_index_state s JOIN meetings m ON m.id=s.meeting_id WHERE m.deleted_at IS NULL ORDER BY s.start_time DESC", db: db) {
            MeetingChatSourceChoice(id: sqlite3_column_int64($0, 0), title: MeetingChatSQL.text($0, 1), startDate: Date(timeIntervalSince1970: sqlite3_column_double($0, 2)), folderID: sqlite3_column_type($0, 3) == SQLITE_NULL ? nil : sqlite3_column_int64($0, 3))
        } }
    }
    private func sourcesMatch(_ dependencies: [MeetingChatDependency], db: OpaquePointer?) throws -> Bool {
        for dependency in dependencies {
            let source = try MeetingChatSQL.snapshots(scope: .init(selection: .meetings([dependency.meetingID])), db: db).first
            guard source?.revision == dependency.revision else { return false }
        }
        return true
    }
    private func session(_ id: UUID, db: OpaquePointer?) throws -> MeetingChatSession {
        guard let result = try MeetingChatSQL.rows("SELECT body FROM meeting_chat_sessions WHERE id=?", [.text(id.uuidString)], db: db, map: {
            try MeetingChatSQL.decode(MeetingChatSession.self, MeetingChatSQL.text($0, 0))
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
    private func saveSession(_ session: MeetingChatSession, db: OpaquePointer?) throws {
        try MeetingChatSQL.execute("UPDATE meeting_chat_sessions SET body=?,updated_at=? WHERE id=?", [.text(try MeetingChatSQL.encode(session)), .real(session.updatedAt.timeIntervalSince1970), .text(session.id.uuidString)], db: db)
    }
    private func saveTurn(_ turn: MeetingChatTurn, db: OpaquePointer?) throws {
        try MeetingChatSQL.execute("UPDATE meeting_chat_turns SET state=?,body=? WHERE id=?", [.text(turn.state.rawValue), .text(try MeetingChatSQL.encode(turn)), .text(turn.id.uuidString)], db: db)
    }
}
