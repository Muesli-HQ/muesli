import Foundation
import SQLite3
import MuesliCore

struct SavedTimeTurnerRecap: Codable, Sendable {
    let version: Int
    let dayStart: Date
    let dayEnd: Date
    let timeZone: String
    let generatedAt: Date
    let provider: String
    let model: String
    var insights: [TimeTurnerRecapInsight]
    let sources: [TimeTurnerRecapSource]
    var includedInputs: [TimeTurnerRecapInput]? = nil
    var inputFingerprint: String? = nil
    var storageKey: String? = nil

    var dayKey: String { Self.key(dayStart: dayStart, timeZone: timeZone) }

    var key: String { storageKey ?? dayKey }
    static func key(dayStart: Date, timeZone: String) -> String {
        "\(timeZone)|\(dayStart.timeIntervalSince1970)"
    }
}

/// Navigation carries the persisted identity and day bounds, never a date rebuilt
/// in the device's current timezone. No source content is cached in this target.
struct TimeTurnerRecapSelection: Equatable, Sendable {
    let key: String
    let interval: DateInterval
    let timeZone: String

    init(_ recap: SavedTimeTurnerRecap) {
        key = recap.key
        interval = DateInterval(start: recap.dayStart, end: recap.dayEnd)
        timeZone = recap.timeZone
    }

    // Date controls browse local calendar days; only presentation is converted.
    // The persisted key and original generation interval remain untouched.
    func browsingDay(in calendar: Calendar = .current) -> Date {
        var original = calendar
        original.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        let parts = original.dateComponents([.era, .year, .month, .day], from: interval.start)
        return calendar.date(from: parts) ?? interval.start
    }

    var dayLabel: String {
        var style = Date.FormatStyle().day().month(.abbreviated).year()
        style.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(secondsFromGMT: 0)!
        return interval.start.formatted(style)
    }
}

/// Local-only, lazily migrated store in muesli.db. Call off the main actor.
/// The versioned body owns its source snapshots; no CloudKit or export projection.
final class TimeTurnerRecapStore {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(databaseURL: URL, readOnly: Bool = false) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(databaseURL.path, &db, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db); db = nil }
            throw Self.failure
        }
        sqlite3_busy_timeout(db, 5_000)
        if readOnly { return }
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS time_turner_recaps (
                day_key TEXT PRIMARY KEY NOT NULL,
                day_start REAL NOT NULL,
                day_end REAL NOT NULL,
                time_zone TEXT NOT NULL,
                generated_at REAL NOT NULL,
                body TEXT NOT NULL
            )
            """)
        try execute("BEGIN IMMEDIATE")
        do {
            try installTodos()
            try installTodoReminders()
            try installStableTodoIDs()
            try installTodoDeletion()
            try installHistoryInvalidation()
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    deinit { sqlite3_close(db) }
    private static var failure: NSError {
        NSError(domain: "TimeTurnerRecapStore", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "The daily recap could not be loaded or saved on this Mac."])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw Self.failure }
    }
    private func statement(_ sql: String) throws -> OpaquePointer? {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK else { throw Self.failure }
        return result
    }
    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        _ = sqlite3_bind_text(statement, index, value, -1, transient)
    }
    /// Triggers invalidate dependent quotes in the source mutation transaction,
    /// including soft deletes and edits, without waiting for the Recap tab to open.
    private func installHistoryInvalidation() throws {
        let check = try statement("SELECT 1 FROM sqlite_master WHERE name='time_turner_recap_history_sources'")
        let projectionStatus = sqlite3_step(check)
        sqlite3_finalize(check)
        guard projectionStatus == SQLITE_ROW || projectionStatus == SQLITE_DONE else { throw Self.failure }
        let projectionExists = projectionStatus == SQLITE_ROW
        try execute("""
            CREATE TABLE IF NOT EXISTS time_turner_recap_history_sources (
                day_key TEXT NOT NULL, kind TEXT NOT NULL, source_id TEXT NOT NULL, parent_id TEXT NOT NULL,
                PRIMARY KEY(day_key,kind,source_id)
            );
            CREATE INDEX IF NOT EXISTS recap_history_source ON time_turner_recap_history_sources(kind,source_id,day_key);
            CREATE INDEX IF NOT EXISTS recap_history_parent ON time_turner_recap_history_sources(kind,parent_id,day_key);
            CREATE TRIGGER IF NOT EXISTS recap_history_projection_delete AFTER DELETE ON time_turner_recaps
            BEGIN DELETE FROM time_turner_recap_history_sources WHERE day_key=OLD.day_key; END;
            """)
        for event in ["INSERT", "UPDATE OF body"] {
            let name = event.hasPrefix("INSERT") ? "insert" : "update"
            try execute("""
                CREATE TRIGGER IF NOT EXISTS recap_history_projection_\(name) AFTER \(event) ON time_turner_recaps
                BEGIN
                    DELETE FROM time_turner_recap_history_sources WHERE day_key=NEW.day_key;
                    INSERT OR IGNORE INTO time_turner_recap_history_sources
                    SELECT NEW.day_key,json_extract(value,'$.history.kind'),json_extract(value,'$.history.id'),json_extract(value,'$.history.parentID')
                    FROM json_each(NEW.body,'$.sources') WHERE json_extract(value,'$.history.id') IS NOT NULL;
                END;
                """)
        }
        if !projectionExists {
            try execute("""
                INSERT OR IGNORE INTO time_turner_recap_history_sources
                SELECT r.day_key,json_extract(j.value,'$.history.kind'),json_extract(j.value,'$.history.id'),json_extract(j.value,'$.history.parentID')
                FROM time_turner_recaps r,json_each(r.body,'$.sources') j WHERE json_extract(j.value,'$.history.id') IS NOT NULL;
                """)
        }
        let rules: [(String, String, String, String, String?)] = [
            ("dictations", "dictations','commands", "source_id", "id", "raw_text,timestamp,source,target_app_name,target_app_bundle_id,deleted_at"),
            ("quill_conversations", "quill", "parent_id", "id", "deleted_at"),
            ("quill_conversation_turns", "quill", "source_id", "turn_id", "body"),
            ("cotypist_sessions", "cotypist", "parent_id", "id", "deleted_at"),
            ("cotypist_suggestions", "cotypist", "source_id", "id", "accepted_text,timestamp,session_id"),
            ("meeting_chat_sessions", "chat", "source_id", "id", "body,updated_at"),
            ("meeting_chat_turns", "chat", "parent_id", "session_id", nil)
        ]
        for (table, kinds, field, column, updates) in rules {
            let check = try statement("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?")
            bind(table, to: check, at: 1)
            let status = sqlite3_step(check); sqlite3_finalize(check)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw Self.failure }
            if status == SQLITE_DONE { continue }
            for event in ["DELETE", "UPDATE"] {
                let operation = event == "UPDATE" ? "UPDATE" + (updates.map { " OF " + $0 } ?? "") : event
                try execute("""
                    CREATE TRIGGER IF NOT EXISTS todo_history_\(table)_\(event) AFTER \(operation) ON \(table)
                    BEGIN
                        DELETE FROM time_turner_todo_links WHERE (day_key,task_key) IN
                        (SELECT day_key,task_key FROM time_turner_todo_refs WHERE kind IN ('\(kinds)') AND \(field)=CAST(OLD.\(column) AS TEXT));
                    END;
                    CREATE TRIGGER IF NOT EXISTS recap_history_\(table)_\(event)_v1 AFTER \(operation) ON \(table)
                    BEGIN
                        DELETE FROM time_turner_recaps WHERE day_key IN (
                            SELECT day_key FROM time_turner_recap_history_sources
                            WHERE kind IN ('\(kinds)') AND \(field)=CAST(OLD.\(column) AS TEXT)
                        );
                    END;
                    """)
            }
        }
    }

    /// Keep one work item across days, with separate links to the recaps supporting it.
    private func installTodos() throws {
        let check = try statement("SELECT 1 FROM sqlite_master WHERE name='time_turner_todo_links'")
        let installed = sqlite3_step(check)
        sqlite3_finalize(check)
        if installed == SQLITE_ROW { return }
        guard installed == SQLITE_DONE else { throw Self.failure }
        try execute("""
            CREATE TABLE time_turner_todos (task_key TEXT PRIMARY KEY, completed INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE time_turner_todo_links (day_key TEXT NOT NULL, task_key TEXT NOT NULL, title TEXT NOT NULL,
                PRIMARY KEY(day_key, task_key));
            CREATE INDEX time_turner_todo_by_task ON time_turner_todo_links(task_key);
            """)
        try execute("""
            CREATE TABLE time_turner_todo_refs (day_key TEXT NOT NULL, task_key TEXT NOT NULL,
                kind TEXT NOT NULL, source_id TEXT NOT NULL, parent_id TEXT NOT NULL, revision TEXT NOT NULL,
                PRIMARY KEY(day_key,task_key,kind,source_id));
            CREATE INDEX time_turner_todo_source ON time_turner_todo_refs(kind,source_id);
            CREATE INDEX time_turner_todo_parent ON time_turner_todo_refs(kind,parent_id);
            CREATE VIEW time_turner_followup_inputs AS
                SELECT r.day_key,lower(trim(coalesce(nullif(trim(json_extract(i.value,'$.action')),''),json_extract(i.value,'$.text')))) AS task_key,
                    trim(coalesce(nullif(trim(json_extract(i.value,'$.action')),''),json_extract(i.value,'$.text'))) AS title,
                    coalesce(json_extract(s.value,'$.history.kind'),CASE WHEN json_extract(s.value,'$.meeting') IS NOT NULL THEN 'meeting' ELSE 'capture' END) AS kind,
                    CAST(coalesce(json_extract(s.value,'$.capture.id'),json_extract(s.value,'$.meeting.meetingID'),json_extract(s.value,'$.history.id')) AS TEXT) AS source_id,
                    coalesce(json_extract(s.value,'$.history.parentID'),'') AS parent_id,
                    coalesce(json_extract(s.value,'$.history.revision'),json_extract(s.value,'$.meeting.revision'),'') AS revision
                FROM time_turner_recaps r,json_each(r.body,'$.insights') i,json_each(i.value,'$.sources') h,json_each(r.body,'$.sources') s
                WHERE json_extract(i.value,'$.section')='followUps' AND json_extract(s.value,'$.id')=h.value;
            CREATE TRIGGER time_turner_todo_unlink AFTER DELETE ON time_turner_todo_links BEGIN
                DELETE FROM time_turner_todo_refs WHERE day_key=OLD.day_key AND task_key=OLD.task_key;
                DELETE FROM time_turner_todos WHERE task_key=OLD.task_key AND NOT EXISTS
                    (SELECT 1 FROM time_turner_todo_links WHERE task_key=OLD.task_key);
            END;
            CREATE TRIGGER time_turner_todo_delete AFTER DELETE ON time_turner_recaps BEGIN
                DELETE FROM time_turner_todo_links WHERE day_key=OLD.day_key;
            END;
            """)
        func ingest(_ predicate: String) -> String {
            """
            INSERT OR IGNORE INTO time_turner_todo_links SELECT day_key,task_key,title FROM time_turner_followup_inputs \(predicate);
            INSERT OR IGNORE INTO time_turner_todos(task_key) SELECT task_key FROM time_turner_todo_links \(predicate);
            INSERT OR IGNORE INTO time_turner_todo_refs SELECT day_key,task_key,kind,source_id,parent_id,revision FROM time_turner_followup_inputs \(predicate);
            """
        }
        try execute(ingest(""))
        for (name, event) in [("insert", "INSERT"), ("update", "UPDATE OF body")] {
            try execute("""
                CREATE TRIGGER time_turner_todo_\(name) AFTER \(event) ON time_turner_recaps BEGIN
                    \(ingest("WHERE day_key=NEW.day_key"))
                END;
                """)
        }
    }

    private func installTodoReminders() throws {
        let columns = try statement("PRAGMA table_info(time_turner_todos)")
        var names = Set<String>()
        while sqlite3_step(columns) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(columns, 1))) }
        sqlite3_finalize(columns)
        if !names.contains("created_at") {
            try execute("""
                ALTER TABLE time_turner_todos ADD COLUMN created_at REAL NOT NULL DEFAULT 0;
                ALTER TABLE time_turner_todos ADD COLUMN reminder_interval REAL;
                ALTER TABLE time_turner_todos ADD COLUMN remind_at REAL;
                UPDATE time_turner_todos SET created_at=coalesce((SELECT min(r.generated_at)
                    FROM time_turner_todo_links l JOIN time_turner_recaps r USING(day_key)
                    WHERE l.task_key=time_turner_todos.task_key),unixepoch());
                CREATE INDEX time_turner_todo_due ON time_turner_todos(remind_at) WHERE completed=0;
                CREATE TRIGGER time_turner_todo_created AFTER INSERT ON time_turner_todos BEGIN
                    UPDATE time_turner_todos SET created_at=coalesce((SELECT min(r.generated_at)
                        FROM time_turner_todo_links l JOIN time_turner_recaps r USING(day_key)
                        WHERE l.task_key=NEW.task_key),unixepoch()) WHERE task_key=NEW.task_key;
                END;
                """)
        }
    }

    /// Legacy wording is only an import alias. All live identities are opaque IDs.
    private func installStableTodoIDs() throws {
        let check = try statement("SELECT 1 FROM sqlite_master WHERE name='time_turner_todo_aliases'")
        let installed = sqlite3_step(check); sqlite3_finalize(check)
        if installed == SQLITE_ROW { return }
        guard installed == SQLITE_DONE else { throw Self.failure }
        try execute("""
            CREATE TABLE time_turner_todo_aliases (legacy_key TEXT PRIMARY KEY, task_id TEXT NOT NULL);
            CREATE TABLE time_turner_todo_redirects (old_id TEXT PRIMARY KEY, task_id TEXT NOT NULL);
            CREATE TRIGGER time_turner_todo_alias_delete AFTER DELETE ON time_turner_todos BEGIN
                DELETE FROM time_turner_todo_aliases WHERE task_id=OLD.task_key;
                DELETE FROM time_turner_todo_redirects WHERE task_id=OLD.task_key;
            END;
            INSERT INTO time_turner_todo_aliases SELECT task_key,lower(hex(randomblob(16))) FROM time_turner_todos;
            UPDATE time_turner_todos SET task_key=(SELECT task_id FROM time_turner_todo_aliases WHERE legacy_key=task_key);
            UPDATE time_turner_todo_links SET task_key=(SELECT task_id FROM time_turner_todo_aliases WHERE legacy_key=task_key);
            UPDATE time_turner_todo_refs SET task_key=(SELECT task_id FROM time_turner_todo_aliases WHERE legacy_key=task_key);
            DROP VIEW time_turner_followup_inputs;
            CREATE VIEW time_turner_followup_inputs AS
                SELECT r.day_key,coalesce(d.task_id,json_extract(i.value,'$.taskID'),a.task_id) AS task_key,
                    trim(coalesce(nullif(trim(json_extract(i.value,'$.action')),''),json_extract(i.value,'$.text'))) AS title,
                    coalesce(json_extract(s.value,'$.history.kind'),CASE WHEN json_extract(s.value,'$.meeting') IS NOT NULL THEN 'meeting' ELSE 'capture' END) AS kind,
                    CAST(coalesce(json_extract(s.value,'$.capture.id'),json_extract(s.value,'$.meeting.meetingID'),json_extract(s.value,'$.history.id')) AS TEXT) AS source_id,
                    coalesce(json_extract(s.value,'$.history.parentID'),'') AS parent_id,
                    coalesce(json_extract(s.value,'$.history.revision'),json_extract(s.value,'$.meeting.revision'),'') AS revision
                FROM time_turner_recaps r,json_each(r.body,'$.insights') i,json_each(i.value,'$.sources') h,json_each(r.body,'$.sources') s
                LEFT JOIN time_turner_todo_aliases a ON a.legacy_key=lower(trim(coalesce(nullif(trim(json_extract(i.value,'$.action')),''),json_extract(i.value,'$.text'))))
                LEFT JOIN time_turner_todo_redirects d ON d.old_id=json_extract(i.value,'$.taskID')
                WHERE json_extract(i.value,'$.section')='followUps' AND json_extract(s.value,'$.id')=h.value;
            CREATE INDEX IF NOT EXISTS time_turner_recap_versions ON time_turner_recaps(day_start,day_end,time_zone,generated_at);
            """)
    }

    /// Keep a deletion marker while supporting recaps exist so replaying an
    /// archived recap cannot restore a task the user removed.
    private func installTodoDeletion() throws {
        let query = try statement("PRAGMA table_info(time_turner_todos)")
        defer { sqlite3_finalize(query) }
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            if String(cString: sqlite3_column_text(query, 1)) == "deleted_at" { return }
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw Self.failure }
        try execute("ALTER TABLE time_turner_todos ADD COLUMN deleted_at REAL")
    }

    func deleteTodo(_ id: String, now: Date = Date()) throws {
        try ContentPrivacy.shared.beginWrite()
        defer { ContentPrivacy.shared.endWrite() }
        let query = try statement("UPDATE time_turner_todos SET deleted_at=?, reminder_interval=NULL, remind_at=NULL WHERE task_key=? AND deleted_at IS NULL")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_double(query, 1, now.timeIntervalSince1970)
        bind(id, to: query, at: 2)
        guard sqlite3_step(query) == SQLITE_DONE else { throw Self.failure }
    }

    func versions(dayStart: Date, dayEnd: Date, timeZone: String) throws -> [SavedTimeTurnerRecap] {
        let query = try statement("SELECT body FROM time_turner_recaps WHERE day_start=? AND day_end=? AND time_zone=? ORDER BY generated_at DESC,day_key")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_double(query, 1, dayStart.timeIntervalSince1970)
        sqlite3_bind_double(query, 2, dayEnd.timeIntervalSince1970)
        bind(timeZone, to: query, at: 3)
        var result: [SavedTimeTurnerRecap] = []
        var step = sqlite3_step(query)
        while step == SQLITE_ROW {
            let body = String(cString: sqlite3_column_text(query, 0))
            result.append(try JSONDecoder().decode(SavedTimeTurnerRecap.self, from: Data(body.utf8)))
            step = sqlite3_step(query)
        }
        guard step == SQLITE_DONE else { throw Self.failure }
        return result
    }

    struct Todo: Identifiable, Sendable {
        let id: String
        let title: String
        let completed: Bool
        let recapKey: String
        let createdAt: Date
        let reminderInterval: TimeInterval?
        let remindAt: Date?
    }

    func todos(root: URL?, databaseURL: URL) throws -> [Todo] {
        let query = try statement("""
            SELECT t.task_key,l.title,t.completed,r.day_key,t.created_at,t.reminder_interval,t.remind_at FROM time_turner_todos t
            JOIN time_turner_todo_links l USING(task_key) JOIN time_turner_recaps r USING(day_key)
            WHERE t.deleted_at IS NULL
            ORDER BY t.completed,t.created_at DESC,t.task_key,r.day_start DESC,r.generated_at DESC
            """)
        var candidates: [Todo] = []
        var step = sqlite3_step(query)
        while step == SQLITE_ROW {
            candidates.append(Todo(id: String(cString: sqlite3_column_text(query, 0)), title: String(cString: sqlite3_column_text(query, 1)),
                completed: sqlite3_column_int(query, 2) != 0, recapKey: String(cString: sqlite3_column_text(query, 3)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 4)),
                reminderInterval: sqlite3_column_type(query, 5) == SQLITE_NULL ? nil : sqlite3_column_double(query, 5),
                remindAt: sqlite3_column_type(query, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(query, 6))))
            step = sqlite3_step(query)
        }
        sqlite3_finalize(query)
        guard step == SQLITE_DONE else { throw Self.failure }
        var seen = Set<String>()
        var validity: [String: Bool] = [:]
        return try candidates.filter { item in
            guard !seen.contains(item.id) else { return false }
            if validity[item.recapKey] == nil {
                if let recap = try load(key: item.recapKey) {
                    validity[item.recapKey] = try TimeTurnerRecap.sourcesAreCurrent(recap.sources, root: root, databaseURL: databaseURL)
                    if validity[item.recapKey] == false { try delete(key: recap.key, generatedAt: recap.generatedAt) }
                } else { validity[item.recapKey] = false }
            }
            guard validity[item.recapKey] == true else { return false }
            guard try supportingSourcesExist(item, root: root, databaseURL: databaseURL) else {
                let remove = try statement("DELETE FROM time_turner_todo_links WHERE day_key=? AND task_key=?")
                defer { sqlite3_finalize(remove) }
                bind(item.recapKey, to: remove, at: 1); bind(item.id, to: remove, at: 2)
                guard sqlite3_step(remove) == SQLITE_DONE else { throw Self.failure }
                return false
            }
            return seen.insert(item.id).inserted
        }
    }

    private func supportingSourcesExist(_ item: Todo, root: URL?, databaseURL: URL) throws -> Bool {
        let refs = try statement("SELECT kind,source_id,revision FROM time_turner_todo_refs WHERE day_key=? AND task_key=?")
        defer { sqlite3_finalize(refs) }
        bind(item.recapKey, to: refs, at: 1)
        bind(item.id, to: refs, at: 2)
        var step = sqlite3_step(refs)
        while step == SQLITE_ROW {
            let kind = String(cString: sqlite3_column_text(refs, 0))
            let id = String(cString: sqlite3_column_text(refs, 1))
            let revision = String(cString: sqlite3_column_text(refs, 2))
            if kind == "meeting" {
                guard let meeting = Int64(id), try MeetingChatStore(databaseURL: databaseURL, readOnly: true)
                    .dependenciesAreCurrent([.init(meetingID: meeting, revision: revision)]) else { return false }
            } else if kind == "capture" {
                guard let root, try VisualMemoryStore(root: root, readOnly: true).moment(id: id) != nil else { return false }
            } else {
                guard let input = MuesliHistoryKind(rawValue: kind), try MuesliHistoryReader(databaseURL: databaseURL)
                    .read(kind: input, id: id)?.revision == revision else { return false }
            }
            step = sqlite3_step(refs)
        }
        guard step == SQLITE_DONE else { throw Self.failure }
        return true
    }

    func setTodo(_ id: String, completed: Bool) throws {
        try ContentPrivacy.shared.beginWrite()
        defer { ContentPrivacy.shared.endWrite() }
        let query = try statement("UPDATE time_turner_todos SET completed=?, reminder_interval=NULL, remind_at=NULL WHERE task_key=? AND deleted_at IS NULL")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_int(query, 1, completed ? 1 : 0)
        bind(id, to: query, at: 2)
        guard sqlite3_step(query) == SQLITE_DONE else { throw Self.failure }
    }

    /// Opt-in, elapsed-time reminders survive restart and timezone changes.
    func snoozeTodo(_ id: String, interval: TimeInterval?, now: Date = Date()) throws {
        guard interval == nil || [43200.0, 86400.0].contains(interval!) else { throw Self.failure }
        try ContentPrivacy.shared.beginWrite()
        defer { ContentPrivacy.shared.endWrite() }
        let query = try statement("UPDATE time_turner_todos SET reminder_interval=?,remind_at=? WHERE task_key=? AND deleted_at IS NULL AND completed=0")
        defer { sqlite3_finalize(query) }
        if let interval {
            sqlite3_bind_double(query, 1, interval); sqlite3_bind_double(query, 2, now.addingTimeInterval(interval).timeIntervalSince1970)
        } else { sqlite3_bind_null(query, 1); sqlite3_bind_null(query, 2) }
        bind(id, to: query, at: 3)
        guard sqlite3_step(query) == SQLITE_DONE else { throw Self.failure }
    }

    func hasDueTodos(now: Date) throws -> Bool {
        let query = try statement("SELECT 1 FROM time_turner_todos WHERE deleted_at IS NULL AND completed=0 AND remind_at<=? LIMIT 1")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_double(query, 1, now.timeIntervalSince1970)
        let status = sqlite3_step(query)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw Self.failure }
        return status == SQLITE_ROW
    }

    /// Compare the observed deadline so a late delivery cannot overwrite a newer snooze.
    func deliveredTodo(_ item: Todo, now: Date) throws {
        guard let due = item.remindAt else { return }
        try ContentPrivacy.shared.beginWrite()
        defer { ContentPrivacy.shared.endWrite() }
        let query = try statement("UPDATE time_turner_todos SET remind_at=?+reminder_interval WHERE task_key=? AND deleted_at IS NULL AND completed=0 AND remind_at=?")
        defer { sqlite3_finalize(query) }
        sqlite3_bind_double(query, 1, now.timeIntervalSince1970)
        bind(item.id, to: query, at: 2)
        sqlite3_bind_double(query, 3, due.timeIntervalSince1970)
        guard sqlite3_step(query) == SQLITE_DONE else { throw Self.failure }
    }

    /// The model supplies equivalence decisions. This transaction only moves
    /// identities and evidence, preserving user-owned completion and reminders.
    func reconcile(_ insights: [TimeTurnerRecapInsight]) throws {
        for insight in insights where insight.section == .followUps {
            guard let target = insight.taskID else { continue }
            for duplicate in insight.duplicateTaskIDs ?? [] {
                guard duplicate != target else { throw Self.failure }
                func run(_ sql: String) throws {
                    let s = try statement(sql); defer { sqlite3_finalize(s) }
                    bind(target, to: s, at: 1); bind(duplicate, to: s, at: 2)
                    guard sqlite3_step(s) == SQLITE_DONE else { throw Self.failure }
                }
                try run("""
                    UPDATE time_turner_todos SET
                        completed=max(completed,(SELECT completed FROM time_turner_todos WHERE task_key=?2)),
                        created_at=min(created_at,(SELECT created_at FROM time_turner_todos WHERE task_key=?2)),
                        reminder_interval=CASE WHEN remind_at IS NULL OR remind_at>(SELECT remind_at FROM time_turner_todos WHERE task_key=?2)
                            THEN coalesce((SELECT reminder_interval FROM time_turner_todos WHERE task_key=?2),reminder_interval) ELSE reminder_interval END,
                        remind_at=CASE WHEN remind_at IS NULL THEN (SELECT remind_at FROM time_turner_todos WHERE task_key=?2)
                            ELSE min(remind_at,coalesce((SELECT remind_at FROM time_turner_todos WHERE task_key=?2),remind_at)) END
                    WHERE task_key=?1
                    """)
                try run("INSERT OR IGNORE INTO time_turner_todo_links SELECT day_key,?1,title FROM time_turner_todo_links WHERE task_key=?2")
                try run("INSERT OR IGNORE INTO time_turner_todo_refs SELECT day_key,?1,kind,source_id,parent_id,revision FROM time_turner_todo_refs WHERE task_key=?2")
                try run("UPDATE time_turner_todo_aliases SET task_id=?1 WHERE task_id=?2")
                try run("UPDATE time_turner_todo_redirects SET task_id=?1 WHERE task_id=?2")
                try run("INSERT OR REPLACE INTO time_turner_todo_redirects VALUES(?2,?1)")
                try run("DELETE FROM time_turner_todo_links WHERE task_key=?2")
                try run("UPDATE time_turner_todos SET remind_at=NULL,reminder_interval=NULL WHERE task_key=?1 AND completed=1")
            }
        }
    }

    /// Serialize main-database validation with publication. Source mutations must
    /// occur before validation or after INSERT, where the invalidation trigger sees it.
    func publish(_ recap: SavedTimeTurnerRecap, reconcile: (() throws -> Void)? = nil, validate: () throws -> Bool) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            guard try validate() else { throw TimeTurnerRecapError.changedSources }
            try reconcile?()
            try save(recap)
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func save(_ recap: SavedTimeTurnerRecap) throws {
        try ContentPrivacy.shared.beginWrite()
        defer { ContentPrivacy.shared.endWrite() }
        guard recap.version == 1, recap.dayEnd > recap.dayStart else { throw Self.failure }
        try execute("SAVEPOINT write_recap")
        do {
            var recap = recap
            var insights = recap.insights
            for index in insights.indices where insights[index].section == .followUps && insights[index].taskID == nil {
                let title = insights[index].action ?? insights[index].text
                let alias = try statement("INSERT OR IGNORE INTO time_turner_todo_aliases VALUES(lower(trim(?)),?)")
                bind(title, to: alias, at: 1); bind(UUID().uuidString, to: alias, at: 2)
                let status = sqlite3_step(alias); sqlite3_finalize(alias)
                guard status == SQLITE_DONE else { throw Self.failure }
                let read = try statement("SELECT task_id FROM time_turner_todo_aliases WHERE legacy_key=lower(trim(?))")
                bind(title, to: read, at: 1)
                guard sqlite3_step(read) == SQLITE_ROW else { sqlite3_finalize(read); throw Self.failure }
                insights[index].taskID = String(cString: sqlite3_column_text(read, 0)); sqlite3_finalize(read)
            }
            recap.insights = insights
            let body = String(decoding: try JSONEncoder().encode(recap), as: UTF8.self)
            // Plain UPDATE preserves to-do links and lets triggers use their own
            // conflict policies. SQLite's DO UPDATE would force ABORT inside them.
            // Archive in the same table so every existing source invalidation,
            // retention and search contract applies equally to earlier versions.
            if recap.storageKey == nil, recap.inputFingerprint != nil,
               var previous = try load(key: recap.dayKey), previous.generatedAt != recap.generatedAt {
                previous.storageKey = previous.dayKey + "|version|" + UUID().uuidString
                try save(previous)
            }
            func write(_ sql: String) throws {
                let s = try statement(sql)
                defer { sqlite3_finalize(s) }
                bind(recap.key, to: s, at: 1)
                sqlite3_bind_double(s, 2, recap.dayStart.timeIntervalSince1970)
                sqlite3_bind_double(s, 3, recap.dayEnd.timeIntervalSince1970)
                bind(recap.timeZone, to: s, at: 4)
                sqlite3_bind_double(s, 5, recap.generatedAt.timeIntervalSince1970)
                bind(body, to: s, at: 6)
                guard try GlobalSearchIndex.stepSourceWrite(s) == SQLITE_DONE else { throw Self.failure }
            }
            try write("UPDATE time_turner_recaps SET day_start=?2,day_end=?3,time_zone=?4,generated_at=?5,body=?6 WHERE day_key=?1")
            if sqlite3_changes(db) == 0 {
                try write("INSERT INTO time_turner_recaps(day_key,day_start,day_end,time_zone,generated_at,body) VALUES(?,?,?,?,?,?)")
            }
            for insight in recap.insights where insight.section == .followUps {
                guard let id = insight.taskID else { continue }
                let update = try statement("UPDATE time_turner_todo_links SET title=? WHERE day_key=? AND task_key=?")
                bind(insight.action ?? insight.text, to: update, at: 1)
                bind(recap.key, to: update, at: 2); bind(id, to: update, at: 3)
                let status = sqlite3_step(update); sqlite3_finalize(update)
                guard status == SQLITE_DONE else { throw Self.failure }
            }
            try execute("RELEASE write_recap")
        } catch {
            try? execute("ROLLBACK TO write_recap")
            try? execute("RELEASE write_recap")
            throw error
        }
    }
    /// Delete derived text, including stored OCR snapshots, without needing to open its day.
    func delete(captureIDs: Set<String>) throws {
        guard !captureIDs.isEmpty else { return }
        let ids = String(decoding: try JSONEncoder().encode(captureIDs.sorted()), as: UTF8.self)
        try execute("BEGIN IMMEDIATE")
        do {
            let remove = try statement("DELETE FROM time_turner_todo_links WHERE (day_key,task_key) IN (SELECT day_key,task_key FROM time_turner_todo_refs WHERE kind='capture' AND source_id IN (SELECT value FROM json_each(?)))")
            defer { sqlite3_finalize(remove) }
            bind(ids, to: remove, at: 1)
            guard sqlite3_step(remove) == SQLITE_DONE else { throw Self.failure }
            let s = try statement("""
                DELETE FROM time_turner_recaps WHERE EXISTS (
                    SELECT 1 FROM json_each(time_turner_recaps.body, '$.sources')
                    WHERE json_extract(value, '$.capture.id') IN (SELECT value FROM json_each(?))
                )
                """)
            defer { sqlite3_finalize(s) }
            bind(ids, to: s, at: 1)
            guard try GlobalSearchIndex.stepSourceWrite(s) == SQLITE_DONE else { throw Self.failure }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func load(key: String) throws -> SavedTimeTurnerRecap? {
        let s = try statement("SELECT body FROM time_turner_recaps WHERE day_key=?")
        defer { sqlite3_finalize(s) }
        bind(key, to: s, at: 1)
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else { throw Self.failure }
        let value = try JSONDecoder().decode(SavedTimeTurnerRecap.self, from: Data(String(cString: text).utf8))
        guard value.version == 1, value.key == key else { throw Self.failure }
        return value
    }
    func delete(key: String, generatedAt: Date? = nil) throws {
        let s = try statement("DELETE FROM time_turner_recaps WHERE day_key=?" + (generatedAt == nil ? "" : " AND generated_at=?"))
        defer { sqlite3_finalize(s) }
        bind(key, to: s, at: 1)
        if let generatedAt { sqlite3_bind_double(s, 2, generatedAt.timeIntervalSince1970) }
        guard try GlobalSearchIndex.stepSourceWrite(s) == SQLITE_DONE else { throw Self.failure }
    }
}

/// Serializes in-process source deletion and recap publication across the two local
/// databases. Capture tombstones persist until recap cleanup succeeds, so a restart
/// retries interrupted cleanup without relying on a user opening the recap.
enum TimeTurnerRetention {
    private static let lock = NSRecursiveLock()

    static func maintain(store: VisualMemoryStore, databaseURL: URL,
                         policy: VisualMemoryRetentionPolicy, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        // Expire source history even if a previous recap cleanup failed. Both success
        // and failure paths retry durable IDs, independently of media cleanup.
        do { try store.applyRetention(policy, now: now) }
        catch {
            try purgeDeletedSources(store: store, databaseURL: databaseURL)
            throw error
        }
        try purgeDeletedSources(store: store, databaseURL: databaseURL)
    }

    static func delete(ids: Set<String>, store: VisualMemoryStore, databaseURL: URL) throws {
        lock.lock(); defer { lock.unlock() }
        do { try store.delete(ids: ids) }
        catch {
            try purgeDeletedSources(store: store, databaseURL: databaseURL)
            throw error
        }
        try purgeDeletedSources(store: store, databaseURL: databaseURL)
    }

    private static func purgeDeletedSources(store: VisualMemoryStore, databaseURL: URL) throws {
        let ids = try store.pendingCaptureDeletions()
        guard !ids.isEmpty else { return }
        try TimeTurnerRecapStore(databaseURL: databaseURL).delete(captureIDs: ids)
        try MeetingChatStore(databaseURL: databaseURL).invalidateHistoryCaptures(Array(ids))
        try store.acknowledgeCaptureDeletions(ids)
    }

    static func save(_ recap: SavedTimeTurnerRecap, root: URL?, databaseURL: URL, taskContext: [TimeTurnerTaskContext]? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        let store = try TimeTurnerRecapStore(databaseURL: databaseURL)
        try store.publish(recap, reconcile: {
            if let taskContext {
                let current = try store.todos(root: root, databaseURL: databaseURL)
                    .map { TimeTurnerTaskContext(id: $0.id, title: $0.title, completed: $0.completed) }
                guard current == taskContext else { throw TimeTurnerRecapError.changedSources }
                try store.reconcile(recap.insights)
            }
        }) {
            try TimeTurnerRecap.sourcesAreCurrent(recap.sources, root: root, databaseURL: databaseURL)
        }
    }
}
