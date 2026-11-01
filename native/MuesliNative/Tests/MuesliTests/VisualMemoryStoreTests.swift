import Foundation
import CoreGraphics
import Testing
import SQLite3
@testable import MuesliCore

@Suite("Local visual evidence")
struct VisualMemoryStoreTests {
    @Test func upgradesVersionOneRetentionWithoutLosingSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let item = VisualMemoryItem(id: "legacy-v1", kind: .moment, capturedAt: Date(timeIntervalSince1970: 1000), source: "Editor", text: "roadmap", path: "old.heic")
        do { let store = try VisualMemoryStore(root: root); try store.save([item]) }
        var db: OpaquePointer?; sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &db)
        // Reproduce the exact v1 trigger shape and remove v2 additions.
        var query: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT name,sql FROM sqlite_master WHERE name IN ('captures_after_insert','captures_after_update')", -1, &query, nil) == SQLITE_OK)
        var triggers: [(String, String)] = []
        while sqlite3_step(query) == SQLITE_ROW {
            triggers.append((String(cString: sqlite3_column_text(query, 0)), String(cString: sqlite3_column_text(query, 1))))
        }
        sqlite3_finalize(query)
        let columns = " (id,captured_at_unix,captured_at_utc,capture_completed_at_unix,source,bundle_id,app_name,window_title,ocr_text,media_relative_path,archive_frame_index,pixel_width,pixel_height,media_bytes)"
        for (name, sql) in triggers {
            #expect(sqlite3_exec(db, "DROP TRIGGER " + name, nil, nil, nil) == SQLITE_OK)
            #expect(sqlite3_exec(db, sql.replacingOccurrences(of: columns, with: ""), nil, nil, nil) == SQLITE_OK)
        }
        #expect(sqlite3_exec(db, "DROP TRIGGER capture_retention_insert; ALTER TABLE time_turner_captures DROP COLUMN media_deleted_at_unix; DROP TABLE pending_capture_deletions; DROP TABLE pending_media_deletions; PRAGMA user_version=1;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        let upgraded = try VisualMemoryStore(root: root)
        #expect(try upgraded.searchMoments(text: "roadmap").map(\.id) == [item.id])
        try upgraded.applyRetention(.init(historyDays: nil), now: item.capturedAt.addingTimeInterval(7 * 86400))
        #expect(try upgraded.moment(id: item.id)?.mediaDeletedAt != nil)
        #expect(try upgraded.searchMoments(text: "roadmap").count == 1)
        #expect(try !upgraded.replaceMedia([item], ifUnchanged: [item]))
        try upgraded.delete(ids: [item.id])
        #expect(try !upgraded.replaceMedia([item], ifUnchanged: [item]))
    }

    @Test func independentRetentionPreservesChronologicalOCR() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VisualMemoryStore(root: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var old = VisualMemoryItem(id: "old", kind: .moment, capturedAt: now.addingTimeInterval(-7 * 86400),
            source: "Editor · Plan", bundleID: "test.editor", text: "searchable roadmap", path: "old.heic", bytes: 10)
        var fresh = old; fresh.id = "fresh"; fresh.path = "fresh.heic"; fresh.capturedAt = old.capturedAt.addingTimeInterval(1)
        try Data([1]).write(to: root.appendingPathComponent(old.path))
        try Data([2]).write(to: root.appendingPathComponent(fresh.path))
        try store.save([old, fresh])
        try store.applyRetention(.init(), now: now)
        let retiredItem = try store.moment(id: "old")
        let expired = try #require(retiredItem)
        #expect(expired.mediaDeletedAt == now)
        #expect(expired.bytes == 0 && expired.text == old.text)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(old.path).path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(fresh.path).path))
        let reopened = try VisualMemoryStore(root: root, readOnly: true)
        #expect(try reopened.searchMoments(text: "roadmap", app: "test.editor", chronological: true).map(\.id) == ["old", "fresh"])
        var db: OpaquePointer?; sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &db)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT media_deleted_at_unix,media_bytes FROM time_turner_captures WHERE id='old'", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_double(statement, 0) == now.timeIntervalSince1970)
        #expect(sqlite3_column_int64(statement, 1) == 0)
        try store.applyRetention(.init(), now: old.capturedAt.addingTimeInterval(30 * 86400))
        #expect(try store.moment(id: "old") == nil)
        #expect(try store.moment(id: "fresh") != nil)
        #expect(try store.pendingCaptureDeletions() == ["old"])
        old.mediaDeletedAt = nil // An older serialized record decodes without the optional field.
        let data = try JSONEncoder().encode(old)
        #expect(try JSONDecoder().decode(VisualMemoryItem.self, from: data).mediaDeletedAt == nil)
    }

    @Test func budgetEvictsSharedMediaWithoutDeletingHistoryOrMeetingVideos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VisualMemoryStore(root: root)
        let now = Date()
        let first = VisualMemoryItem(id: "a", kind: .moment, capturedAt: now, source: "Editor", text: "alpha", path: "archive.mp4", frameIndex: 0, bytes: 100)
        var second = first; second.id = "b"; second.frameIndex = 1
        let video = VisualMemoryItem(id: "meeting", kind: .meetingVideo, capturedAt: .distantPast, source: "Call", path: "meeting.mp4", bytes: 100)
        try store.save([first, second, video])
        try Data([1]).write(to: root.appendingPathComponent(first.path))
        try Data([2]).write(to: root.appendingPathComponent(video.path))
        try store.applyRetention(.init(historyDays: nil, mediaBudgetBytes: 0), now: now)
        #expect(try store.searchMoments(text: "alpha").count == 2)
        #expect(try store.moment(id: "a")?.mediaDeletedAt == now)
        #expect(try store.moment(id: "b")?.mediaDeletedAt == now)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(video.path).path))
        try store.applyRetention(.init(historyDays: nil), now: now.addingTimeInterval(1000 * 86400))
        #expect(try store.searchMoments().count == 2)
        try store.delete(ids: ["a", "b"])
        #expect(try store.searchMoments(text: "alpha").isEmpty)
        #expect(try store.pendingCaptureDeletions() == ["a", "b"])
        try store.acknowledgeCaptureDeletions(["a"])
        #expect(try VisualMemoryStore(root: root).pendingCaptureDeletions() == ["b"])
    }

    @Test func migratesLegacyViewAndRepairsSearchWithoutLosingEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let item = VisualMemoryItem(id: "legacy", kind: .moment, capturedAt: Date(timeIntervalSince1970: 1000.125),
            source: "Editor · Old title", bundleID: "com.example.editor", text: "legacy roadmap", path: "still.heic")
        let body = String(decoding: try JSONEncoder().encode(item), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
            CREATE TABLE evidence(id TEXT PRIMARY KEY,kind TEXT,meeting_id INTEGER,captured REAL,body TEXT);
            CREATE VIRTUAL TABLE evidence_search USING fts5(id UNINDEXED,text);
            CREATE VIEW time_turner_captures AS SELECT id FROM evidence;
            INSERT INTO evidence VALUES('legacy','moment',NULL,1000.125,'\(body)');
            """, nil, nil, nil) == SQLITE_OK)
        let store = try VisualMemoryStore(root: root)
        #expect(try store.searchMoments(text: "roadmap", app: "EDITOR").map(\.id) == ["legacy"])
        #expect(try store.moment(id: "legacy") == item)
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT app_name,window_title,captured_at_unix FROM time_turner_captures", -1, &stmt, nil) == SQLITE_OK)
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(stmt, 0)) == "Editor")
        #expect(sqlite3_column_type(stmt, 1) == SQLITE_NULL)
        #expect(sqlite3_column_double(stmt, 2) == 1000.125)
        sqlite3_finalize(stmt)
        var updated = item
        updated.appName = "Renamed · App"; updated.windowTitle = "Exact title"
        updated.path = "archive.mp4"; updated.frameIndex = 7
        try store.save([updated])
        #expect(try store.searchMoments(app: "Renamed · App").map(\.id) == ["legacy"])
        #expect(try store.searchMoments(app: "Editor").isEmpty)
        let reopened = try VisualMemoryStore(root: root)
        #expect(try reopened.moment(id: "legacy") == updated)
        updated.kind = .meetingVideo
        try store.save([updated])
        #expect(sqlite3_prepare_v2(db, "SELECT count(*) FROM time_turner_captures", -1, &stmt, nil) == SQLITE_OK)
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == 0)
        sqlite3_finalize(stmt)
    }

    @Test func failedMigrationRollsBackTheLegacyView() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, """
            CREATE TABLE evidence(id TEXT PRIMARY KEY,kind TEXT,meeting_id INTEGER,captured REAL,body TEXT);
            CREATE VIRTUAL TABLE evidence_search USING fts5(id UNINDEXED,text);
            CREATE VIEW time_turner_captures AS SELECT id FROM evidence;
            INSERT INTO evidence VALUES('broken','moment',NULL,1000,'invalid json');
            """, nil, nil, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { _ = try VisualMemoryStore(root: root) }
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT type FROM sqlite_master WHERE name='time_turner_captures'", -1, &stmt, nil) == SQLITE_OK)
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(String(cString: sqlite3_column_text(stmt, 0)) == "view")
        sqlite3_finalize(stmt)
        #expect(sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK)
        #expect(sqlite3_step(stmt) == SQLITE_ROW)
        #expect(sqlite3_column_int(stmt, 0) == 0)
        sqlite3_finalize(stmt)
    }

    @Test func paginationKeepsEqualTimestampsAndSurvivesCursorDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VisualMemoryStore(root: root)
        let time = Date(timeIntervalSince1970: 1000.125)
        let captures = ["a", "b", "c"].map {
            VisualMemoryItem(id: $0, kind: .moment, capturedAt: time, source: "Editor", text: "roadmap", path: $0 + ".heic")
        }
        try store.save(captures)
        let first = try #require(store.searchMoments(text: "roadmap", limit: 1).first)
        #expect(first.id == "a")
        let cursor = VisualMemoryCursor(capturedAtUnix: first.capturedAt.timeIntervalSince1970, id: first.id)
        try store.delete(ids: [first.id])
        #expect(try store.searchMoments(text: "roadmap", after: cursor).map(\.id) == ["b", "c"])
        try store.save([VisualMemoryItem(id: "new", kind: .moment, capturedAt: time.addingTimeInterval(1), source: "Editor", text: "roadmap", path: "new.heic")])
        #expect(try store.searchMoments(after: cursor).map(\.id) == ["b", "c"])
    }

    @Test func chronologicalHistoryPreservesTiesBoundsAndTextWithoutMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VisualMemoryStore(root: root)
        let start = Date(timeIntervalSince1970: 1000)
        func item(_ id: String, _ offset: Double, app: String = "Editor") -> VisualMemoryItem {
            VisualMemoryItem(id: id, kind: .moment, capturedAt: start.addingTimeInterval(offset),
                source: app, bundleID: app, text: "Observed text", path: "missing-" + id + ".heic", appName: app)
        }
        try store.save([item("before", -1), item("a", 0), item("b", 0), item("c", 1), item("other", 1, app: "Browser"), item("end", 2)])
        let first = try store.searchMoments(from: start, until: start.addingTimeInterval(2), app: "editor", limit: 1, chronological: true)
        #expect(first.map(\.id) == ["a"])
        let cursor = VisualMemoryCursor(capturedAtUnix: start.timeIntervalSince1970, id: "a")
        try store.delete(ids: ["a"])
        let rest = try store.searchMoments(from: start, until: start.addingTimeInterval(2), app: "editor", after: cursor, chronological: true)
        #expect(rest.map(\.id) == ["b", "c"])
        #expect(rest.allSatisfy { $0.text == "Observed text" })
        #expect(try store.searchMoments(from: start, until: start.addingTimeInterval(2), app: "editor").map(\.id) == ["c", "b"])
    }

    @Test func roundTripAndSharedChunkDeletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VisualMemoryStore(root: root)
        let file = try store.url(for: "chunk.mp4")
        try Data([1, 2, 3]).write(to: file)
        let one = VisualMemoryItem(kind: .moment, source: "Quoted ' source", text: "SELECT *; 中文", path: "chunk.mp4", frameIndex: 0)
        let two = VisualMemoryItem(kind: .moment, source: "Second", path: "chunk.mp4", frameIndex: 1)
        try store.save([one, two])
        #expect(Set(try store.items().map(\.id)) == [one.id, two.id])
        #expect(try store.items().first { $0.id == one.id }?.text == one.text)
        try store.delete(ids: [one.id])
        #expect(FileManager.default.fileExists(atPath: file.path))
        try store.delete(ids: [two.id])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try store.items().isEmpty)
    }

    @Test func failedBatchRollsBackAndRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VisualMemoryStore(root: root)
        let valid = VisualMemoryItem(kind: .meetingVideo, meetingID: 5, source: "Display", path: "clip.mp4", meetingOffset: 12)
        let invalid = VisualMemoryItem(kind: .moment, source: "Bad", path: "../outside.heic")
        #expect(throws: (any Error).self) { try store.save([valid, invalid]) }
        #expect(try store.items().isEmpty)
        #expect(throws: (any Error).self) { try store.url(for: "/tmp/outside") }
        try store.save([valid]); try store.save([valid])
        #expect(try store.items().count == 1)
        let reopened = try VisualMemoryStore(root: root)
        #expect(try reopened.items().first?.meetingOffset == 12)
    }

    @Test func rejectsSameWidthToolbar() {
        let full = CGRect(x: 0, y: 30, width: 1512, height: 900)
        #expect(VisualMemoryWindowMatch.matches(candidate: full, focused: full, layer: 0))
        #expect(!VisualMemoryWindowMatch.matches(candidate: CGRect(x: 0, y: 30, width: 1512, height: 32), focused: full, layer: 0))
        #expect(!VisualMemoryWindowMatch.matches(candidate: full, focused: full, layer: 1))
    }

    @Test func indexedSearchUsesCaptureTimeAndSurvivesCompaction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VisualMemoryStore(root: root)
        let time = Date(timeIntervalSince1970: 1_792_691_605.921857)
        var item = VisualMemoryItem(kind: .moment, capturedAt: time, source: "Editor", text: "release checklist", path: "still.heic",
                                   captureCompletedAt: time.addingTimeInterval(0.2), pixelWidth: 3024, pixelHeight: 1800)
        try store.save([item])
        #expect(try store.searchMoments(text: "release", from: time, until: time.addingTimeInterval(1)).map(\.id) == [item.id])
        #expect(try store.searchMoments(until: time).isEmpty)
        #expect(try store.searchMoments(text: "\" OR *").isEmpty)
        item.path = "archive.mp4"; item.frameIndex = 12
        try store.save([item])
        let result = try store.searchMoments(text: "release").first
        #expect(result?.capturedAt == time)
        #expect(result?.frameIndex == 12)
        #expect(result?.captureCompletedAt == time.addingTimeInterval(0.2))
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(root.appendingPathComponent("catalog.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT captured_at_unix,capture_completed_at_unix,archive_frame_index FROM time_turner_captures", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(abs(sqlite3_column_double(statement, 0) - time.timeIntervalSince1970) < 0.000001)
        #expect(abs(sqlite3_column_double(statement, 1) - time.addingTimeInterval(0.2).timeIntervalSince1970) < 0.000001)
        #expect(sqlite3_column_int(statement, 2) == 12)
        sqlite3_reset(statement)

        try store.delete(ids: [item.id])
        #expect(try store.searchMoments(text: "release").isEmpty)
    }

    @Test func readOnlySearchFiltersAppBeforeLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = try VisualMemoryStore(root: root)
        let time = Date(timeIntervalSince1970: 1000)
        let wanted = VisualMemoryItem(kind: .moment, capturedAt: time, source: "ChatGPT · Plan", bundleID: "com.openai.chat", text: "roadmap", path: "a.heic")
        let newer = VisualMemoryItem(kind: .moment, capturedAt: time.addingTimeInterval(1), source: "Editor", bundleID: "editor", text: "roadmap", path: "b.heic")
        try writer.save([wanted, newer])
        let reader = try VisualMemoryStore(root: root, readOnly: true)
        #expect(try reader.searchMoments(text: "roadmap", from: time, until: time.addingTimeInterval(2), app: "chatgpt", limit: 1).map(\.id) == [wanted.id])
        #expect(try reader.searchMoments(app: "COM.OPENAI.CHAT").map(\.id) == [wanted.id])
        #expect(try reader.searchMoments(app: "Chat").isEmpty)
        #expect(try reader.searchMoments(app: "' OR 1=1 --").isEmpty)
        #expect(try reader.moment(id: wanted.id) == wanted)
        #expect(try reader.moment(id: "missing") == nil)
        #expect(throws: (any Error).self) { try reader.save([newer]) }
        #expect(throws: (any Error).self) { _ = try VisualMemoryStore(root: root.appendingPathComponent("absent"), readOnly: true) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
    }

    @Test func dayNavigationCrossesAppsButNotMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        #expect(end.timeIntervalSince(start) == 23 * 3600)
        let a = VisualMemoryItem(kind: .moment, capturedAt: start.addingTimeInterval(60), source: "Safari", bundleID: "safari", path: "a.heic")
        let b = VisualMemoryItem(kind: .moment, capturedAt: start.addingTimeInterval(180), source: "Editor", bundleID: "editor", path: "b.heic")
        let tomorrow = VisualMemoryItem(kind: .moment, capturedAt: end, source: "Tomorrow", path: "c.heic")
        let ordered = VisualMemoryDayTimeline.moments([tomorrow, b, a], on: start, calendar: calendar)
        #expect(ordered.map(\.id) == [a.id, b.id])
        let range = VisualMemoryDayTimeline.captureInterval(in: ordered)
        #expect(range?.start == a.capturedAt)
        #expect(range?.end == b.capturedAt)
        #expect(range?.duration == 120)
        #expect(VisualMemoryDayTimeline.captureInterval(in: [a])?.duration == 1)
        #expect(VisualMemoryDayTimeline.captureInterval(in: [a])?.end == a.capturedAt)
        #expect(VisualMemoryDayTimeline.captureInterval(in: []) == nil)
        #expect(VisualMemoryDayTimeline.nearestIndex(in: ordered, to: start.addingTimeInterval(120)) == 0)
        #expect(VisualMemoryDayTimeline.nearestIndex(in: ordered, to: start.addingTimeInterval(150)) == 1)
        #expect(VisualMemoryDayTimeline.nearestIndex(in: [], to: start) == nil)
    }

    @Test func scrubScaleCompressesOvernightGapsAndPreservesTimes() {
        let start = Date(timeIntervalSince1970: 1000)
        let dates = [0.0, 30, 60, 36_000, 36_030].map { start.addingTimeInterval($0) }
        let scale = VisualMemoryScrubScale(dates: dates)
        #expect(scale.compressesGaps)
        #expect(scale.fraction(for: dates[2]) > 0.25)
        for date in dates {
            #expect(abs(scale.date(at: scale.fraction(for: date))!.timeIntervalSince(date)) < 0.001)
        }
        let insideGap = start.addingTimeInterval(18_000)
        #expect(abs(scale.date(at: scale.fraction(for: insideGap))!.timeIntervalSince(insideGap)) < 0.001)
        #expect(scale.date(at: -1) == dates.first)
        #expect(scale.date(at: 2) == dates.last)
        #expect(VisualMemoryScrubScale(dates: []).date(at: 0.5) == nil)
        #expect(VisualMemoryScrubScale(dates: [start]).date(at: 0.5) == start)
        #expect(!VisualMemoryScrubScale(dates: Array(dates.prefix(3))).compressesGaps)
    }

    @Test func meetingResumeDoesNotOverrideExplicitVideoPause() {
        var state = ScreenRecordingPauseState()
        state.userPaused = true; state.meetingPaused = true
        state.meetingPaused = false
        #expect(state.isPaused)
        state.userPaused = false
        #expect(!state.isPaused)
    }
}
