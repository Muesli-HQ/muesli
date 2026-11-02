import Foundation
import MuesliCore
import SQLite3
import Testing
@testable import MuesliNativeApp

@Suite("Failure-only dictation recovery")
struct DictationRecoveryTests {
    private func fixture() throws -> (URL, URL, DictationRecoveryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.wav")
        try (WavWriter.header(dataSize: 4) + Data([0, 1, 128, 255])).write(to: source)
        return (root, source, DictationRecoveryStore(directory: root.appendingPathComponent("Dictation Recovery")))
    }

    private func save(_ source: URL, to store: DictationRecoveryStore) throws -> FailedDictation {
        try store.save(wavURL: source, startedAt: Date(timeIntervalSince1970: 123456),
                       durationSeconds: 12.5, modelName: "Local model", failureMessage: "Recognition failed")
    }

    private func permissions(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    @Test("failed takes save independently and privately without consuming the original WAV")
    func savesPrivateIndependentRecoveries() throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: source)
        let first = try save(source, to: store)
        let second = try save(source, to: store)
        #expect(first.id != second.id)
        #expect(try store.recordings().count == 2)
        #expect(try Data(contentsOf: source) == original)
        for record in [first, second] {
            let audio = try store.validatedAudioURL(for: record)
            #expect(try Data(contentsOf: audio) == original)
            #expect(try permissions(audio) == 0o600)
            #expect(try permissions(audio.deletingLastPathComponent()) == 0o700)
            #expect(try permissions(audio.deletingLastPathComponent().appendingPathComponent("failure.json")) == 0o600)
        }
        // Reopening the store after relaunch discovers the same failed take.
        #expect(try DictationRecoveryStore(directory: store.directory).recordings().contains(first))
    }

    @Test("streaming recovery keeps exact Unicode partial text privately and remains readable after relaunch")
    func partialTranscriptIsPrivate() throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = "  Draft e\u{301} 👩🏽‍💻\nதமிழ்\tworld  "
        let record = try store.save(wavURL: source, startedAt: Date(), durationSeconds: 1,
            modelName: "Local model", failureMessage: "Incomplete stream", partialTranscript: partial)
        let textFile = store.audioURL(for: record).deletingLastPathComponent().appendingPathComponent("transcript.txt")
        #expect(try Data(contentsOf: textFile) == Data(partial.utf8))
        #expect(try permissions(textFile) == 0o600)
        #expect(try DictationRecoveryStore(directory: store.directory).recordings() == [record])
        #expect(record.partialTranscript == partial)
        // Original recovery schema had no partial-transcript field.
        let ordinary = try save(source, to: store)
        #expect(ordinary.partialTranscript == nil)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: ordinary)
            .deletingLastPathComponent().appendingPathComponent("transcript.txt").path))
        #expect(try store.recordings().contains(ordinary))
    }

    @Test("backup failure preserves original audio and earlier recovery content")
    func failedSaveKeepsOriginal() throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try save(source, to: store)
        let occupied = root.appendingPathComponent("occupied")
        try Data("keep".utf8).write(to: occupied)
        let blocked = DictationRecoveryStore(directory: occupied)
        #expect(throws: (any Error).self) { try save(source, to: blocked) }
        #expect(try Data(contentsOf: source).count == 48)
        #expect(try Data(contentsOf: store.audioURL(for: first)).count == 48)
        #expect(try Data(contentsOf: occupied) == Data("keep".utf8))
        // Encoding failure happens after the audio copy. Roll back only the
        // incomplete new session; keep both the source and prior recoveries.
        #expect(throws: (any Error).self) {
            try store.save(wavURL: source, startedAt: Date(), durationSeconds: .nan,
                           modelName: "Local model", failureMessage: "failed")
        }
        #expect(try store.recordings() == [first])
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count == 1)
    }

    @Test("a failed microphone start with no captured samples creates no backup")
    func noAudioCreatesNoBackup() throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try WavWriter.header(dataSize: 0).write(to: source)
        #expect(throws: DictationRecoveryStore.Failure.noCapturedAudio) { try save(source, to: store) }
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test("cancellation, superseded sessions, and onboarding tests never request a backup")
    func failureEligibility() {
        let failure = NSError(domain: "test", code: 1)
        #expect(DictationRecoveryPolicy.shouldPreserve(after: failure, taskIsCancelled: false,
                                                     isCurrentSession: true, isTestMode: false))
        #expect(!DictationRecoveryPolicy.shouldPreserve(after: failure, taskIsCancelled: true,
                                                      isCurrentSession: true, isTestMode: false))
        #expect(!DictationRecoveryPolicy.shouldPreserve(after: failure, taskIsCancelled: false,
                                                      isCurrentSession: false, isTestMode: false))
        #expect(!DictationRecoveryPolicy.shouldPreserve(after: failure, taskIsCancelled: false,
                                                      isCurrentSession: true, isTestMode: true))
        for cancellation: Error in [CancellationError(), URLError(.cancelled)] {
            #expect(!DictationRecoveryPolicy.shouldPreserve(after: cancellation, taskIsCancelled: false,
                                                          isCurrentSession: true, isTestMode: false))
        }
    }

    @Test("successful and canceled attempts only delete their existing WAV")
    func successfulCleanupCreatesNoRecovery() throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        DictationRecordingCleanup(wavURL: source).finish()
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test("failure ownership keeps the original if recovery storage fails")
    func preservesOriginalUntilBackupCompletes() throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var cleanup = DictationRecordingCleanup(wavURL: source)
        cleanup.preserveOriginal = true
        cleanup.finish()
        #expect(FileManager.default.fileExists(atPath: source.path))
        let record = try save(source, to: store)
        cleanup.preserveOriginal = false
        cleanup.finish()
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: store.audioURL(for: record)).count == 48)
    }

    @Test("corrupt metadata and unrelated upstream recovery folders leave valid takes accessible")
    func listingSkipsUnrelatedData() throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try save(source, to: store)
        let unrelated = store.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("not JSON".utf8).write(to: unrelated.appendingPathComponent("failure.json"))
        #expect(try store.recordings() == [record])
        try store.discard(record)
        #expect(try store.recordings().isEmpty)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("clearing history removes all owned recovery data, including incomplete entries")
    func clearHistoryRemovesRecoveryAudio() throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try save(source, to: store)
        let incomplete = store.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: incomplete.appendingPathComponent("audio.wav"))
        try store.discardAll()
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        try store.discardAll()
    }

    @Test("symlink inputs and replaced session folders cannot be used for recovery")
    func rejectsSymbolicLinks() throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: (any Error).self) { try save(link, to: store) }
        let record = try save(source, to: store)
        let session = store.audioURL(for: record).deletingLastPathComponent()
        try FileManager.default.removeItem(at: session)
        try FileManager.default.createSymbolicLink(at: session, withDestinationURL: root)
        #expect(throws: (any Error).self) { try store.validatedAudioURL(for: record) }
        #expect(throws: (any Error).self) { try store.discard(record) }
        #expect(try store.recordings().isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("a successful retry keeps audio until its transcript has been saved")
    @MainActor
    func retrySavesBeforeDeletingAudio() async throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try save(source, to: store)
        var savedText: String?
        var calls = 0
        try await DictationRecoveryRetry.run(record: record, store: store, transcribe: { audio in
            calls += 1
            #expect(audio == store.audioURL(for: record))
            let replayAudio = try Data(contentsOf: audio)
            let originalAudio = try Data(contentsOf: source)
            #expect(replayAudio == originalAudio)
            return "  Recovered தமிழ் transcript.  "
        }, persist: { text in
            #expect(FileManager.default.fileExists(atPath: store.audioURL(for: record).path))
            savedText = text
        })
        #expect(calls == 1)
        #expect(savedText == "Recovered தமிழ் transcript.")
        #expect(try store.recordings().isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("cleanup failure and relaunch cannot insert the same recovery into history twice")
    @MainActor
    func cleanupFailureDoesNotDuplicateHistory() async throws {
        let (root, source, store) = try fixture()
        let record = try save(source, to: store)
        let session = store.audioURL(for: record).deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: session.path)
            try? FileManager.default.removeItem(at: root)
        }
        let database = root.appendingPathComponent("history.db")
        try DictationStore(databaseURL: database).migrateIfNeeded()
        for attempt in 1...3 {
            // A new store instance simulates retrying after app relaunch.
            let history = DictationStore(databaseURL: database)
            var savedText: String?
            do {
                try await DictationRecoveryRetry.run(record: record, store: store,
                    transcribe: { _ in "Recovered text \(attempt)" }, persist: { text in
                        savedText = try history.insertRecoveredDictation(recoveryID: record.id,
                            text: text, durationSeconds: record.durationSeconds,
                            startedAt: record.startedAt, endedAt: record.startedAt)
                        if attempt < 3 {
                            // Real deletion failure after a committed history save.
                            try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: session.path)
                        }
                    })
                #expect(attempt == 3)
            } catch {
                #expect(attempt < 3)
                #expect((error as NSError).domain == NSCocoaErrorDomain)
                #expect((error as NSError).code == NSFileWriteNoPermissionError)
            }
            #expect(savedText == "Recovered text 1")
            #expect(try history.recentDictations().map(\.rawText) == ["Recovered text 1"])
            if attempt < 3 {
                #expect(try store.recordings() == [record])
                try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: session.path)
            }
        }
        #expect(try store.recordings().isEmpty)
        let separate = try save(source, to: store)
        let history = DictationStore(databaseURL: database)
        _ = try history.insertRecoveredDictation(recoveryID: separate.id, text: "Recovered text 1",
            durationSeconds: 1, startedAt: separate.startedAt, endedAt: separate.startedAt)
        #expect(try history.recentDictations().count == 2)
    }

    @Test("a failed retry-key write rolls back history and leaves the recording retryable")
    @MainActor
    func retryKeyFailureRollsBackHistory() async throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try save(source, to: store)
        let history = DictationStore(databaseURL: root.appendingPathComponent("history.db"))
        try history.migrateIfNeeded()
        _ = try history.insertDictation(text: "Ordinary successful dictation", durationSeconds: 1,
            startedAt: record.startedAt, endedAt: record.startedAt)
        var db: OpaquePointer?
        #expect(sqlite3_open(history.resolvedDatabaseURL.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        // The normal migration/insert path never initializes recovery tracking.
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE name = 'dictation_recovery_history'", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_DONE)
        sqlite3_finalize(statement)
        #expect(sqlite3_exec(db, """
        CREATE TABLE dictation_recovery_history (
            recovery_id TEXT PRIMARY KEY,
            dictation_id INTEGER NOT NULL UNIQUE REFERENCES dictations(id) ON DELETE CASCADE
        );
        CREATE TRIGGER reject_recovery_key BEFORE INSERT ON dictation_recovery_history
        BEGIN SELECT RAISE(ABORT, 'synthetic recovery-key failure'); END;
        """, nil, nil, nil) == SQLITE_OK)
        do {
            try await DictationRecoveryRetry.run(record: record, store: store,
                transcribe: { _ in "Recovered text" }, persist: { text in
                    _ = try history.insertRecoveredDictation(recoveryID: record.id, text: text,
                        durationSeconds: 1, startedAt: record.startedAt, endedAt: record.startedAt)
                })
            Issue.record("The retry-key write should fail")
        } catch {}
        #expect(try history.recentDictations().map(\.rawText) == ["Ordinary successful dictation"])
        #expect(try store.recordings() == [record])
        #expect(sqlite3_exec(db, "DROP TRIGGER reject_recovery_key", nil, nil, nil) == SQLITE_OK)
        _ = try history.insertRecoveredDictation(recoveryID: record.id, text: "Recovered text",
            durationSeconds: 1, startedAt: record.startedAt, endedAt: record.startedAt)
        #expect(try history.recentDictations().count == 2)
    }

    @Test("inference failure, empty output, and history-save failure preserve the recovery")
    @MainActor
    func failedRetriesKeepAudio() async throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try save(source, to: store)
        let error = NSError(domain: "test", code: 1)
        for outcome in 0..<3 {
            do {
                try await DictationRecoveryRetry.run(record: record, store: store, transcribe: { _ in
                    if outcome == 0 { throw error }
                    return outcome == 1 ? " \n " : "Recovered text"
                }, persist: { _ in throw error })
                Issue.record("Retry should fail")
            } catch {}
            #expect(try store.recordings() == [record])
        }
    }

    @Test("a canceled retry ignores a late model reply and keeps audio")
    @MainActor
    func canceledRetryIgnoresLateReply() async throws {
        let (root, source, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try save(source, to: store)
        let signal = AsyncStream<Void>.makeStream()
        var continuation: CheckedContinuation<String, Never>?
        var persisted = false
        let task = Task {
            try await DictationRecoveryRetry.run(record: record, store: store, transcribe: { _ in
                await withCheckedContinuation { pending in
                    continuation = pending
                    signal.continuation.yield(())
                }
            }, persist: { _ in persisted = true })
        }
        for await _ in signal.stream { break }
        task.cancel()
        continuation?.resume(returning: "Late reply")
        do {
            try await task.value
            Issue.record("Canceled retry should not complete")
        } catch is CancellationError {} catch { throw error }
        signal.continuation.finish()
        #expect(!persisted)
        #expect(try store.recordings() == [record])
    }
}
