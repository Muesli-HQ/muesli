import Testing
import Foundation
import MuesliCore
import SQLite3
@testable import MuesliNativeApp

@Suite("Private meetings store", .serialized)
struct PrivateMeetingsStoreTests {

    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-private-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    /// A database from before folders and private flags existed.
    private func makeLegacyStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-private-legacy-\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE meetings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            calendar_event_id TEXT,
            start_time TEXT NOT NULL,
            end_time TEXT,
            duration_seconds REAL,
            raw_transcript TEXT,
            formatted_notes TEXT,
            mic_audio_path TEXT,
            system_audio_path TEXT,
            word_count INTEGER NOT NULL DEFAULT 0,
            source TEXT NOT NULL DEFAULT 'meeting',
            created_at TEXT DEFAULT (datetime('now'))
        );
        """
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        return DictationStore(databaseURL: url)
    }

    @discardableResult
    private func insertMeeting(_ store: DictationStore, title: String = "Call") throws -> Int64 {
        let now = Date()
        return try store.insertMeeting(
            title: title,
            calendarEventID: nil,
            startTime: now,
            endTime: now.addingTimeInterval(60),
            rawTranscript: "words",
            formattedNotes: "",
            micAudioPath: nil,
            systemAudioPath: nil
        )
    }

    private func setFolderParentRaw(_ store: DictationStore, folderID: Int64, parentID: Int64) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(store.databasePath().path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "UPDATE meeting_folders SET parent_id = \(parentID) WHERE id = \(folderID)", nil, nil, nil) == SQLITE_OK)
    }

    // MARK: - Schema (F1)

    @Test("migration adds the private flags to a legacy database and is idempotent")
    func legacyMigrationAddsFlags() throws {
        let store = try makeLegacyStore()
        try store.migrateIfNeeded()
        try store.migrateIfNeeded()

        let id = try insertMeeting(store)
        #expect(try store.isMeetingPrivate(id: id) == false)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        #expect(try store.isMeetingPrivate(id: id) == true)
    }

    @Test("new meetings and folders are not private")
    func defaultsAreNotPrivate() throws {
        let store = try makeStore()
        let meetingID = try insertMeeting(store)
        let folderID = try store.createFolder(name: "Team")

        #expect(try store.isMeetingPrivate(id: meetingID) == false)
        #expect(try store.listFolders().first { $0.id == folderID }?.isPrivate == false)
        #expect(try store.privateMeetingIDs().isEmpty)
    }

    // MARK: - Meeting flag

    @Test("setMeetingPrivate marks and unmarks a meeting")
    func meetingFlagRoundTrip() throws {
        let store = try makeStore()
        let id = try insertMeeting(store)
        let other = try insertMeeting(store, title: "Other")

        try store.setMeetingPrivate(id: id, isPrivate: true)
        #expect(try store.isMeetingPrivate(id: id))
        #expect(try store.isMeetingPrivate(id: other) == false)
        #expect(try store.privateMeetingIDs() == [id])

        try store.setMeetingPrivate(id: id, isPrivate: false)
        #expect(try store.isMeetingPrivate(id: id) == false)
        #expect(try store.privateMeetingIDs().isEmpty)
    }

    @Test("directlyPrivateMeetingIDs ignores meetings that are private only through a folder")
    func directFlagsExcludeInherited() throws {
        let store = try makeStore()
        let folderID = try store.createFolder(name: "Legal")
        try store.setFolderPrivate(id: folderID, isPrivate: true)
        let inherited = try insertMeeting(store, title: "Inherited")
        let direct = try insertMeeting(store, title: "Direct")
        try store.moveMeeting(id: inherited, toFolder: folderID)
        try store.setMeetingPrivate(id: direct, isPrivate: true)

        #expect(try store.directlyPrivateMeetingIDs() == [direct])
        #expect(try store.privateMeetingIDs() == [direct, inherited])
    }

    @Test("isFolderPrivate covers the folder, its subfolders, and nothing else")
    func folderPrivacyLookup() throws {
        let store = try makeStore()
        let root = try store.createFolder(name: "Legal")
        let child = try store.createFolder(name: "Cases", parentID: root)
        let other = try store.createFolder(name: "Work")

        #expect(try store.isFolderPrivate(id: child) == false)
        try store.setFolderPrivate(id: root, isPrivate: true)
        #expect(try store.isFolderPrivate(id: root))
        #expect(try store.isFolderPrivate(id: child))
        #expect(try store.isFolderPrivate(id: other) == false)
        #expect(try store.isFolderPrivate(id: 9_999) == false)
    }

    // MARK: - Folder inheritance (F6, F7, F8)

    @Test("a meeting in a private folder is private")
    func folderMakesMeetingsPrivate() throws {
        let store = try makeStore()
        let folderID = try store.createFolder(name: "Legal")
        let id = try insertMeeting(store)
        try store.moveMeeting(id: id, toFolder: folderID)
        #expect(try store.isMeetingPrivate(id: id) == false)

        try store.setFolderPrivate(id: folderID, isPrivate: true)
        #expect(try store.isMeetingPrivate(id: id))
        #expect(try store.listFolders().first { $0.id == folderID }?.isPrivate == true)
        #expect(try store.privateMeetingIDs() == [id])
    }

    @Test("privacy is inherited through every ancestor, not only the direct parent")
    func inheritedThroughGrandparent() throws {
        let store = try makeStore()
        let root = try store.createFolder(name: "Legal")
        let child = try store.createFolder(name: "Cases", parentID: root)
        let grandchild = try store.createFolder(name: "2026", parentID: child)
        let id = try insertMeeting(store)
        try store.moveMeeting(id: id, toFolder: grandchild)

        try store.setFolderPrivate(id: root, isPrivate: true)
        #expect(try store.isMeetingPrivate(id: id))
        // Only the root carries the flag; descendants stay unflagged themselves.
        #expect(try store.listFolders().first { $0.id == grandchild }?.isPrivate == false)
    }

    @Test("moving a meeting out of a private folder makes it normal again")
    func moveOutClearsInheritedPrivacy() throws {
        let store = try makeStore()
        let privateFolder = try store.createFolder(name: "Legal")
        let normalFolder = try store.createFolder(name: "Team")
        try store.setFolderPrivate(id: privateFolder, isPrivate: true)
        let id = try insertMeeting(store)
        try store.moveMeeting(id: id, toFolder: privateFolder)
        #expect(try store.isMeetingPrivate(id: id))

        try store.moveMeeting(id: id, toFolder: normalFolder)
        #expect(try store.isMeetingPrivate(id: id) == false)
        try store.moveMeeting(id: id, toFolder: nil)
        #expect(try store.isMeetingPrivate(id: id) == false)
    }

    @Test("a meeting flagged private stays private in a normal folder")
    func meetingFlagSurvivesMove() throws {
        let store = try makeStore()
        let normalFolder = try store.createFolder(name: "Team")
        let id = try insertMeeting(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)

        try store.moveMeeting(id: id, toFolder: normalFolder)
        #expect(try store.isMeetingPrivate(id: id))
        try store.moveMeeting(id: id, toFolder: nil)
        #expect(try store.isMeetingPrivate(id: id))
    }

    @Test("clearing a folder flag releases its unflagged meetings")
    func clearingFolderFlag() throws {
        let store = try makeStore()
        let folderID = try store.createFolder(name: "Legal")
        let inherited = try insertMeeting(store, title: "Inherited")
        let flagged = try insertMeeting(store, title: "Flagged")
        try store.moveMeeting(id: inherited, toFolder: folderID)
        try store.moveMeeting(id: flagged, toFolder: folderID)
        try store.setMeetingPrivate(id: flagged, isPrivate: true)
        try store.setFolderPrivate(id: folderID, isPrivate: true)

        try store.setFolderPrivate(id: folderID, isPrivate: false)
        #expect(try store.isMeetingPrivate(id: inherited) == false)
        #expect(try store.isMeetingPrivate(id: flagged))
    }

    // MARK: - Deleting a private folder (F9)

    @Test("deleting a private folder unfiles its meetings and they stop inheriting privacy")
    func deleteFolderDropsInheritedPrivacy() throws {
        let store = try makeStore()
        let folderID = try store.createFolder(name: "Legal")
        try store.setFolderPrivate(id: folderID, isPrivate: true)
        let id = try insertMeeting(store)
        try store.moveMeeting(id: id, toFolder: folderID)

        try store.deleteFolder(id: folderID)
        #expect(try store.isMeetingPrivate(id: id) == false)
    }

    @Test("deleting a private folder leaves flagged meetings private")
    func deleteFolderKeepsMeetingFlag() throws {
        let store = try makeStore()
        let folderID = try store.createFolder(name: "Legal")
        try store.setFolderPrivate(id: folderID, isPrivate: true)
        let id = try insertMeeting(store)
        try store.setMeetingPrivate(id: id, isPrivate: true)
        try store.moveMeeting(id: id, toFolder: folderID)

        try store.deleteFolder(id: folderID)
        #expect(try store.isMeetingPrivate(id: id))
    }

    @Test("deleting a private folder keeps its subfolders' own flags and drops inherited privacy")
    func deleteFolderReparentsChildren() throws {
        let store = try makeStore()
        let parent = try store.createFolder(name: "Legal")
        let child = try store.createFolder(name: "Cases", parentID: parent)
        let flaggedChild = try store.createFolder(name: "Sealed", parentID: parent)
        try store.setFolderPrivate(id: parent, isPrivate: true)
        try store.setFolderPrivate(id: flaggedChild, isPrivate: true)
        let inChild = try insertMeeting(store, title: "In child")
        let inFlagged = try insertMeeting(store, title: "In flagged")
        try store.moveMeeting(id: inChild, toFolder: child)
        try store.moveMeeting(id: inFlagged, toFolder: flaggedChild)

        try store.deleteFolder(id: parent)
        #expect(try store.isMeetingPrivate(id: inChild) == false)
        #expect(try store.isMeetingPrivate(id: inFlagged))
    }

    // MARK: - Failure (F19)

    @Test("flagging a missing meeting or folder throws instead of silently succeeding")
    func missingRowsThrow() throws {
        let store = try makeStore()
        #expect(throws: (any Error).self) { try store.setMeetingPrivate(id: 9_999, isPrivate: true) }
        #expect(throws: (any Error).self) { try store.setFolderPrivate(id: 9_999, isPrivate: true) }
    }

    @Test("an unknown meeting id is not private")
    func unknownMeetingIsNotPrivate() throws {
        let store = try makeStore()
        #expect(try store.isMeetingPrivate(id: 9_999) == false)
    }

    @Test("a corrupt folder cycle terminates and still honors a private ancestor")
    func cyclicFoldersTerminate() throws {
        let store = try makeStore()
        let a = try store.createFolder(name: "A")
        let b = try store.createFolder(name: "B", parentID: a)
        try setFolderParentRaw(store, folderID: a, parentID: b)
        try store.setFolderPrivate(id: b, isPrivate: true)
        let id = try insertMeeting(store)
        try store.moveMeeting(id: id, toFolder: a)

        #expect(try store.isMeetingPrivate(id: id))
    }
}
