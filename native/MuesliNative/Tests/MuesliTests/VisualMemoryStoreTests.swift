import Foundation
import CoreGraphics
import Testing
import SQLite3
@testable import MuesliCore

@Suite("Local visual evidence")
struct VisualMemoryStoreTests {
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
