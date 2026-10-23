import Foundation
import Testing
@testable import MuesliCore

@Suite("Local storage usage")
struct LocalStorageUsageTests {
    @Test func categorizesFilesWithoutCountingLinksOrOverlappingRootsTwice() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let models = root.appendingPathComponent("models")
        func write(_ path: String, count: Int) throws -> URL {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 42, count: count).write(to: url)
            return url
        }
        func allocated(_ url: URL) throws -> Int64 {
            let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        let model = try write("models/speech/weights.bin", count: 20_000)
        try FileManager.default.linkItem(at: model, to: models.appendingPathComponent("speech/duplicate.bin"))
        let audio = try write("support/meeting-recordings/audio.m4a", count: 6_000)
        let video = try write("support/meeting-recordings/videos/clip.mp4", count: 9_000)
        let database = try write("support/muesli.db", count: 4_000)
        let wal = try write("support/muesli.db-wal", count: 1_000)
        let waveform = try write("support/waveform-cache/audio.json", count: 100)
        let other = try write("support/config.json", count: 200)
        let outside = try write("private.txt", count: 10_000)
        try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("outside"), withDestinationURL: outside)
        let usage = LocalStorageUsage.scan(support: support, modelRoots: [models, models.appendingPathComponent("speech")])
        #expect(try usage.bytes[.models] == allocated(model))
        #expect(try usage.bytes[.meetingAudio] == allocated(audio))
        #expect(try usage.bytes[.meetingVideo] == allocated(video))
        #expect(try usage.bytes[.database] == allocated(database) + allocated(wal))
        #expect(try usage.bytes[.waveformCache] == allocated(waveform))
        #expect(try usage.bytes[.other] == allocated(other))
        #expect(usage.models.count == 1)
        #expect(usage.unavailableLocations == 0)
    }
    @Test func missingFoldersDoNotGetCreated() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let usage = LocalStorageUsage.scan(support: missing, modelRoots: [missing.appendingPathComponent("models")])
        #expect(usage.totalBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(LocalStorageUsage.category(for: "meeting-recordings/videos/clip.mp4.pending.json") == .other)
    }
}
