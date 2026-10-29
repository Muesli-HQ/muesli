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
    @Test func survivingEventsEnterRecoveryWithoutPlayableMedia() throws {
        try withFeedbackStore { store, _, _ in
            let m = try store.begin(target: feedbackTarget())
            let log = Data("{\"kind\":\"click\",\"t\":1200,\"x\":0.5,\"y\":0.25,\"button\":0}\n".utf8)
            try log.write(to: store.mediaURL(id: m.id, path: "events.jsonl"))
            store.release(id: m.id)
            var errors: [String] = []
            let pending = try store.recover(audioDuration: { _ in nil }, videoDuration: { _ in nil }) {
                errors.append($1.localizedDescription)
            }
            #expect(errors.isEmpty)
            #expect(pending.map(\.id) == [m.id])
            #expect(pending.first?.durationMs == 1200)
            #expect(store.isActive(id: m.id))
            #expect(try Data(contentsOf: store.mediaURL(id: m.id, path: "events.jsonl")) == log)
        }
    }
    @Test func versionOneContextFieldsSurviveRoundTrip() throws {
        let m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        json["events"] = [["kind": "click", "t": 100, "x": 0.5, "y": 0.25, "button": 0]]
        json["inputGaps"] = [["t0": 50, "t1": 75]]
        json["keyframes"] = [["index": 1, "t": 350, "reason": "click", "file": "frames/frame-01.png",
            "eventIndex": 0, "said": "Open this.", "saidRange": ["from": 0, "to": 2]]]
        json["contactSheet"] = "contact-sheet.png"
        let decoded = try JSONDecoder().decode(FeedbackCaptureManifest.self, from: JSONSerialization.data(withJSONObject: json))
        let output = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        for key in ["events", "inputGaps", "keyframes", "contactSheet"] {
            #expect(NSDictionary(dictionary: [key: json[key]!]).isEqual(to: [key: output[key] as Any]), "Lost \(key)")
        }
    }
    @Test func truncatedEventTailPreservesCompleteRecordsAndNamesFailure() throws {
        try withFeedbackStore { store, _, _ in
            let m = try store.begin(target: feedbackTarget())
            let usable: [FeedbackCaptureEvent] = [
                .scroll(t: 2000, x: 0.2, y: 0.4, dx: 1e308, dy: 3),
                .scroll(t: 2100, x: 0.2, y: 0.4, dx: 1e308, dy: 3),
                .click(t: 3000, x: 0.7, y: 0.8, button: 1)
            ]
            let unsafe = FeedbackCaptureEvent.click(t: Int64.max, x: 0.5, y: 0.5, button: 0)
            var log = Data()
            for event in [usable[0], unsafe, usable[1], usable[2]] {
                log.append(try JSONEncoder().encode(event)); log.append(10)
            }
            log.append(Data("{\"kind\":\"click\"".utf8))
            try log.write(to: store.mediaURL(id: m.id, path: "events.jsonl"))
            store.release(id: m.id)
            let pending = try store.recover(audioDuration: { _ in nil }, videoDuration: { _ in nil })
            let result = try #require(pending.first)
            #expect(result.durationMs == 3000 && result.events == usable)
            #expect(result.failures.contains { $0.stage == "events" && $0.message.contains("record 2") })
            #expect(result.failures.contains { $0.stage == "events" && $0.message.localizedCaseInsensitiveContains("truncated") })
            #expect(try store.manifest(id: m.id) == result)
            #expect(result.version == 1)
            #expect(try JSONDecoder().decode(FeedbackCaptureManifest.self, from: JSONEncoder().encode(result)) == result)
            #expect(try Data(contentsOf: store.mediaURL(id: m.id, path: "events.jsonl")) == log)
        }
    }
    @Test func contextPathsAreContainedAndKeyframeProjectionMatchesManifest() throws {
        try withFeedbackStore { store, db, _ in
            var m = try store.begin(target: feedbackTarget())
            m.events = [.click(t: 800, x: 0.5, y: 0.5, button: 0)]
            m.keyframes = [.init(index: 1, t: 1000, reason: "click", file: "frames/frame-01.png", eventIndex: 0,
                said: "", saidRange: .init(from: 0, to: 0))]
            m.contactSheet = "contact-sheet.png"
            try store.save(m)
            var statement: OpaquePointer?
            #expect(sqlite3_prepare_v2(db, "SELECT body FROM feedback_captures", -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            #expect(sqlite3_step(statement) == SQLITE_ROW)
            let data = Data(String(cString: sqlite3_column_text(statement, 0)).utf8)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["keyframeCount"] as? Int == 1)
            m.contactSheet = "../escape.png"
            #expect(throws: (any Error).self) { try store.save(m) }
            m.contactSheet = nil
            m.keyframes[0].file = "/tmp/escape.png"
            #expect(throws: (any Error).self) { try store.publish(m) }
            m.keyframes[0].file = "frames/frame-01.png"
            m.state = .processing
            let final = store.reconcileMedia(m, audioDuration: { _ in nil }, videoDuration: { _ in nil })
            #expect(final.retainsContent && final.manifest.durationMs == 800)
        }
    }
    @Test func manifestVersionAndUnknownFields() throws {
        var m = FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget())
        m.microphoneStartFrame = 32_000; m.videoStartFrame = 36_000; m.alignClocks()
        #expect(m.videoOffsetMs == 250)
        #expect(FeedbackCaptureManifest.milliseconds(frame: 28_000, origin: 32_000) == -250)
        let legacy = Data(#"{"version":1,"id":"fc-1000-abcd","createdAtMs":1000,"durationMs":0,"state":"recording","target":{"mode":"display","displayId":42,"frame":{"x":-1920,"y":0,"width":1920,"height":1080,"scale":2},"appName":"Fixture Editor"},"failures":[]}"#.utf8)
        let old = try JSONDecoder().decode(FeedbackCaptureManifest.self, from: legacy)
        #expect(old == FeedbackCaptureManifest(id: "fc-1000-abcd", createdAtMs: 1000, target: feedbackTarget()))
        #expect(old.transcript == nil)
        m.transcript = .init(source: "fluidaudio", model: "fixture", text: "Open this.",
            words: [.init(t0: 50, t1: 500, text: "Open"), .init(t0: 600, t1: 950, text: "this.")],
            segments: [.init(t0: 50, t1: 950, text: "Open this.")], estimated: false)
        #expect(try JSONDecoder().decode(FeedbackCaptureManifest.self, from: JSONEncoder().encode(m)) == m)
        m.transcript = .unavailable("no on-device speech model installed")
        #expect(try JSONDecoder().decode(FeedbackCaptureManifest.self, from: JSONEncoder().encode(m)) == m)
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
    @Test func malformedS3SidecarsDoNotBlockInterruptedRecovery() throws {
        try withFeedbackStore { store, _, _ in
            let manifest = try store.begin(target: feedbackTarget())
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
            json["events"] = [["kind": "futureGesture", "t": 100, "x": 0.5, "y": 0.5]]
            json["inputGaps"] = [["t0": 50, "t1": 75], ["t0": "malformed", "t1": 100], ["t0": 200, "t1": 250]]
            json["keyframes"] = [["index": 1, "t": "malformed", "reason": "click", "file": "frames/frame-01.png",
                "said": "", "saidRange": ["from": 0, "to": 0]]]
            json["contactSheet"] = ["malformed"]
            try JSONSerialization.data(withJSONObject: json).write(to: store.mediaURL(id: manifest.id, path: "unfinished.json"))
            let eventLog = Data("{\"kind\":\"click\",\"t\":300,\"x\":0.25,\"y\":0.75,\"button\":0}\n".utf8)
            try eventLog.write(to: store.mediaURL(id: manifest.id, path: "events.jsonl"))
            try Data([0]).write(to: store.mediaURL(id: manifest.id, path: "recording.mp4"))
            store.release(id: manifest.id)

            var errors: [String] = []
            let recovered = try store.recover(audioDuration: { _ in nil }, videoDuration: { _ in 500 }) {
                errors.append($1.localizedDescription)
            }
            #expect(errors.isEmpty)
            let result = try #require(recovered.first)
            #expect(result.id == manifest.id)
            #expect(result.events == [.click(t: 300, x: 0.25, y: 0.75, button: 0)])
            #expect(result.inputGaps == [.init(t0: 50, t1: 75), .init(t0: 200, t1: 250)])
            #expect(result.keyframes.isEmpty)
            #expect(result.contactSheet == nil)
            #expect(store.isActive(id: manifest.id))
        }
    }
    @Test func malformedInkSidecarsDoNotHideRetainedVideo() throws {
        try withFeedbackStore { store, _, _ in
            let manifest = try store.begin(target: feedbackTarget())
            var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
            json["strokes"] = ["malformed"]
            json["marks"] = ["malformed"]
            json["video"] = "recording.mp4"
            try JSONSerialization.data(withJSONObject: json).write(to: store.mediaURL(id: manifest.id, path: "unfinished.json"))
            try Data([0]).write(to: store.mediaURL(id: manifest.id, path: "recording.mp4"))
            store.release(id: manifest.id)

            var errors: [String] = []
            let recovered = try store.recover(audioDuration: { _ in nil }, videoDuration: { _ in 500 }) {
                errors.append($1.localizedDescription)
            }
            #expect(errors.isEmpty)
            #expect(recovered.map(\.id) == [manifest.id])
            #expect(recovered.first?.video == "recording.mp4")
            #expect(recovered.first?.strokes.isEmpty == true)
            #expect(recovered.first?.marks.isEmpty == true)
            #expect(try store.list().map(\.id) == [manifest.id])
            #expect(FileManager.default.fileExists(atPath: try store.mediaURL(id: manifest.id, path: "recording.mp4").path))
        }
    }
    @Test func recoveryMergesSavedAndReplayedInputGapsWithoutDuplicates() throws {
        try withFeedbackStore { store, _, _ in
            var manifest = try store.begin(target: feedbackTarget())
            let savedGaps = [FeedbackCaptureInputGap(t0: 50, t1: 75), .init(t0: 200, t1: 250)]
            manifest.inputGaps = savedGaps

            let records: [FeedbackCaptureJournalRecord] = [
                .gap(t: 50, unavailable: true), .gap(t: 75, unavailable: false),
                .gap(t: 50, unavailable: true), .gap(t: 75, unavailable: false),
                .gap(t: 300, unavailable: true), .gap(t: 325, unavailable: false)
            ]
            var eventLog = Data()
            for record in records {
                eventLog.append(try JSONEncoder().encode(record))
                eventLog.append(10)
            }
            try eventLog.write(to: store.mediaURL(id: manifest.id, path: "events.jsonl"))

            let recovered = store.reconcileMedia(manifest, audioDuration: { _ in nil }, videoDuration: { _ in nil })
            #expect(recovered.manifest.inputGaps == [
                .init(t0: 50, t1: 75), .init(t0: 200, t1: 250), .init(t0: 300, t1: 325)
            ])
        }
    }
    @Test func recoveryKeepsSavedMarkGroupsAndFrameLinks() throws {
        try withFeedbackStore { store, _, _ in
            var manifest = try store.begin(target: feedbackTarget())
            manifest.strokes = [
                .init(t0: 100, t1: 200, fw: 1920, fh: 1080, pts: [1000, 1000, 0, 2000, 2000, 100]),
                .init(t0: 400, t1: 500, fw: 1920, fh: 1080, pts: [7000, 1000, 0, 8000, 2000, 100])
            ]
            let savedMarks = [
                FeedbackCaptureMark(id: "m1", strokes: [0], t0: 100, t1: 200, boxNorm: [0.1, 0.1, 0.2, 0.2],
                    pin: nil, description: "mark on first page", frame: "frames/frame-01.png"),
                FeedbackCaptureMark(id: "m2", strokes: [1], t0: 400, t1: 500, boxNorm: [0.7, 0.1, 0.8, 0.2],
                    pin: nil, description: "mark on second page", frame: "frames/frame-02.png")
            ]
            manifest.marks = savedMarks
            manifest.keyframes = [
                .init(index: 1, t: 200, reason: "mark", file: "frames/frame-01.png", markId: "m1", said: "", saidRange: .init(from: 0, to: 0)),
                .init(index: 2, t: 500, reason: "mark", file: "frames/frame-02.png", markId: "m2", said: "", saidRange: .init(from: 0, to: 0))
            ]

            let recovered = store.reconcileMedia(manifest, audioDuration: { _ in nil }, videoDuration: { _ in nil })

            #expect(recovered.manifest.marks == savedMarks)
            #expect(recovered.manifest.keyframes.map(\.file) == ["frames/frame-01.png", "frames/frame-02.png"])
        }
    }
    @Test func recoveryDoesNotDuplicateSynthesizedOpenInputGapAcrossRetries() throws {
        try withFeedbackStore { store, _, _ in
            var manifest = try store.begin(target: feedbackTarget())
            manifest.durationMs = 325

            var eventLog = Data()
            eventLog.append(try JSONEncoder().encode(FeedbackCaptureJournalRecord.gap(t: 300, unavailable: true)))
            eventLog.append(10)
            try eventLog.write(to: store.mediaURL(id: manifest.id, path: "events.jsonl"))

            let expectedGaps = [FeedbackCaptureInputGap(t0: 300, t1: 325)]
            let firstRecovery = store.reconcileMedia(manifest, audioDuration: { _ in nil }, videoDuration: { _ in nil })
            #expect(firstRecovery.manifest.inputGaps == expectedGaps)

            try store.checkpoint(firstRecovery.manifest)
            let persistedRecovery = try store.manifest(id: manifest.id)
            let secondRecovery = store.reconcileMedia(persistedRecovery, audioDuration: { _ in nil }, videoDuration: { _ in nil })
            #expect(secondRecovery.manifest.inputGaps == expectedGaps)
        }
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
    @Test @MainActor func checkpointSurvivesCrashBeforeFinishAndRecoveryIsIdempotent() async throws {
        try await withFeedbackStoreAsync { store, root in
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
            let repaired = try relaunched.recover(audioDuration: WavWriter.repairIncrementalWAV, videoDuration: { _ in 800 })
            #expect(repaired.count == 1)
            #expect(try relaunched.get(id: m.id)?.state == .processing)
            #expect(FileManager.default.fileExists(atPath: try relaunched.mediaURL(id: m.id, path: "unfinished.json").path))
            #expect(throws: (any Error).self) { try relaunched.delete(id: m.id) }
            #expect(try relaunched.recover(audioDuration: { _ in Issue.record("Owned recovery was repaired again"); return nil }, videoDuration: { _ in nil }).isEmpty)
            let stage = FeedbackCaptureFinalizer.transcriptionStage { _ in
                // Store access during inference must not hold the recovery lock.
                let records = try await Task.detached { try relaunched.list() }.value
                #expect(records.first?.state == .processing)
                return .init(source: "fixture", text: "recovered narration",
                    words: FeedbackCaptureTranscript.estimatedWords("recovered narration", t0: 0, t1: 1000),
                    segments: [.init(t0: 0, t1: 1000, text: "recovered narration")], estimated: true)
            }
            let result = try await FeedbackCaptureFinalizer(stages: [stage]).finish(try #require(repaired.first),
                context: .init(store: relaunched, finishPasteboardChangeCount: 0), completionState: .recovered)
            relaunched.release(id: m.id)
            #expect(result.transcript?.text == "recovered narration")
            #expect(try relaunched.get(id: m.id)?.title == "recovered narration")
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
            for var item in try store.recover(audioDuration: WavWriter.repairIncrementalWAV, videoDuration: { _ in nil }) {
                item.state = .recovered; try store.publish(item); store.release(id: item.id)
            }
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
            var errors: [String] = []
            try store.recover(audioDuration: { _ in nil }, videoDuration: { _ in nil }) { id, _ in errors.append(id) }
            #expect(errors.isEmpty)
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
            for pass in 0..<2 {
                errors.removeAll()
                let pending = try store.recover(audioDuration: { _ in nil }, videoDuration: {
                    FileManager.default.fileExists(atPath: $0.path) ? 750 : nil
                }) { id, _ in errors.append(id) }
                #expect(errors.count == negatives.count + uncertain.count + 1)
                #expect(Set(errors) == Set(negatives.map { $0.0 } + uncertain.map { $0.0 } + ["fc-6-abcd"]))
                #expect(pending.map(\.id) == (pass == 0 ? [neighbor.id] : []))
                for var item in pending { item.state = .recovered; try store.publish(item); store.release(id: item.id) }
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
                for var item in try store.recover(audioDuration: audio, videoDuration: video) {
                    item.state = .recovered; try store.publish(item); store.release(id: item.id)
                }
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
            #expect(try store.get(id: m.id)?.state == .processing)
            #expect(FileManager.default.fileExists(atPath: try store.mediaURL(id: m.id, path: "recording.mp4").path))
        }
    }
    @Test func probeFailureDoesNotReleaseHealthyPendingRecovery() throws {
        try withFeedbackStore { store, _, _ in
            let broken = try store.begin(target: feedbackTarget())
            let healthy = try store.begin(target: feedbackTarget())
            for capture in [broken, healthy] {
                try WavWriter.writeWAV(samples: [Float](repeating: 0, count: 16_000),
                    to: store.mediaURL(id: capture.id, path: "narration.wav"))
            }
            store.release(id: broken.id); store.release(id: healthy.id)
            var errors: [String] = []
            let pending = try store.recover(audioDuration: { url in
                if url.deletingLastPathComponent().lastPathComponent == "\(broken.id).capture" {
                    throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "unreadable audio"])
                }
                return 1000
            }, videoDuration: { _ in nil }) { id, error in
                errors.append("\(id): \(error.localizedDescription)")
            }
            #expect(errors.isEmpty)
            #expect(Set(pending.map(\.id)) == Set([healthy.id, broken.id]))
            let brokenManifest = try #require(pending.first { $0.id == broken.id })
            #expect(brokenManifest.failures.contains { $0.stage == "audio" && $0.message == "unreadable audio" })
            #expect(throws: (any Error).self) { try store.delete(id: broken.id) }
            #expect(throws: (any Error).self) { try store.delete(id: healthy.id) }
            #expect(FileManager.default.fileExists(atPath: try store.mediaURL(id: healthy.id, path: "unfinished.json").path))
            #expect(FileManager.default.fileExists(atPath: try store.mediaURL(id: broken.id, path: "unfinished.json").path))
            var complete = try #require(pending.first { $0.id == healthy.id })
            complete.state = .recovered
            try store.publish(complete)
            store.release(id: complete.id)
            #expect(try store.get(id: healthy.id)?.state == .recovered)
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
