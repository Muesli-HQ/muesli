import Foundation
import SQLite3
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

private final class FeedbackStoreFixture {
    let root: URL
    let db: OpaquePointer?
    let store: FeedbackCaptureStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var opened: OpaquePointer?
        do {
            let url = root.appendingPathComponent("muesli.db")
            let database = DictationStore(databaseURL: url)
            try database.migrateIfNeeded()
            try database.migrateIfNeeded() // Every fixture also checks migration idempotence.
            #expect(sqlite3_open(url.path, &opened) == SQLITE_OK)
            store = try FeedbackCaptureStore(databaseURL: url, support: root)
            db = opened
        } catch {
            sqlite3_close(opened)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: root)
    }
}

func withFeedbackStore(_ body: (FeedbackCaptureStore, OpaquePointer?, URL) throws -> Void) throws {
    let fixture = try FeedbackStoreFixture()
    defer { withExtendedLifetime(fixture) {} }
    try body(fixture.store, fixture.db, fixture.root)
}

func feedbackTarget() -> FeedbackCaptureTarget {
    .init(displayId: 42, frame: .init(x: -1920, y: 0, width: 1920, height: 1080, scale: 2), appName: "Fixture Editor")
}

@Suite("Scrawl storage")
struct FeedbackCaptureStoreTests {
    @Test func manifestVersionAndUnknownFields() throws {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.microphoneStartFrame = 32_000; m.videoStartFrame = 36_000; m.alignClocks()
        #expect(m.videoOffsetMs == 250)
        #expect(FeedbackCaptureManifest.milliseconds(frame: 28_000, origin: 32_000) == -250)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        json["laterSlice"] = ["anything": true]
        #expect(try JSONDecoder().decode(FeedbackCaptureManifest.self, from: JSONSerialization.data(withJSONObject: json)) == m)
        json["version"] = 2
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FeedbackCaptureManifest.self, from: JSONSerialization.data(withJSONObject: json)) }
    }
    @Test func malformedFailureRecordsAreSkippedIndividually() throws {
        let manifest = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
        json["failures"] = [
            ["stage": "audio", "message": "input removed"],
            ["stage": "malformed"],
            ["stage": "video", "message": "capture stopped"]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try? JSONDecoder().decode(FeedbackCaptureManifest.self, from: data)
        #expect(decoded?.failures == [
            .init(stage: "audio", message: "input removed"),
            .init(stage: "video", message: "capture stopped")
        ])
    }
    @Test func catalogSkipsUnknownStatesWithoutHidingKnownCaptures() throws {
        try withFeedbackStore { store, db, _ in
            let future = try store.begin(target: feedbackTarget())
            let known = try store.begin(target: feedbackTarget())
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(db, "UPDATE feedback_captures SET state='future_state' WHERE id=?", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement); store.release(id: future.id); store.release(id: known.id) }
            sqlite3_bind_text(statement, 1, (future.id as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            try #require(sqlite3_step(statement) == SQLITE_DONE)
            #expect(try store.list().map(\.id) == [known.id])
            #expect(FileManager.default.fileExists(atPath: try store.bundleURL(id: future.id).path))
        }
    }

    @Test func migrationPathsPermissionsAndDeletion() throws {
        try withFeedbackStore { store, db, root in
            var count: Int32 = 0
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "SELECT count(*) FROM pragma_table_info('feedback_captures')", -1, &statement, nil) == SQLITE_OK)
            if sqlite3_step(statement) == SQLITE_ROW { count = sqlite3_column_int(statement, 0) }
            sqlite3_finalize(statement)
            #expect(count == 7)
            let m = try store.begin(target: feedbackTarget(), now: Date(timeIntervalSince1970: 1000))
            let folder = try store.bundleURL(id: m.id)
            #expect(m.id.hasPrefix("fc-1000000-"))
            #expect((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect(try store.list().first?.id == m.id)
            #expect(try store.get(id: m.id)?.bundlePath == "feedback-captures/\(m.id).capture")
            #expect(throws: (any Error).self) { try store.bundleURL(id: "../escape") }
            #expect(throws: (any Error).self) { try store.mediaURL(id: m.id, path: "../escape") }
            #expect(throws: (any Error).self) { try store.mediaURL(id: m.id, path: "/tmp/escape") }
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("outside"), withDestinationURL: root)
            #expect(throws: (any Error).self) { try store.mediaURL(id: m.id, path: "outside/muesli.db") }
            #expect(throws: (any Error).self) { try store.delete(id: m.id) }
            store.release(id: m.id)
            try store.delete(id: m.id)
            #expect(try store.list().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }
    @Test func checkpointSurvivesCrashBeforeFinishAndRecoveryIsIdempotent() throws {
        try withFeedbackStore { store, _, root in
            var m = try store.begin(target: feedbackTarget())
            m.microphoneStartFrame = 1_000_000; try store.checkpoint(m)
            m.videoStartFrame = 1_008_000; m.alignClocks(); try store.checkpoint(m)
            let wav = try store.mediaURL(id: m.id, path: "narration.wav")
            // Crash leaves a zero data-size header and an incomplete final sample.
            var data = WavWriter.header(dataSize: 0)
            data.append(Data(repeating: 1, count: 32_001)); try data.write(to: wav)
            try Data([1]).write(to: store.mediaURL(id: m.id, path: "recording.mp4"))
            try store.recover(audioDuration: WavWriter.repairIncrementalWAV, videoDuration: { _ in 800 })
            #expect(try store.get(id: m.id)?.state == .recording) // still owned
            store.release(id: m.id)
            let relaunched = try FeedbackCaptureStore(databaseURL: root.appendingPathComponent("muesli.db"), support: root)
            try relaunched.recover(audioDuration: WavWriter.repairIncrementalWAV, videoDuration: { _ in 800 })
            let recovered = try relaunched.manifest(id: m.id)
            #expect(recovered.state == .recovered)
            #expect(recovered.microphoneStartFrame == 1_000_000)
            #expect(recovered.videoOffsetMs == 500)
            #expect(recovered.durationMs == 1300)
            #expect(recovered.audio == "narration.wav" && recovered.video == "recording.mp4")
            #expect(try WavReader.readFloatMonoWAV(from: wav).samples.count == 16_000)
            #expect(try Data(contentsOf: wav).count == 32_044)
            try relaunched.recover(audioDuration: { _ in Issue.record("Completed audio probed again"); return nil }, videoDuration: { _ in nil })
            #expect(try relaunched.manifest(id: m.id) == recovered)
            #expect(!FileManager.default.fileExists(atPath: try relaunched.mediaURL(id: m.id, path: "unfinished.json").path))
        }
    }
    @Test func publicationFailureKeepsJournalAndPartialMedia() throws {
        try withFeedbackStore { store, db, _ in
            var m = try store.begin(target: feedbackTarget())
            try WavWriter.writeWAV(samples: [Float](repeating: 0, count: 1600), to: store.mediaURL(id: m.id, path: "narration.wav"))
            m.audio = "narration.wav"; m.state = .ready
            #expect(sqlite3_exec(db, "CREATE TRIGGER reject_feedback BEFORE INSERT ON feedback_captures BEGIN SELECT RAISE(ABORT,'fixture'); END", nil, nil, nil) == SQLITE_OK)
            #expect(throws: (any Error).self) { try store.publish(m) }
            #expect(FileManager.default.fileExists(atPath: try store.mediaURL(id: m.id, path: "unfinished.json").path))
            #expect(sqlite3_exec(db, "DROP TRIGGER reject_feedback", nil, nil, nil) == SQLITE_OK)
            store.release(id: m.id)
            try store.recover(audioDuration: WavWriter.repairIncrementalWAV, videoDuration: { _ in nil })
            #expect(try store.get(id: m.id)?.state == .recovered)
            #expect(try store.manifest(id: m.id).audio == "narration.wav")
        }
    }
    @Test func emptyInterruptedBundlesAreRemoved() throws {
        try withFeedbackStore { store, _, _ in
            let empty = try store.begin(target: feedbackTarget())
            store.release(id: empty.id)
            let orphan = try store.bundleURL(id: "fc-1-abcd")
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
            let disposable = try store.begin(target: feedbackTarget())
            try JSONEncoder().encode(disposable).write(to: store.mediaURL(id: disposable.id, path: "capture.json"))
            try Data().write(to: store.mediaURL(id: disposable.id, path: ".empty"))
            try Data().write(to: store.mediaURL(id: disposable.id, path: "recording.mp4"))
            try WavWriter.header(dataSize: 0).write(to: store.mediaURL(id: disposable.id, path: "narration.wav"))
            store.release(id: disposable.id)
            do { try store.recover(audioDuration: { _ in nil }, videoDuration: { _ in nil }) }
            catch { Issue.record("Entirely empty orphan must recover without error: \(error)") }
            #expect(try store.get(id: empty.id) == nil)
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            #expect(!FileManager.default.fileExists(atPath: try store.bundleURL(id: disposable.id).path))
            var uncertain: [(String, URL, Data)] = []
            for kind in ["unknown", ".hidden", "directory", "symlink", "unreadable"] {
                let m = try store.begin(target: feedbackTarget())
                let entry = try store.mediaURL(id: m.id, path: kind)
                let bytes = Data([9, 8, 7])
                if kind == "directory" { try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false) }
                else if kind == "symlink" { try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: "absent") }
                else {
                    try bytes.write(to: entry)
                    if kind == "unreadable" { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: entry.path) }
                }
                let journal = try store.mediaURL(id: m.id, path: "unfinished.json")
                uncertain.append((m.id, entry, try Data(contentsOf: journal)))
                store.release(id: m.id)
            }
            var unsupported = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as? [String: Any])
            unsupported["version"] = 2
            let negatives: [(String, String, Data)] = [
                ("fc-2-abcd", "unfinished.json", Data("bad json".utf8)),
                ("fc-3-abcd", "unfinished.json", try JSONSerialization.data(withJSONObject: unsupported)),
                ("fc-4-abcd", "recording.mp4", Data([1])),
                ("fc-5-abcd", ".unknown", Data([2]))]
            for (id, name, data) in negatives {
                let folder = try store.bundleURL(id: id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                try data.write(to: folder.appendingPathComponent(name))
            }
            let unreadable = try store.bundleURL(id: "fc-6-abcd")
            try Data([3]).write(to: unreadable) // Cannot enumerate a file as a directory.
            let neighbor = try store.begin(target: feedbackTarget())
            try Data([4]).write(to: store.mediaURL(id: neighbor.id, path: "recording.mp4"))
            store.release(id: neighbor.id)
            for _ in 0..<2 {
                #expect(throws: (any Error).self) { try store.recover(audioDuration: { _ in nil }, videoDuration: {
                    FileManager.default.fileExists(atPath: $0.path) ? 750 : nil
                }) }
                #expect(try store.manifest(id: neighbor.id).state == .recovered)
                for (id, entry, journal) in uncertain {
                    #expect((try? Data(contentsOf: store.mediaURL(id: id, path: "unfinished.json"))) == journal)
                    #expect((try? store.get(id: id)?.state) == .recording, "Uncertain contents must not be published as success")
                    let type = try? FileManager.default.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType
                    if entry.lastPathComponent == "directory" { #expect(type == .typeDirectory) }
                    else if entry.lastPathComponent == "symlink" { #expect(type == .typeSymbolicLink) }
                    else {
                        if entry.lastPathComponent == "unreadable" { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.path) }
                        #expect((try? Data(contentsOf: entry)) == Data([9, 8, 7]))
                    }
                }
                for (id, name, data) in negatives {
                    #expect(try Data(contentsOf: store.mediaURL(id: id, path: name)) == data)
                }
                #expect(try Data(contentsOf: unreadable) == Data([3]))
            }
        }
    }
    @Test("Finish and recovery report unavailable media independently", arguments: [false, true], ["throw", "audio", "video", "written"])
    func independentMediaReconciliation(recover: Bool, unavailable: String) throws {
        try withFeedbackStore { store, _, _ in
            var m = try store.begin(target: feedbackTarget())
            if unavailable == "written" { m.audio = "narration.wav"; m.video = "recording.mp4"; try store.checkpoint(m) }
            try Data([1, 2, 3]).write(to: store.mediaURL(id: m.id, path: "narration.wav"))
            try Data([4, 5]).write(to: store.mediaURL(id: m.id, path: "recording.mp4"))
            var videoProbed = false
            let audio: (URL) throws -> Int64? = { _ in
                if unavailable == "throw" { throw ScreenVideoRecorder.error("Unreadable WAV") }
                return unavailable == "audio" || unavailable == "written" ? nil : 750
            }
            let video: (URL) throws -> Int64? = { _ in
                videoProbed = true; return unavailable == "video" || unavailable == "written" ? nil : 750
            }
            if recover {
                store.release(id: m.id)
                try store.recover(audioDuration: audio, videoDuration: video)
            } else {
                let result = store.reconcileMedia(m, audioDuration: audio, videoDuration: video)
                #expect(result.retainsContent)
                try store.publish(result.manifest)
                store.release(id: m.id)
            }
            let result = try store.manifest(id: m.id)
            #expect(videoProbed)
            #expect((result.audio != nil) == (unavailable == "video" || unavailable == "written"))
            #expect((result.video != nil) == (unavailable != "video"))
            #expect(result.durationMs == (unavailable == "written" ? 0 : 750))
            for stage in ["audio", "video"] {
                #expect(result.failures.contains { $0.stage == stage } == (unavailable == stage || (unavailable == "throw" && stage == "audio")))
            }
            #expect(try Data(contentsOf: store.mediaURL(id: m.id, path: "narration.wav")) == Data([1, 2, 3]))
            #expect(try Data(contentsOf: store.mediaURL(id: m.id, path: "recording.mp4")) == Data([4, 5]))
        }
    }
    @Test func uncertainUnplayableFilesAreRetained() throws {
        try withFeedbackStore { store, _, _ in
            let m = try store.begin(target: feedbackTarget())
            try Data([1, 2, 3]).write(to: store.mediaURL(id: m.id, path: "recording.mp4"))
            store.release(id: m.id)
            try store.recover(audioDuration: { _ in nil }, videoDuration: { _ in nil })
            #expect(try store.get(id: m.id)?.state == .recovered)
            #expect(FileManager.default.fileExists(atPath: try store.mediaURL(id: m.id, path: "recording.mp4").path))
        }
    }
    @Test func failedFileDeletionKeepsTheRow() throws {
        try withFeedbackStore { store, _, _ in
            let m = try store.begin(target: feedbackTarget())
            store.release(id: m.id)
            let folder = try store.bundleURL(id: m.id)
            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: folder.path) }
            #expect(throws: (any Error).self) { try store.delete(id: m.id) }
            #expect(try store.get(id: m.id) != nil)
        }
    }
}

func withFeedbackStoreAsync(_ body: (FeedbackCaptureStore, URL) async throws -> Void) async throws {
    let fixture = try FeedbackStoreFixture()
    defer { withExtendedLifetime(fixture) {} }
    try await body(fixture.store, fixture.root)
}
