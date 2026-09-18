import XCTest
@testable import MuesliCore

/// Verifies the portable SQLite persistence path against a temporary database.
final class SQLitePersistenceTests: XCTestCase {
    private func makeTemporaryStore() throws -> (store: DictationStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.sqlite"))
        try store.migrateIfNeeded()
        return (store, directory)
    }

    func testInsertAndReadDictationRoundTrip() throws {
        let (store, directory) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let ended = started.addingTimeInterval(3.5)

        let id = try store.insertDictation(
            text: "Hello Windows shared core",
            durationSeconds: 3.5,
            appContext: "tests",
            source: "dictation",
            targetAppName: "Xcode",
            targetAppBundleID: "com.apple.dt.Xcode",
            startedAt: started,
            endedAt: ended
        )
        XCTAssertGreaterThan(id, 0)

        let recent = try store.recentDictations(limit: 10)
        XCTAssertEqual(recent.count, 1)
        let record = try XCTUnwrap(recent.first)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.rawText, "Hello Windows shared core")
        XCTAssertEqual(record.appContext, "tests")
        XCTAssertEqual(record.source, "dictation")
        XCTAssertEqual(record.targetAppName, "Xcode")
        XCTAssertEqual(record.targetAppBundleID, "com.apple.dt.Xcode")
        XCTAssertEqual(record.wordCount, 4)
        XCTAssertEqual(record.durationSeconds, 3.5, accuracy: 0.0001)
    }

    func testDataPersistsAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("muesli.sqlite")

        do {
            let store = DictationStore(databaseURL: url)
            try store.migrateIfNeeded()
            try store.insertDictation(
                text: "persisted row",
                durationSeconds: 1.0,
                startedAt: Date(timeIntervalSince1970: 1_600_000_000),
                endedAt: Date(timeIntervalSince1970: 1_600_000_001)
            )
        }

        let reopened = DictationStore(databaseURL: url)
        try reopened.migrateIfNeeded()
        let recent = try reopened.recentDictations(limit: 10)
        XCTAssertEqual(recent.map(\.rawText), ["persisted row"])
    }

    func testDeleteDictationRemovesRow() throws {
        let (store, directory) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = try store.insertDictation(
            text: "delete me",
            durationSeconds: 0.5,
            startedAt: Date(),
            endedAt: Date()
        )
        XCTAssertEqual(try store.recentDictations(limit: 10).count, 1)

        try store.deleteDictation(id: id)
        XCTAssertEqual(try store.recentDictations(limit: 10).count, 0)
    }

    func testUnicodeTextSurvivesRoundTrip() throws {
        let (store, directory) = try makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let unicode = "Zürich café 東京 नमस्ते 🎙️ — em dash"
        try store.insertDictation(
            text: unicode,
            durationSeconds: 2.0,
            startedAt: Date(),
            endedAt: Date()
        )
        let record = try XCTUnwrap(try store.recentDictations(limit: 1).first)
        XCTAssertEqual(record.rawText, unicode)
    }
}
