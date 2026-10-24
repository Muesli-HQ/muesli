import Foundation
import CoreGraphics
import SQLite3

/// Device-local evidence. Deliberately separate from meeting CloudKit records.
public struct VisualMemoryItem: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case meetingVideo, moment }
    public var id: String
    public var kind: Kind
    public var meetingID: Int64?
    public var capturedAt: Date
    public var source: String
    public var bundleID: String
    public var text: String
    public var appName: String?
    public var windowTitle: String?
    public var path: String
    public var duration: Double
    public var meetingOffset: Double
    public var frameIndex: Int?
    public var captureCompletedAt: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var bytes: Int64

    public init(id: String = UUID().uuidString, kind: Kind, meetingID: Int64? = nil,
                capturedAt: Date = Date(), source: String, bundleID: String = "", text: String = "",
                path: String, duration: Double = 0, meetingOffset: Double = 0, frameIndex: Int? = nil, bytes: Int64 = 0,
                captureCompletedAt: Date? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil, appName: String? = nil, windowTitle: String? = nil) {
        self.appName = appName; self.windowTitle = windowTitle
        self.id = id; self.kind = kind; self.meetingID = meetingID; self.capturedAt = capturedAt
        self.source = source; self.bundleID = bundleID; self.text = text; self.path = path
        self.captureCompletedAt = captureCompletedAt; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.duration = duration; self.meetingOffset = meetingOffset; self.frameIndex = frameIndex; self.bytes = bytes
    }
}

/// Serialized, bound SQLite writes; media bytes live alongside the catalog.
public final class VisualMemoryStore: @unchecked Sendable {
    public let root: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var hasCaptureTable = false
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(root: URL, readOnly: Bool = false) throws {
        self.root = root
        if !readOnly { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        guard sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &db,
                             (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw failure()
        }
        sqlite3_busy_timeout(db, 5_000)
        hasCaptureTable = try scalar("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='time_turner_captures'") > 0
        if readOnly { return }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS evidence(id TEXT PRIMARY KEY, kind TEXT NOT NULL, meeting_id INTEGER, captured REAL NOT NULL, body TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS evidence_time ON evidence(kind,captured)")
        try execute("CREATE INDEX IF NOT EXISTS evidence_meeting ON evidence(meeting_id)")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS evidence_search USING fts5(id UNINDEXED, text)")
        try migrateCaptureTable()

    }
    deinit { sqlite3_close(db) }
    private func failure() -> NSError {
        NSError(domain: "VisualMemoryStore", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func scalar(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Versioned, transactional projection for SQL consumers. Evidence remains the
    /// compatibility record; triggers keep typed columns in sync even for older writers.
    private func migrateCaptureTable() throws {
        let version = try scalar("PRAGMA user_version")
        guard version <= 1 else { throw NSError(domain: "VisualMemoryStore", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Screen history was created by a newer Muesli version."]) }
        guard version < 1 else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            // Another connection may have upgraded while BEGIN waited for its lock.
            if try scalar("PRAGMA user_version") == 1 {
                try execute("COMMIT"); hasCaptureTable = true; return
            }
            try execute("DROP VIEW IF EXISTS time_turner_captures")
            try execute("""
                CREATE TABLE time_turner_captures (
                    id TEXT PRIMARY KEY NOT NULL,
                    captured_at_unix REAL NOT NULL,
                    captured_at_utc TEXT NOT NULL,
                    capture_completed_at_unix REAL,
                    source TEXT NOT NULL,
                    bundle_id TEXT NOT NULL COLLATE NOCASE,
                    app_name TEXT NOT NULL COLLATE NOCASE,
                    window_title TEXT,
                    ocr_text TEXT NOT NULL,
                    media_relative_path TEXT NOT NULL,
                    archive_frame_index INTEGER,
                    pixel_width INTEGER,
                    pixel_height INTEGER,
                    media_bytes INTEGER NOT NULL
                );
                CREATE INDEX captures_time ON time_turner_captures(captured_at_unix DESC,id);
                CREATE INDEX captures_bundle_time ON time_turner_captures(bundle_id,captured_at_unix DESC,id);
                CREATE INDEX captures_app_time ON time_turner_captures(app_name,captured_at_unix DESC,id);
                """)
            let projection = """
                SELECT id, captured, strftime('%Y-%m-%dT%H:%M:%fZ', captured, 'unixepoch'),
                    json_extract(body,'$.captureCompletedAt') + 978307200,
                    json_extract(body,'$.source'), coalesce(json_extract(body,'$.bundleID'),''),
                    coalesce(json_extract(body,'$.appName'), CASE WHEN instr(json_extract(body,'$.source'),' · ')>0
                        THEN substr(json_extract(body,'$.source'),1,instr(json_extract(body,'$.source'),' · ')-1)
                        ELSE json_extract(body,'$.source') END),
                    json_extract(body,'$.windowTitle'), json_extract(body,'$.text'),
                    json_extract(body,'$.path'), json_extract(body,'$.frameIndex'),
                    json_extract(body,'$.pixelWidth'), json_extract(body,'$.pixelHeight'), json_extract(body,'$.bytes')
                FROM evidence WHERE kind='moment'
                """
            try execute("INSERT INTO time_turner_captures " + projection)
            for event in ["INSERT", "UPDATE"] {
                let oldIDCleanup = event == "UPDATE" ? "DELETE FROM time_turner_captures WHERE id=OLD.id;" : ""
                try execute("""
                    CREATE TRIGGER captures_after_\(event.lowercased()) AFTER \(event) ON evidence BEGIN
                        \(oldIDCleanup)
                        DELETE FROM time_turner_captures WHERE id=NEW.id;
                        INSERT INTO time_turner_captures \(projection) AND id=NEW.id;
                    END;
                    """)
            }
            try execute("""
                CREATE TRIGGER captures_after_delete AFTER DELETE ON evidence BEGIN
                    DELETE FROM time_turner_captures WHERE id=OLD.id;
                END;
                DELETE FROM evidence_search;
                INSERT INTO evidence_search SELECT id,json_extract(body,'$.source') || ' ' || json_extract(body,'$.text') FROM evidence;
                PRAGMA user_version=1;
                COMMIT;
                """)
            hasCaptureTable = true
        } catch { try? execute("ROLLBACK"); throw error }
    }

    public func url(for path: String) throws -> URL {
        let resolved = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.hasPrefix("/"), resolved.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
            throw NSError(domain: "VisualMemoryStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid media path"])
        }
        return resolved
    }
    public func save(_ items: [VisualMemoryItem]) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            for item in items {
                _ = try url(for: item.path)
                let body = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO evidence VALUES(?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, item.id, -1, transient)
                sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, transient)
                if let id = item.meetingID { sqlite3_bind_int64(stmt, 3, id) } else { sqlite3_bind_null(stmt, 3) }
                sqlite3_bind_double(stmt, 4, item.capturedAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 5, body, -1, transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
                try removeSearch(item.id)
                var search: OpaquePointer?
                guard sqlite3_prepare_v2(db, "INSERT INTO evidence_search VALUES(?,?)", -1, &search, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(search) }
                sqlite3_bind_text(search, 1, item.id, -1, transient)
                sqlite3_bind_text(search, 2, item.source + " " + item.text, -1, transient)
                guard sqlite3_step(search) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func removeSearch(_ id: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM evidence_search WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }
    public func items() throws -> [VisualMemoryItem] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT body FROM evidence ORDER BY captured DESC", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        var result: [VisualMemoryItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            let body = String(cString: sqlite3_column_text(stmt, 0))
            result.append(try JSONDecoder().decode(VisualMemoryItem.self, from: Data(body.utf8)))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }
    public func moment(id: String) throws -> VisualMemoryItem? {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT body FROM evidence WHERE kind='moment' AND id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        let status = sqlite3_step(stmt)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw failure() }
        return try JSONDecoder().decode(VisualMemoryItem.self, from: Data(String(cString: sqlite3_column_text(stmt, 0)).utf8))
    }

    /// Literal word/phrase search with a half-open UTC time range and bounded results.
    /// This does not expose SQL or FTS expression syntax to callers.
    public func searchMoments(text: String = "", from: Date = .distantPast,
                              until: Date = .distantFuture, app: String? = nil, limit: Int = 100, after: VisualMemoryCursor? = nil) throws -> [VisualMemoryItem] {
        lock.lock(); defer { lock.unlock() }
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchClause = phrase.isEmpty ? "" : " AND id IN (SELECT id FROM evidence_search WHERE evidence_search MATCH ?)"
        let legacyAppClause = app == nil ? "" : " AND (lower(json_extract(body,'$.bundleID'))=lower(?) OR lower(CASE WHEN instr(json_extract(body,'$.source'),' · ')>0 THEN substr(json_extract(body,'$.source'),1,instr(json_extract(body,'$.source'),' · ')-1) ELSE json_extract(body,'$.source') END)=lower(?))"
        let appClause = app == nil ? "" : (hasCaptureTable
            ? " AND id IN (SELECT id FROM time_turner_captures WHERE bundle_id=? COLLATE NOCASE OR app_name=? COLLATE NOCASE)"
            : legacyAppClause)
        let cursorClause = after == nil ? "" : " AND (captured<? OR (captured=? AND id>?))"
        var stmt: OpaquePointer?
        let sql = "SELECT body FROM evidence WHERE kind='moment' AND captured>=? AND captured<?" + searchClause + appClause + cursorClause + " ORDER BY captured DESC,id LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 2, until.timeIntervalSince1970)
        var slot: Int32 = 3
        if !phrase.isEmpty {
            let literal = "\"" + phrase.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            sqlite3_bind_text(stmt, slot, literal, -1, transient); slot += 1
        }
        if let app {
            sqlite3_bind_text(stmt, slot, app, -1, transient); slot += 1
            sqlite3_bind_text(stmt, slot, app, -1, transient); slot += 1
        }
        if let after {
            sqlite3_bind_double(stmt, slot, after.capturedAtUnix); slot += 1
            sqlite3_bind_double(stmt, slot, after.capturedAtUnix); slot += 1
            sqlite3_bind_text(stmt, slot, after.id, -1, transient); slot += 1
        }
        sqlite3_bind_int(stmt, slot, Int32(max(1, min(1001, limit))))
        var result: [VisualMemoryItem] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            result.append(try JSONDecoder().decode(VisualMemoryItem.self,
                from: Data(String(cString: sqlite3_column_text(stmt, 0)).utf8)))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    /// Remove metadata first, then only unreferenced files. A crash can leave an orphan,
    /// never a surviving reference to deliberately forgotten evidence.
    public func delete(ids: Set<String>) throws {
        lock.lock(); defer { lock.unlock() }
        let before = try items()
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, "DELETE FROM evidence WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, id, -1, transient)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
                try removeSearch(id)
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        let retainedPaths = Set(before.filter { !ids.contains($0.id) }.map(\.path))
        for path in Set(before.filter { ids.contains($0.id) }.map(\.path)).subtracting(retainedPaths) {
            let file = try url(for: path)
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
}

public struct ScreenRecordingPauseState: Equatable, Sendable {
    public var userPaused = false
    public var meetingPaused = false
    public var isPaused: Bool { userPaused || meetingPaused }
    public init() {}
}

/// Match the entire focused window, not a same-width toolbar or overlay.
public enum VisualMemoryWindowMatch {
    public static func matches(candidate: CGRect, focused: CGRect, layer: Int) -> Bool {
        layer == 0 && candidate.width >= 100 && candidate.height >= 100
            && abs(candidate.minX - focused.minX) < 3
            && abs(candidate.minY - focused.minY) < 3
            && abs(candidate.width - focused.width) < 3
            && abs(candidate.height - focused.height) < 3
    }
}

/// Wall-clock navigation is independent of app groups and archive frame offsets.
public enum VisualMemoryDayTimeline {
    public static func moments(_ items: [VisualMemoryItem], on day: Date, calendar: Calendar = .current) -> [VisualMemoryItem] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        return items.filter { $0.kind == .moment && $0.capturedAt >= interval.start && $0.capturedAt < interval.end }
            .sorted { $0.capturedAt == $1.capturedAt ? $0.id < $1.id : $0.capturedAt < $1.capturedAt }
    }

    /// Fit the track to saved evidence, never to future hours. A single sample gets
    /// one second of preceding space so the track remains finite without inventing future coverage.
    public static func captureInterval(in ordered: [VisualMemoryItem]) -> DateInterval? {
        guard let first = ordered.first?.capturedAt, let last = ordered.last?.capturedAt else { return nil }
        return DateInterval(start: min(first, last.addingTimeInterval(-1)), end: last)
    }

    /// Nearest sample; ties choose the earlier capture. Never crosses a day boundary.
    public static func nearestIndex(in ordered: [VisualMemoryItem], to time: Date) -> Int? {
        guard !ordered.isEmpty else { return nil }
        var low = 0, high = ordered.count
        while low < high {
            let mid = (low + high) / 2
            if ordered[mid].capturedAt < time { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return 0 }
        if low == ordered.count { return ordered.count - 1 }
        return time.timeIntervalSince(ordered[low - 1].capturedAt) <= ordered[low].capturedAt.timeIntervalSince(time) ? low - 1 : low
    }
}

/// Compresses empty time on the browse axis without changing evidence timestamps.
public struct VisualMemoryScrubScale {
    private let dates: [Date]
    private let positions: [Double]
    public init(dates: [Date]) {
        self.dates = dates.sorted()
        var offsets = [Double]()
        for (index, date) in self.dates.enumerated() {
            offsets.append(index == 0 ? 0 : offsets[index - 1] + min(120, max(1, date.timeIntervalSince(self.dates[index - 1]))))
        }
        positions = offsets
    }
    public var compressesGaps: Bool {
        zip(dates, dates.dropFirst()).contains { $1.timeIntervalSince($0) > 120 }
    }
    public func fraction(for date: Date) -> Double {
        guard let first = dates.first, let last = dates.last, let total = positions.last, total > 0 else { return 0 }
        if date <= first { return 0 }; if date >= last { return 1 }
        let upper = dates.firstIndex { $0 >= date }!
        let lower = upper - 1
        let interval = dates[upper].timeIntervalSince(dates[lower])
        let local = interval > 0 ? date.timeIntervalSince(dates[lower]) / interval : 0
        return (positions[lower] + local * (positions[upper] - positions[lower])) / total
    }
    public func date(at fraction: Double) -> Date? {
        guard let first = dates.first, let total = positions.last, total > 0 else { return dates.first }
        let position = min(1, max(0, fraction)) * total
        guard let upper = positions.firstIndex(where: { $0 >= position }), upper > 0 else { return first }
        let lower = upper - 1
        let local = (position - positions[lower]) / (positions[upper] - positions[lower])
        return dates[lower].addingTimeInterval(local * dates[upper].timeIntervalSince(dates[lower]))
    }
}

/// Stable keyset position; does not depend on the referenced capture still existing.
public struct VisualMemoryCursor: Codable, Sendable {
    public let capturedAtUnix: Double
    public let id: String
    public init(capturedAtUnix: Double, id: String) {
        self.capturedAtUnix = capturedAtUnix; self.id = id
    }
}
