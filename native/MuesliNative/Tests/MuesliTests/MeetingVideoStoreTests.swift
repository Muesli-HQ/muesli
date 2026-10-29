import Foundation
import SQLite3
import Testing
@testable import MuesliCore

@Suite("Meeting-owned video storage")
struct MeetingVideoStoreTests {
    @Test func migrationPreservesVideoAndLeavesAmbientHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("muesli.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE meetings(id INTEGER PRIMARY KEY, deleted_at REAL); INSERT INTO meetings VALUES(42,NULL)", nil, nil, nil) == SQLITE_OK)
        try MeetingVideoStore.migrate(db: db)
        let legacy = try VisualMemoryStore(root: root.appendingPathComponent("visual-memory"))
        let video = VisualMemoryItem(kind: .meetingVideo, meetingID: 42, source: "Display", path: "clip.mp4", duration: 12, meetingOffset: 5)
        let moment = VisualMemoryItem(kind: .moment, source: "Editor", path: "still.heic")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: legacy.url(for: video.path))
        try legacy.save([video, moment])
        let videos = try MeetingVideoStore(databaseURL: database, root: root.appendingPathComponent("meeting-recordings/videos"))
        try videos.migrateLegacyVideos(from: legacy)
        try videos.migrateLegacyVideos(from: legacy)
        #expect(try videos.items() == [video])
        #expect(try Data(contentsOf: videos.url(for: video.path)) == bytes)
        #expect(try legacy.items() == [moment])
        #expect(!FileManager.default.fileExists(atPath: try legacy.url(for: video.path).path))
        let conflicting = VisualMemoryItem(kind: .meetingVideo, meetingID: 42, source: "Display", path: "conflict.mp4")
        try bytes.write(to: legacy.url(for: conflicting.path))
        try Data([9]).write(to: videos.url(for: conflicting.path))
        try legacy.save([conflicting])
        #expect(throws: (any Error).self) { try videos.migrateLegacyVideos(from: legacy) }
        #expect(try legacy.items().contains(conflicting))
        #expect(try Data(contentsOf: legacy.url(for: conflicting.path)) == bytes)
        let orphan = VisualMemoryItem(kind: .meetingVideo, meetingID: 999, source: "Display", path: "orphan.mp4")
        #expect(throws: (any Error).self) { try videos.save([orphan]) }
        #expect(throws: (any Error).self) { try videos.save([moment]) }
        try videos.delete(ids: [video.id])
        #expect(try videos.items().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try videos.url(for: video.path).path))
    }
    @Test func completedVideoSurvivesDatabaseFailureAndRecovers() throws {
        try withStore { store, db, _ in
            let item = VisualMemoryItem(kind: .meetingVideo, meetingID: 42, source: "Display", path: "recover.mp4")
            let bytes = Data([5, 6, 7])
            try bytes.write(to: store.url(for: item.path))
            #expect(sqlite3_exec(db, "CREATE TRIGGER reject_video BEFORE INSERT ON meeting_video_clips BEGIN SELECT RAISE(ABORT,'injected failure'); END", nil, nil, nil) == SQLITE_OK)
            #expect(throws: (any Error).self) { try store.persistCompleted(item) }
            #expect(try Data(contentsOf: store.url(for: item.path)) == bytes)
            #expect(FileManager.default.fileExists(atPath: try store.url(for: item.path + ".pending.json").path))
            #expect(sqlite3_exec(db, "DROP TRIGGER reject_video", nil, nil, nil) == SQLITE_OK)
            try store.maintain()
            #expect(try store.items() == [item])
            #expect(!FileManager.default.fileExists(atPath: try store.url(for: item.path + ".pending.json").path))
        }
    }

    @Test func deletionJournalSurvivesRollbackAndHardPurge() throws {
        try withStore { store, db, _ in
            let item = VisualMemoryItem(kind: .meetingVideo, meetingID: 42, source: "Display", path: "delete.mp4")
            try Data([1]).write(to: store.url(for: item.path))
            try store.save([item])
            #expect(sqlite3_exec(db, "BEGIN; UPDATE meetings SET deleted_at=1 WHERE id=42; ROLLBACK", nil, nil, nil) == SQLITE_OK)
            try store.maintain()
            #expect(try store.items() == [item])
            #expect(FileManager.default.fileExists(atPath: try store.url(for: item.path).path))
            #expect(sqlite3_exec(db, "UPDATE meetings SET deleted_at=1 WHERE id=42; DELETE FROM meetings WHERE id=42", nil, nil, nil) == SQLITE_OK)
            #expect(try store.items().isEmpty)
            try store.maintain()
            #expect(!FileManager.default.fileExists(atPath: try store.url(for: item.path).path))
        }
    }

    @Test func discardOnlyRemovesCurrentSessionAndPendingJournal() throws {
        try withStore { store, db, _ in
            let old = VisualMemoryItem(kind: .meetingVideo, meetingID: 42, source: "Display", path: "old.mp4")
            let new = VisualMemoryItem(kind: .meetingVideo, meetingID: 42, source: "Display", path: "new.mp4")
            for item in [old, new] { try Data([1]).write(to: store.url(for: item.path)) }
            try store.save([old])
            #expect(sqlite3_exec(db, "CREATE TRIGGER reject_video BEFORE INSERT ON meeting_video_clips BEGIN SELECT RAISE(ABORT,'injected failure'); END", nil, nil, nil) == SQLITE_OK)
            #expect(throws: (any Error).self) { try store.persistCompleted(new) }
            #expect(sqlite3_exec(db, "DROP TRIGGER reject_video", nil, nil, nil) == SQLITE_OK)
            try store.delete(ids: [new.id])
            #expect(try store.items() == [old])
            #expect(FileManager.default.fileExists(atPath: try store.url(for: old.path).path))
            #expect(!FileManager.default.fileExists(atPath: try store.url(for: new.path).path))
            try store.maintain()
            #expect(try store.items() == [old])
        }
    }

    @Test func badLegacyOwnerDoesNotBlockLaterVideos() throws {
        try withStore { store, _, root in
            let legacy = try VisualMemoryStore(root: root.appendingPathComponent("legacy"))
            let bad = VisualMemoryItem(kind: .meetingVideo, meetingID: 999, capturedAt: .distantFuture, source: "Display", path: "bad.mp4")
            let good = VisualMemoryItem(kind: .meetingVideo, meetingID: 42, source: "Display", path: "good.mp4")
            for item in [bad, good] { try Data([1]).write(to: legacy.url(for: item.path)) }
            try legacy.save([bad, good])
            #expect(throws: (any Error).self) { try store.migrateLegacyVideos(from: legacy) }
            #expect(try store.items() == [good])
            #expect(try legacy.items() == [bad])
            #expect(!FileManager.default.fileExists(atPath: try store.url(for: bad.path).path))
        }
    }

    @Test func interruptedCaptureIsOwnedAndRecoveredOnlyAfterFinalization() throws {
        try withStore { store, _, _ in
            let item = VisualMemoryItem(kind: .meetingVideo, meetingID: 42, source: "Display", path: "interrupted.mp4")
            try store.beginRecording(item)
            try Data([1]).write(to: store.url(for: item.path))
            try store.maintain(recoverRecording: { _ in 12 })
            #expect(try store.items().isEmpty) // still writing
            #expect(try store.hasMedia(meetingID: 42))
            store.endRecording(item)
            try store.maintain(recoverRecording: { _ in nil })
            #expect(try store.items().isEmpty) // not playable yet, retain ownership
            try store.maintain(recoverRecording: { _ in 12 })
            #expect(try store.items().first?.duration == 12)
        }
    }

    @Test func discardUnfinishedVideoRetriesRemovalDespiteCorruptJournal() throws {
        try withStore { store, _, _ in
            let item = VisualMemoryItem(kind: .meetingVideo, meetingID: 42, source: "Display", path: "discard.mp4")
            try store.beginRecording(item)
            try Data([1]).write(to: store.url(for: item.path))
            store.endRecording(item)
            try Data("broken".utf8).write(to: store.url(for: "corrupt.pending.json"))
            // A symlink escaping the media root forces removal to fail after journaling.
            let file = try store.url(for: item.path)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/tmp")
            #expect(throws: (any Error).self) { try store.delete(ids: [item.id]) }
            try FileManager.default.removeItem(at: file)
            try Data([1]).write(to: file)
            try store.maintain()
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(!(try store.hasMedia(meetingID: 42)))
        }
    }

    @Test func deletedOwnerCleansUnfinalizedVideo() throws {
        try withStore { store, db, _ in
            let item = VisualMemoryItem(kind: .meetingVideo, meetingID: 42, source: "Display", path: "unfinished.mp4")
            try store.beginRecording(item)
            try Data([1]).write(to: store.url(for: item.path))
            store.endRecording(item)
            #expect(sqlite3_exec(db, "DELETE FROM meetings WHERE id=42", nil, nil, nil) == SQLITE_OK)
            try store.maintain()
            #expect(!FileManager.default.fileExists(atPath: try store.url(for: item.path).path))
        }
    }

    private func withStore(_ body: (MeetingVideoStore, OpaquePointer?, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("muesli.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE meetings(id INTEGER PRIMARY KEY, deleted_at REAL); INSERT INTO meetings VALUES(42,NULL)", nil, nil, nil) == SQLITE_OK)
        try MeetingVideoStore.migrate(db: db)
        try body(MeetingVideoStore(databaseURL: database, root: root.appendingPathComponent("videos")), db, root)
    }

}
