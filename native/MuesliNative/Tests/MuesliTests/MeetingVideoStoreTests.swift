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
        #expect(sqlite3_exec(db, "CREATE TABLE meetings(id INTEGER PRIMARY KEY); INSERT INTO meetings VALUES(42)", nil, nil, nil) == SQLITE_OK)
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
}
