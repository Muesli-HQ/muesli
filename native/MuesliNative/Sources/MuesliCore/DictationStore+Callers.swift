import Foundation
import SQLite3

public enum CallerAttachResult: Equatable, Sendable {
    case attached(UUID)
    case alreadyPresent
    case suppressed
    case meetingMissing
}

public struct CallerPerson: Equatable, Sendable {
    public let id: UUID
    public let displayName: String?
    public let handles: [CallerHandle]

    public init(id: UUID, displayName: String?, handles: [CallerHandle]) {
        self.id = id
        self.displayName = displayName
        self.handles = handles
    }
}

public struct CallerHistoryEntry: Equatable, Sendable {
    public let meetingID: Int64
    public let title: String
    public let startedAt: String

    public init(meetingID: Int64, title: String, startedAt: String) {
        self.meetingID = meetingID
        self.title = title
        self.startedAt = startedAt
    }
}

private enum CallerSQLValue {
    case text(String?)
    case integer(Int64)
}

/// Callers identified during recordings. A caller links to a meeting through
/// its automatic participant row or an explicit association with an existing
/// participant, keeping calendar attendees distinct from call history.
extension DictationStore {
    public static let callerParticipantPrefix = "call-person:"

    public static func callerPersonID(fromParticipantIdentifier identifier: String) -> UUID? {
        guard identifier.hasPrefix(callerParticipantPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(callerParticipantPrefix.count)))
    }

    static func callerParticipantIdentifier(_ personID: UUID) -> String {
        callerParticipantPrefix + personID.uuidString
    }

    func migrateCallerTables(db: OpaquePointer?) throws {
        try callerExec(
            """
            CREATE TABLE IF NOT EXISTS caller_people (
                id TEXT PRIMARY KEY,
                display_name TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS caller_person_handles (
                handle_key TEXT PRIMARY KEY,
                person_id TEXT NOT NULL REFERENCES caller_people(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                display_value TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_caller_person_handles_person
                ON caller_person_handles(person_id);
            CREATE INDEX IF NOT EXISTS idx_meeting_participants_identifier
                ON meeting_participants(participant_identifier);
            CREATE TABLE IF NOT EXISTS caller_person_meeting_participants (
                person_id TEXT NOT NULL REFERENCES caller_people(id) ON DELETE CASCADE,
                meeting_id INTEGER NOT NULL,
                participant_identifier TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (person_id, meeting_id, participant_identifier),
                FOREIGN KEY (meeting_id, participant_identifier)
                    REFERENCES meeting_participants(meeting_id, participant_identifier) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_caller_person_meeting_participants_meeting
                ON caller_person_meeting_participants(meeting_id, participant_identifier);
            CREATE TABLE IF NOT EXISTS caller_person_meeting_history (
                person_id TEXT NOT NULL REFERENCES caller_people(id) ON DELETE CASCADE,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                participant_identifier TEXT NOT NULL,
                is_suppressed INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL,
                PRIMARY KEY (person_id, meeting_id, participant_identifier)
            );
            INSERT OR IGNORE INTO caller_person_meeting_history
                (person_id, meeting_id, participant_identifier, is_suppressed, created_at)
            SELECT l.person_id, l.meeting_id, l.participant_identifier, p.is_suppressed, l.created_at
            FROM caller_person_meeting_participants l
            JOIN meeting_participants p
              ON p.meeting_id = l.meeting_id
             AND p.participant_identifier = l.participant_identifier;
            """,
            db: db
        )
    }

    /// Removes people that no meeting participant row references any more.
    func deleteOrphanCallerPeople(db: OpaquePointer?) throws {
        try callerExec(
            """
            DELETE FROM caller_people
            WHERE NOT EXISTS (
                SELECT 1 FROM meeting_participants
                WHERE participant_identifier = 'call-person:' || caller_people.id
            ) AND NOT EXISTS (
                SELECT 1 FROM caller_person_meeting_participants
                WHERE person_id = caller_people.id
            ) AND NOT EXISTS (
                SELECT 1 FROM caller_person_meeting_history
                WHERE person_id = caller_people.id AND is_suppressed = 0
            )
            """,
            db: db
        )
    }

    public func attachCaller(_ handle: CallerHandle, toMeetingID meetingID: Int64) throws -> CallerAttachResult {
        let db = try openCallerConnection()
        defer { sqlite3_close(db) }
        try callerExec("BEGIN IMMEDIATE TRANSACTION", db: db)
        do {
            let result = try attachCaller(handle, toMeetingID: meetingID, db: db)
            try callerExec("COMMIT", db: db)
            return result
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func callerPerson(id: UUID) throws -> CallerPerson? {
        let db = try openCallerConnection()
        defer { sqlite3_close(db) }
        var found = false
        var displayName: String?
        try callerQuery("SELECT display_name FROM caller_people WHERE id = ?", [.text(id.uuidString)], db: db) { statement in
            found = true
            displayName = callerOptionalText(statement, 0)
        }
        guard found else { return nil }
        return CallerPerson(id: id, displayName: displayName, handles: try callerHandles(personID: id, db: db))
    }

    /// Sets or clears (`nil`/blank) a person's name and returns the meetings
    /// whose visible participant row changed, newest first.
    public func renameCallerPerson(id: UUID, displayName: String?) throws -> [Int64] {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedName = (name?.isEmpty ?? true) ? nil : name
        let db = try openCallerConnection()
        defer { sqlite3_close(db) }
        try callerExec("BEGIN IMMEDIATE TRANSACTION", db: db)
        do {
            try callerQuery(
                "UPDATE caller_people SET display_name = ?, updated_at = ? WHERE id = ?",
                [.text(storedName), .text(Self.callerTimestamp()), .text(id.uuidString)],
                db: db
            )
            guard sqlite3_changes(db) > 0 else {
                try callerExec("COMMIT", db: db)
                return []
            }
            let identifier = Self.callerParticipantIdentifier(id)
            let meetings = try callerHistory(personID: id, db: db).map(\.meetingID)
            let rowName = try callerDisplayName(personID: id, db: db)
            try callerQuery(
                """
                UPDATE meeting_participants SET display_name = ?
                WHERE participant_identifier = ? AND source = 'automaticCall' AND is_suppressed = 0
                """,
                [.text(rowName), .text(identifier)],
                db: db
            )
            try callerExec("COMMIT", db: db)
            return meetings
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Removes a caller that should never have been linked, such as one read
    /// during a resumed recording whose audio was discarded. Unlike removal
    /// by the user, this leaves no suppression behind.
    public func detachCaller(personID: UUID, fromMeetingID meetingID: Int64) throws {
        let db = try openCallerConnection()
        defer { sqlite3_close(db) }
        try callerExec("BEGIN IMMEDIATE TRANSACTION", db: db)
        do {
            try callerQuery(
                """
                DELETE FROM meeting_participants
                WHERE meeting_id = ? AND participant_identifier = ? AND source = 'automaticCall'
                """,
                [.integer(meetingID), .text(Self.callerParticipantIdentifier(personID))],
                db: db
            )
            try callerQuery(
                "DELETE FROM caller_person_meeting_participants WHERE person_id = ? AND meeting_id = ?",
                [.text(personID.uuidString), .integer(meetingID)],
                db: db
            )
            try callerQuery(
                "DELETE FROM caller_person_meeting_history WHERE person_id = ? AND meeting_id = ?",
                [.text(personID.uuidString), .integer(meetingID)],
                db: db
            )
            try deleteOrphanCallerPeople(db: db)
            try callerExec("COMMIT", db: db)
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    public func callerHistory(personID: UUID) throws -> [CallerHistoryEntry] {
        let db = try openCallerConnection()
        defer { sqlite3_close(db) }
        return try callerHistory(personID: personID, db: db)
    }

    public func callerHistory(personID: UUID, limit: Int, offset: Int) throws -> [CallerHistoryEntry] {
        let db = try openCallerConnection()
        defer { sqlite3_close(db) }
        return try callerHistory(
            personID: personID,
            db: db,
            limit: max(0, limit),
            offset: max(0, offset)
        )
    }

    private func attachCaller(
        _ handle: CallerHandle,
        toMeetingID meetingID: Int64,
        db: OpaquePointer?
    ) throws -> CallerAttachResult {
        var meetingExists = false
        try callerQuery(
            "SELECT 1 FROM meetings WHERE id = ? AND deleted_at IS NULL",
            [.integer(meetingID)],
            db: db
        ) { _ in meetingExists = true }
        guard meetingExists else { return .meetingMissing }

        var matchingEmailParticipant: (identifier: String, isSuppressed: Bool)?
        if handle.kind == .email {
            try callerQuery(
                """
                SELECT participant_identifier, is_suppressed FROM meeting_participants
                WHERE meeting_id = ? AND email_address IS NOT NULL AND lower(email_address) = lower(?)
                ORDER BY is_suppressed, insertion_order, participant_identifier LIMIT 1
                """,
                [.integer(meetingID), .text(handle.displayValue)],
                db: db
            ) { statement in
                matchingEmailParticipant = (
                    callerText(statement, 0) ?? "",
                    sqlite3_column_int(statement, 1) != 0
                )
            }
            if let matchingEmailParticipant,
               matchingEmailParticipant.isSuppressed,
               !matchingEmailParticipant.identifier.hasPrefix("call-person:") {
                return .alreadyPresent
            }
        }

        let personID = try resolveCallerPerson(handle, db: db)
        let identifier = Self.callerParticipantIdentifier(personID)
        var suppressed: Bool?
        try callerQuery(
            "SELECT is_suppressed FROM meeting_participants WHERE meeting_id = ? AND participant_identifier = ?",
            [.integer(meetingID), .text(identifier)],
            db: db
        ) { statement in suppressed = sqlite3_column_int(statement, 0) != 0 }
        if let suppressed { return suppressed ? .suppressed : .alreadyPresent }

        if let matchingEmailParticipant, !matchingEmailParticipant.isSuppressed {
            var associationExists = false
            try callerQuery(
                """
                SELECT 1 FROM caller_person_meeting_participants
                WHERE person_id = ? AND meeting_id = ? AND participant_identifier = ?
                """,
                [.text(personID.uuidString), .integer(meetingID), .text(matchingEmailParticipant.identifier)],
                db: db
            ) { _ in associationExists = true }
            if associationExists { return .alreadyPresent }
            try callerQuery(
                """
                INSERT INTO caller_person_meeting_participants
                    (person_id, meeting_id, participant_identifier, created_at)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .text(personID.uuidString),
                    .integer(meetingID),
                    .text(matchingEmailParticipant.identifier),
                    .text(Self.callerTimestamp()),
                ],
                db: db
            )
            try callerQuery(
                """
                INSERT OR IGNORE INTO caller_person_meeting_history
                    (person_id, meeting_id, participant_identifier, created_at)
                VALUES (?, ?, ?, ?)
                """,
                [
                    .text(personID.uuidString),
                    .integer(meetingID),
                    .text(matchingEmailParticipant.identifier),
                    .text(Self.callerTimestamp()),
                ],
                db: db
            )
            return .attached(personID)
        }

        let rowName = try callerDisplayName(personID: personID, db: db)
        try callerQuery(
            """
            INSERT INTO meeting_participants
                (meeting_id, participant_identifier, display_name, email_address, insertion_order, source)
            VALUES (?, ?, ?, ?,
                COALESCE((SELECT MAX(insertion_order) + 1 FROM meeting_participants WHERE meeting_id = ?), 0),
                'automaticCall')
            """,
            [
                .integer(meetingID),
                .text(identifier),
                .text(rowName),
                .text(handle.kind == .email ? handle.displayValue : nil),
                .integer(meetingID),
            ],
            db: db
        )
        return .attached(personID)
    }

    private func resolveCallerPerson(_ handle: CallerHandle, db: OpaquePointer?) throws -> UUID {
        var existing: UUID?
        try callerQuery(
            "SELECT person_id FROM caller_person_handles WHERE handle_key = ?",
            [.text(handle.key)],
            db: db
        ) { statement in existing = UUID(uuidString: callerText(statement, 0)) }
        if let existing { return existing }

        let personID = CallerHandleNormalizer.personID(forKey: handle.key)
        let now = Self.callerTimestamp()
        try callerQuery(
            "INSERT OR IGNORE INTO caller_people (id, display_name, created_at, updated_at) VALUES (?, NULL, ?, ?)",
            [.text(personID.uuidString), .text(now), .text(now)],
            db: db
        )
        try callerQuery(
            """
            INSERT INTO caller_person_handles (handle_key, person_id, kind, display_value, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            [.text(handle.key), .text(personID.uuidString), .text(handle.kind.rawValue), .text(handle.displayValue), .text(now)],
            db: db
        )
        return personID
    }

    private func callerHandles(personID: UUID, db: OpaquePointer?) throws -> [CallerHandle] {
        var handles: [CallerHandle] = []
        try callerQuery(
            """
            SELECT kind, handle_key, display_value FROM caller_person_handles
            WHERE person_id = ? ORDER BY created_at, rowid
            """,
            [.text(personID.uuidString)],
            db: db
        ) { statement in
            guard let kind = CallerHandleKind(rawValue: callerText(statement, 0)) else { return }
            handles.append(CallerHandle(
                kind: kind,
                key: callerText(statement, 1),
                displayValue: callerText(statement, 2)
            ))
        }
        return handles
    }

    /// The person's edited name, else the first handle as it was shown.
    private func callerDisplayName(personID: UUID, db: OpaquePointer?) throws -> String {
        var name: String?
        try callerQuery("SELECT display_name FROM caller_people WHERE id = ?", [.text(personID.uuidString)], db: db) { statement in
            name = callerOptionalText(statement, 0)
        }
        if let name { return name }
        return try callerHandles(personID: personID, db: db).first?.displayValue ?? "Unknown caller"
    }

    private func callerHistory(personID: UUID, db: OpaquePointer?) throws -> [CallerHistoryEntry] {
        try callerHistory(personID: personID, db: db, limit: nil, offset: 0)
    }

    private func callerHistory(
        personID: UUID,
        db: OpaquePointer?,
        limit: Int?,
        offset: Int
    ) throws -> [CallerHistoryEntry] {
        var entries: [CallerHistoryEntry] = []
        var sql = """
            SELECT m.id, m.title, m.start_time
            FROM meetings m
            WHERE m.deleted_at IS NULL
              AND (
                EXISTS (
                    SELECT 1 FROM meeting_participants p
                    WHERE p.meeting_id = m.id
                      AND p.participant_identifier = ?
                      AND p.is_suppressed = 0
                ) OR EXISTS (
                    SELECT 1
                    FROM caller_person_meeting_history l
                    WHERE l.meeting_id = m.id
                      AND l.person_id = ?
                      AND l.is_suppressed = 0
                )
            )
            ORDER BY m.start_time DESC, m.id DESC
            """
        var bindings: [CallerSQLValue] = [
            .text(Self.callerParticipantIdentifier(personID)),
            .text(personID.uuidString),
        ]
        if let limit {
            sql += " LIMIT ? OFFSET ?"
            bindings.append(.integer(Int64(limit)))
            bindings.append(.integer(Int64(offset)))
        }
        try callerQuery(
            sql,
            bindings,
            db: db
        ) { statement in
            entries.append(CallerHistoryEntry(
                meetingID: sqlite3_column_int64(statement, 0),
                title: callerText(statement, 1),
                startedAt: callerText(statement, 2)
            ))
        }
        return entries
    }

    /// Runs one statement with text bindings (`nil` binds NULL), calling
    /// `row` for each result row.
    private func callerQuery(
        _ sql: String,
        _ bindings: [CallerSQLValue],
        db: OpaquePointer?,
        row: (OpaquePointer?) throws -> Void = { _ in }
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw callerError(db)
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .integer(let number):
                sqlite3_bind_int64(statement, position, number)
            case .text(let text?):
                sqlite3_bind_text(statement, position, (text as NSString).utf8String, -1, nil)
            case .text(nil):
                sqlite3_bind_null(statement, position)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw callerError(db)
            }
        }
    }

    private func callerExec(_ sql: String, db: OpaquePointer?) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw callerError(db) }
    }

    private func callerError(_ db: OpaquePointer?) -> NSError {
        NSError(
            domain: "MuesliDB",
            code: Int(sqlite3_errcode(db)),
            userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))]
        )
    }

    private func callerText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func callerOptionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        let text = callerText(statement, index)
        return text.isEmpty ? nil : text
    }

    private static func callerTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
