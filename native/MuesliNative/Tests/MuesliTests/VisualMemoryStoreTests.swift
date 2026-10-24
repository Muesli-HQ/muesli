import Foundation
import CoreGraphics
import Testing
import SQLite3
@testable import MuesliCore

@Suite("Local visual evidence")
struct VisualMemoryStoreTests {
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

    @Test func meetingResumeDoesNotOverrideExplicitVideoPause() {
        var state = ScreenRecordingPauseState()
        state.userPaused = true; state.meetingPaused = true
        state.meetingPaused = false
        #expect(state.isPaused)
        state.userPaused = false
        #expect(!state.isPaused)
    }
}
