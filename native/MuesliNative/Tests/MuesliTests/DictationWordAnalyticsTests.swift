import Foundation
import Testing
import SQLite3
import MuesliCore
@testable import MuesliNativeApp

@Suite("Dictation word analytics")
struct DictationWordAnalyticsTests {
    @Test func baselineThenDailyDeltaAndRelaunch() throws {
        var state = DictationWordState(consent: "legacy", day: 10)
        #expect(state.baseline(words: 42_000, token: "legacy") == .init(kind: .baseline, words: 42_000))
        state.add(850, capturedToken: "legacy", currentToken: "legacy")
        #expect(state.flush(today: 10, token: "legacy") == nil)
        state = try JSONDecoder().decode(DictationWordState.self, from: JSONEncoder().encode(state))
        #expect(state.baseline(words: 42_850, token: "legacy") == nil)
        #expect(state.flush(today: 11, token: "legacy") == .init(kind: .daily, words: 850))
        #expect(state.flush(today: 12, token: "legacy") == nil)
    }
    @Test func disabledPeriodNeverBackfillsOrReplays() {
        var state = DictationWordState(consent: "legacy", day: 10)
        _ = state.baseline(words: 100, token: "legacy")
        state.add(50, capturedToken: "legacy", currentToken: "legacy")
        state.reconcile(token: nil)
        state.add(500, capturedToken: nil, currentToken: nil)
        state.reconcile(token: "new")
        state.add(70, capturedToken: "legacy", currentToken: "new")
        #expect(state.baseline(words: 1000, token: "new") == nil)
        #expect(state.flush(today: 11, token: "new") == nil)
        state.add(20, capturedToken: "new", currentToken: "new")
        #expect(state.flush(today: 12, token: "new") == .init(kind: .daily, words: 20))
    }
    @Test func firstLaunchDisabledOrPreviouslyOptedOutSuppressesBaseline() {
        for token: String? in [nil, "rotated"] {
            var state = DictationWordState(consent: token, day: 1)
            #expect(state.baseline(words: 1000, token: token) == nil)
            #expect(state.baseline(words: 1000, token: "enabled") == nil)
        }
    }
    @Test func missedDaysClockRollbackAndInvalidCounts() {
        var state = DictationWordState(consent: "legacy", day: 10)
        state.add(100, capturedToken: "legacy", currentToken: "legacy")
        state.add(-100, capturedToken: "legacy", currentToken: "legacy")
        #expect(state.flush(today: 9, token: "legacy") == nil)
        #expect(state.flush(today: 20, token: "legacy")?.words == 100)
        #expect(state.flush(today: 21, token: "legacy") == nil)
    }

    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var batches: [DictationWordBatch] = []
        var words: [Int] = []
        func batch(_ value: DictationWordBatch) { lock.withLock { batches.append(value) } }
        func saved(_ count: Int) { lock.withLock { words.append(count) } }
    }
    private func fixture() throws -> (URL, DictationStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DictationStore(databaseURL: dir.appendingPathComponent("test.db"))
        try store.migrateIfNeeded()
        return (dir, store)
    }
    @Test func baselineExcludesAmbiguousSyncedDeletedAndOtherActivities() throws {
        let (dir, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = Recorder()
        store.onLocalDictationWords = { _, count in recorder.saved(count) }
        for source in ["dictation", "dictation", "dictation", "computer_use", "ios"] {
            _ = try store.insertDictation(text: "two words", durationSeconds: 1, source: source,
                                         startedAt: Date(), endedAt: Date())
        }
        // Synthetic data only: row 2 represents a cloud-imported row with unknown
        // origin; row 3 a removed history entry. Neither contributes a baseline.
        var db: OpaquePointer?
        #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE dictations SET cloud_record_name='synthetic-cloud' WHERE id=2; UPDATE dictations SET deleted_at=1 WHERE id=3", nil, nil, nil) == SQLITE_OK)
        let snapshot = try store.localDictationWordBaseline()
        #expect(snapshot.lastID == 5)
        #expect(snapshot.words == 2)
        #expect(recorder.words == [2, 2, 2])
    }
    @Test func workerPersistsBaselineOnceAndDoesNotCountSnapshotTwice() throws {
        let (dir, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try store.insertDictation(text: "two words", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        let recorder = Recorder()
        let stateURL = dir.appendingPathComponent("counts.json")
        let worker = DictationWordAnalytics(token: { "legacy" }, sink: { batch, _ in recorder.batch(batch) })
        worker.start(databaseURL: store.resolvedDatabaseURL, stateURL: stateURL)
        worker.record(id: id, words: 2)
        worker.drain()
        #expect(recorder.batches == [.init(kind: .baseline, words: 2)])
        worker.record(id: id + 1, words: 3)
        worker.drain()
        let saved = try JSONDecoder().decode(DictationWordState.self, from: Data(contentsOf: stateURL))
        #expect(saved.pending == 3)
        let next = DictationWordAnalytics(token: { "legacy" }, sink: { batch, _ in recorder.batch(batch) })
        // Daily counting after the baseline must work without opening the history database.
        next.start(databaseURL: dir.appendingPathComponent("absent.db"), stateURL: stateURL)
        next.record(id: id + 2, words: 4)
        next.drain()
        #expect(recorder.batches.count == 1)
        #expect(try JSONDecoder().decode(DictationWordState.self, from: Data(contentsOf: stateURL)).pending == 7)
    }
    @Test func concurrentStartupSnapshotAndSavesHaveNoOverlap() throws {
        let (dir, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = Recorder()
        let url = dir.appendingPathComponent("counts.json")
        let worker = DictationWordAnalytics(token: { "legacy" }, sink: { batch, _ in recorder.batch(batch) })
        worker.start(databaseURL: store.resolvedDatabaseURL, stateURL: url)
        store.onLocalDictationWords = { id, count in worker.record(id: id, words: count) }
        for _ in 0..<20 {
            _ = try store.insertDictation(text: "two words", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        }
        worker.drain()
        let checkpoint = try JSONDecoder().decode(DictationWordState.self, from: Data(contentsOf: url))
        #expect(recorder.batches.reduce(0) { $0 + $1.words } + checkpoint.pending == 40)
    }
    @Test func failedInsertDoesNotNotifyObserver() throws {
        let (dir, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let readOnly = DictationStore(databaseURL: store.resolvedDatabaseURL, readOnly: true)
        let recorder = Recorder()
        readOnly.onLocalDictationWords = { _, count in recorder.saved(count) }
        #expect(throws: (any Error).self) {
            try readOnly.insertDictation(text: "two words", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        }
        #expect(recorder.words.isEmpty)
    }
    @Test func corruptCheckpointFailsClosed() throws {
        let (dir, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.insertDictation(text: "two words", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        let url = dir.appendingPathComponent("counts.json")
        try Data("invalid".utf8).write(to: url)
        let recorder = Recorder()
        let worker = DictationWordAnalytics(token: { "legacy" }, sink: { batch, _ in recorder.batch(batch) })
        worker.start(databaseURL: store.resolvedDatabaseURL, stateURL: url)
        worker.drain()
        #expect(recorder.batches.isEmpty)
    }
    @Test func blockedUploadDoesNotBlockRecordingCaller() throws {
        let (dir, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.insertDictation(text: "two words", durationSeconds: 1, startedAt: Date(), endedAt: Date())
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let worker = DictationWordAnalytics(token: { "legacy" }, sink: { _, _ in entered.signal(); release.wait() })
        worker.start(databaseURL: store.resolvedDatabaseURL, stateURL: dir.appendingPathComponent("counts.json"))
        #expect(entered.wait(timeout: .now() + 5) == .success)
        defer { release.signal(); worker.drain() }
        let start = ContinuousClock.now
        var samples: [Double] = []
        for id in 2...1001 {
            let before = DispatchTime.now().uptimeNanoseconds
            worker.record(id: Int64(id), words: 10)
            if id <= 201 { samples.append(Double(DispatchTime.now().uptimeNanoseconds - before) / 1000) }
        }
        samples.sort()
        print("Word analytics admitted-call p95: \(samples[Int(Double(samples.count - 1) * 0.95)]) microseconds")
        let elapsed = start.duration(to: .now)
        #expect(elapsed < .milliseconds(500))
        print("Word analytics: 1000 admissions with blocked sink: \(elapsed)")
    }
}
