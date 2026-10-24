import Foundation
import Testing
import SQLite3
import ZIPFoundation
@testable import MuesliCore

@Suite("Granola import")
struct GranolaImportTests {
    private let header = "document_id,user_email,document_title,workspace_name,document_created,summary,notes,transcript"
    private func csv(id: String = "00000000-0000-0000-0000-000000000001", summary: String = "## Summary\nA, B and \"C\"", transcript: String = "Hello\nWorld") -> Data {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return Data((header + "\r\n" + [id, "owner@example.test", "Planning ☕", "Team", "2026-10-24T14:34:40.866Z", summary, "Manual note", transcript].map(quote).joined(separator: ",") + "\r\n").utf8)
    }
    private func withStore(_ body: (DictationStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("test.db"))
        try store.migrateIfNeeded()
        try body(store)
    }

    @Test func multilineBOMAndUnicode() throws {
        let records = try GranolaImport.parse(Data([0xEF, 0xBB, 0xBF]) + csv())
        #expect(records.count == 1)
        #expect(records[0].summary == "## Summary\nA, B and \"C\"")
        #expect(records[0].transcript == "Hello\nWorld")
        #expect(records[0].title == "Planning ☕")
        #expect(records[0].createdAt.timeIntervalSince1970 == 1792852480.866)
    }

    @Test func summaryOnlyAndTranscriptOnly() throws {
        #expect(try GranolaImport.parse(csv(transcript: ""))[0].transcript.isEmpty)
        #expect(try GranolaImport.parse(csv(summary: ""))[0].summary.isEmpty)
    }

    @Test func rejectMalformedInput() {
        for bytes in [Data([0xff]), Data("wrong,header\n1,2".utf8), csv(id: "bad-id"), Data((header + "\n\"unterminated").utf8), Data((header + "\nx\"y").utf8), Data((header + "\n\"x\"y").utf8), Data((header + "\n\0").utf8)] {
            #expect(throws: GranolaImportError.self) { try GranolaImport.parse(bytes) }
        }
    }

    @Test func rejectsExcessiveColumnsBeforeAccumulatingFields() {
        let tooManyColumns = String(repeating: ",", count: 10_000)
        for text in [tooManyColumns, header + "\n" + tooManyColumns] {
            #expect(throws: GranolaImportError.self) { try GranolaImport.parse(Data(text.utf8)) }
        }
    }

    @Test func deletedImportsAreNotResurrected() throws {
        let records = try GranolaImport.parse(csv())
        try withStore { store in
            _ = try store.importGranola(records)
            let meeting = try #require(store.recentMeetings(limit: 10).first)
            try store.deleteMeeting(id: meeting.id)
            #expect(try store.importGranola(records).skipped == 1)
            #expect(try store.recentMeetings(limit: 10).isEmpty)
            let tombstone = try #require(store.textRecordsNeedingSync().first)
            #expect(tombstone.isDeleted)
            try withStore { destination in
                _ = try destination.upsertSyncedTextRecord(tombstone)
                #expect(try destination.importGranola(records).skipped == 1)
                #expect(try destination.recentMeetings(limit: 10).isEmpty)
            }
        }
    }

    @Test func preservesContentAndSkipsRepeats() throws {
        let records = try GranolaImport.parse(csv())
        try withStore { (store: DictationStore) throws in
            let report = try store.importGranola(records + records)
            #expect(report.imported == 1); #expect(report.skipped == 1)
            let meeting = try #require(store.recentMeetings(limit: 10).first)
            #expect(meeting.source == .granolaImport)
            #expect(meeting.calendarEventID == nil)
            let folder = try #require(store.listFolders().first)
            #expect(folder.name == "Granola")
            #expect(folder.parentID == nil)
            #expect(meeting.folderID == folder.id)
            #expect(meeting.manualNotes == "Manual note")
            #expect(meeting.formattedNotes == records[0].summary)
            #expect(meeting.rawTranscript == records[0].transcript)
            #expect(meeting.durationSeconds == 0)
            #expect(meeting.savedRecordingPath == nil)
            try store.updateMeetingNotes(id: meeting.id, formattedNotes: "Edited locally")
            #expect(try store.importGranola(records).skipped == 1)
            #expect(try store.meeting(id: meeting.id)?.formattedNotes == "Edited locally")
            #expect(try store.listFolders().count == 1)
        }
    }

    @Test func countsTranscriptAndManualNotesButNotGeneratedSummary() throws {
        let records = [("One two", "Three four", 4), ("", "Manual words", 2), ("", "", 0)].map { transcript, notes, count in
            (GranolaImportRecord(id: UUID().uuidString.lowercased(), title: "Count", createdAt: Date(),
                                 summary: "Generated summary words", notes: notes, transcript: transcript,
                                 workspace: "Team", ownerEmail: ""), count)
        }
        for (record, expected) in records {
            try withStore { store in
                _ = try store.importGranola([record])
                #expect(try store.recentMeetings(limit: 1).first?.wordCount == expected)
            }
        }
    }

    @Test func manualNoteEditsRefreshStoredAndSyncedWordCounts() throws {
        for transcript in ["", "Transcript words"] {
            try withStore { store in
                let record = GranolaImportRecord(id: UUID().uuidString.lowercased(), title: "Count", createdAt: Date(),
                    summary: "Generated summary excluded", notes: "Original manual notes", transcript: transcript,
                    workspace: "", ownerEmail: "")
                _ = try store.importGranola([record])
                let meeting = try #require(store.recentMeetings(limit: 1).first)
                let transcriptWords = transcript.isEmpty ? 0 : 2
                for (notes, words) in [("One two three four", 4), ("", 0)] {
                    try store.updateMeetingManualNotes(id: meeting.id, manualNotes: notes)
                    let saved = try #require(try store.meeting(id: meeting.id))
                    #expect(saved.wordCount == transcriptWords + words)
                    #expect(saved.manualNotes == notes)
                    #expect(saved.formattedNotes == record.summary)
                    let synced = try #require(store.textRecordsNeedingSync().first)
                    #expect(synced.wordCount == transcriptWords + words)
                }
            }
        }
    }

    @Test func syncedIdentityPreventsDuplicateImport() throws {
        let records = try GranolaImport.parse(csv())
        try withStore { source in
            _ = try source.importGranola(records)
            let synced = try #require(source.textRecordsNeedingSync().first)
            #expect(synced.localSource == "granola_import")
            #expect(synced.id == records[0].syncIdentity)
            try withStore { destination in
                _ = try destination.upsertSyncedTextRecord(synced)
                #expect(try destination.recentMeetings(limit: 10).first?.source == .granolaImport)
                #expect(try destination.importGranola(records).skipped == 1)
            }
        }
    }

    @Test func rollsBackWholeBatchOnDatabaseFailure() throws {
        let records = try GranolaImport.parse(csv()) + GranolaImport.parse(csv(id: "00000000-0000-0000-0000-000000000002"))
        try withStore { (store: DictationStore) throws in
            var db: OpaquePointer?
            #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, "CREATE TRIGGER fail_second BEFORE INSERT ON meetings WHEN NEW.cloud_record_name LIKE '%000000000002' BEGIN SELECT RAISE(ABORT, 'test failure'); END", nil, nil, nil) == SQLITE_OK)
            #expect(throws: (any Error).self) { try store.importGranola(records) }
            #expect(try store.recentMeetings(limit: 10).isEmpty)
            #expect(try store.listFolders().isEmpty)
        }
    }

    @Test func reusesExistingImportFolderAndLeavesUnrelatedFoldersAlone() throws {
        let records = try GranolaImport.parse(csv())
        try withStore { store in
            let parent = try store.createFolder(name: "Other")
            _ = try store.createFolder(name: "Granola", parentID: parent)
            let destination = try store.createFolder(name: "Granola")
            _ = try store.importGranola(records)
            #expect(try store.recentMeetings(limit: 10).first?.folderID == destination)
            #expect(try store.listFolders().count == 3)
        }
    }

    @Test func noFolderCreatedForEmptyOrAlreadySyncedImports() throws {
        let records = try GranolaImport.parse(csv())
        try withStore { source in
            _ = try source.importGranola(records)
            let synced = try #require(source.textRecordsNeedingSync().first)
            try withStore { destination in
                #expect(try destination.importGranola([]).imported == 0)
                #expect(try destination.listFolders().isEmpty)
                _ = try destination.upsertSyncedTextRecord(synced)
                let before = try destination.listFolders().count
                #expect(try destination.importGranola(records).skipped == 1)
                #expect(try destination.listFolders().count == before)
            }
        }
    }

    @Test func reorderedColumnsExtraColumnsAndCRLFPreservation() throws {
        let data = Data("transcript,notes,summary,document_created,workspace_name,document_title,user_email,document_id,extra\r\n\"line one\r\nline two\",,Summary,2026-10-24T14:34:40Z,Team,Title,owner@example.test,00000000-0000-0000-0000-000000000001,ignored".utf8)
        let record = try #require(GranolaImport.parse(data).first)
        #expect(record.transcript == "line one\r\nline two")
        #expect(record.notes.isEmpty)
    }

    @Test func invalidDatesColumnCountsAndEmptyContentFail() {
        let original = String(data: csv(), encoding: .utf8)!
        let badDate = original.replacingOccurrences(of: "2026-10-24T14:34:40.866Z", with: "not-a-date")
        let shortRow = header + "\n00000000-0000-0000-0000-000000000001"
        let empty = header + "\n00000000-0000-0000-0000-000000000001,a@b.test,Title,Team,2026-10-24T14:34:40Z,,,"
        for invalid in [badDate, shortRow, empty] {
            #expect(throws: GranolaImportError.self) { try GranolaImport.parse(Data(invalid.utf8)) }
        }
    }

    private func zip(_ entries: [(String, Data)], compression: CompressionMethod = .deflate,
                     type: Entry.EntryType = .file) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (path, data) in entries {
            try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count), compressionMethod: compression) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return try #require(archive.data)
    }

    private func readTemporary(_ files: [(String, Data)]) throws -> [GranolaImportRecord] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = try files.map { name, data in
            let url = folder.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        let records = try GranolaImport.read(files: urls)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == files.count)
        return records
    }

    @Test func zipReadsAllPartsAndIgnoresMacMetadataWithoutExtraction() throws {
        let second = csv(id: "00000000-0000-0000-0000-000000000002")
        let archive = try zip([("export/part-000.csv", csv()), ("export/part-001.CSV", second),
                               ("__MACOSX/._part.csv", Data("metadata".utf8)), ("README.txt", Data())])
        let records = try readTemporary([("export.ZIP", archive)])
        #expect(records.count == 2)
        #expect(try records[0].summary == GranolaImport.parse(csv())[0].summary)
        #expect(records[1].id.hasSuffix("2"))
        #expect(try readTemporary([("export.zip", archive), ("more.csv", csv())]).count == 3)
        #expect(try readTemporary([("stored.zip", zip([("part.csv", csv())], compression: .none))]).count == 1)
    }

    @Test func zipRejectsMissingCSVTruncationAndInvalidCSV() throws {
        let valid = try zip([("part.csv", csv())])
        let invalids = [Data("not zip".utf8), Data(valid.dropLast(10)),
                        try zip([("readme.txt", Data("notes".utf8))]),
                        try zip([("good.csv", csv()), ("bad.csv", Data("wrong,header".utf8))])]
        for data in invalids {
            #expect(throws: GranolaImportError.self) { try readTemporary([("export.zip", data)]) }
        }
    }

    @Test func zipRejectsSymlinksAndUnsafeCSVPaths() throws {
        for path in ["../escape.csv", "/absolute.csv", "folder\\escape.csv"] {
            let data = try zip([(path, csv())])
            #expect(throws: GranolaImportError.self) { try readTemporary([("export.zip", data)]) }
        }
        let link = try zip([("part.csv", Data("/tmp/private.csv".utf8))], type: .symlink)
        #expect(throws: GranolaImportError.self) { try readTemporary([("export.zip", link)]) }
    }

    @Test func zipRejectsChecksumMismatchAndUnreadableLaterEntry() throws {
        var corrupted = try zip([("part.csv", csv())], compression: .none)
        let content = try #require(corrupted.range(of: Data("Planning".utf8)))
        corrupted[content.lowerBound] ^= 1
        #expect(throws: GranolaImportError.self) { try readTemporary([("export.zip", corrupted)]) }

        let original = try zip([("one.csv", csv()), ("two.csv", csv())], compression: .none)
        let first = try #require(original.range(of: Data([0x50, 0x4b, 0x01, 0x02])))
        let second = try #require(original.range(of: Data([0x50, 0x4b, 0x01, 0x02]), in: first.upperBound..<original.count))
        var encrypted = original
        encrypted[second.lowerBound + 8] |= 1
        #expect(throws: GranolaImportError.self) { try readTemporary([("export.zip", encrypted)]) }
        var damaged = original
        damaged[second.lowerBound] = 0
        #expect(throws: GranolaImportError.self) { try readTemporary([("export.zip", damaged)]) }
    }

    @Test func zipRejectsExcessiveExpandedSize() throws {
        let expanded = Data(repeating: 65, count: GranolaImport.maximumBytes + 1)
        let archive = try zip([("huge.csv", expanded)])
        #expect(archive.count < GranolaImport.maximumBytes)
        #expect(throws: GranolaImportError.self) { try readTemporary([("export.zip", archive)]) }
    }

    @Test func previewAndStoredMeetingsAreNewestFirstAcrossFiles() throws {
        let early = Data(String(decoding: csv(id: "00000000-0000-0000-0000-000000000002"), as: UTF8.self)
            .replacingOccurrences(of: "2026-10-24", with: "2025-01-01")
            .replacingOccurrences(of: "Planning ☕", with: "Alphabetically first").utf8)
        let recent = Data(String(decoding: csv(), as: UTF8.self)
            .replacingOccurrences(of: "Planning ☕", with: "Zebra latest").utf8)
        let records = try readTemporary([("old.zip", zip([("old.csv", early)])), ("new.csv", recent)])
        #expect(records.map(\.title) == ["Zebra latest", "Alphabetically first"])
        try withStore { store in
            _ = try store.importGranola(records)
            #expect(try store.recentMeetings(limit: 10).map(\.title) == ["Zebra latest", "Alphabetically first"])
            #expect(try store.recentMeetings(limit: 1).first?.title == "Zebra latest")
        }
    }

    @Test func newestMeetingsAreSelectedBeforeBrowserLimit() throws {
        let records = (0..<205).map { index in
            GranolaImportRecord(id: UUID().uuidString.lowercased(), title: "Meeting \(index)",
                                createdAt: Date(timeIntervalSince1970: 1_790_000_000 - Double(index * 3600)),
                                summary: "Summary", notes: "", transcript: "Transcript", workspace: "Team", ownerEmail: "")
        }
        try withStore { store in
            _ = try store.importGranola(records)
            let folder = try #require(store.listFolders().first)
            for folderID: Int64? in [nil, folder.id] {
                let visible = try store.recentMeetings(limit: 200, folderID: folderID)
                #expect(visible.count == 200)
                #expect(visible.first?.title == "Meeting 0")
                #expect(visible.last?.title == "Meeting 199")
            }
        }
    }

    @Test func folderLimitMergesDescendantsAfterFilteringOriginAndDeletion() throws {
        let records = (0..<30).map { index in
            GranolaImportRecord(id: UUID().uuidString.lowercased(), title: "Meeting \(index)",
                                createdAt: Date(timeIntervalSince1970: 1_790_000_000 - Double(index * 3600)),
                                summary: "Summary", notes: "", transcript: "Transcript", workspace: "", ownerEmail: "")
        }
        try withStore { store in
            _ = try store.importGranola(records)
            let root = try #require(store.listFolders().first)
            let child = try store.createFolder(name: "Child", parentID: root.id)
            let grandchild = try store.createFolder(name: "Grandchild", parentID: child)
            let other = try store.createFolder(name: "Other")
            let rows = try store.recentMeetings()
            for (index, row) in rows.enumerated() {
                try store.moveMeeting(id: row.id, toFolder: [root.id, child, grandchild][index % 3])
            }
            try store.moveMeeting(id: rows[0].id, toFolder: other)
            try store.deleteMeeting(id: rows[1].id)
            var db: OpaquePointer?
            #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, "UPDATE meetings SET source = 'ios' WHERE id = \(rows[2].id)", nil, nil, nil) == SQLITE_OK)
            #expect(try store.recentMeetings(limit: 3, folderID: root.id).map(\.title) == ["Meeting 2", "Meeting 3", "Meeting 4"])
            #expect(try store.recentMeetings(limit: 3, folderID: root.id, origin: .thisMac).map(\.title) == ["Meeting 3", "Meeting 4", "Meeting 5"])
            #expect(try store.recentMeetings(limit: 3, folderID: root.id, origin: .fromIPhone).map(\.title) == ["Meeting 2"])
            #expect(try store.recentMeetings(folderID: root.id).count == 28)
            #expect(try store.recentMeetings(limit: 0, folderID: root.id).isEmpty)
        }
    }

    @Test func chronologicalQueryHandlesMixedTimestampFormatsAndInvalidDates() throws {
        try withStore { store in
            let formats = ["2026-10-24T09:00:00Z", "2026-10-24T15:00:00+05:30", "2026-10-24 10:00:00", "invalid", "2026-10-24T10:00:00.500Z"]
            for (index, timestamp) in formats.enumerated() {
                let record = GranolaImportRecord(id: UUID().uuidString.lowercased(), title: "Meeting \(index)", createdAt: Date(), summary: "Summary", notes: "", transcript: "", workspace: "", ownerEmail: "")
                _ = try store.importGranola([record])
                var db: OpaquePointer?
                #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
                defer { sqlite3_close(db) }
                #expect(sqlite3_exec(db, "UPDATE meetings SET start_time = '\(timestamp)' WHERE title = 'Meeting \(index)'", nil, nil, nil) == SQLITE_OK)
            }
            #expect(try store.recentMeetings().map(\.title) == ["Meeting 4", "Meeting 2", "Meeting 1", "Meeting 0", "Meeting 3"])
        }
    }

    @Test func upgradesLegacyImportFolderInPlaceOnlyOnce() throws {
        try withStore { store in
            _ = try store.importGranola(GranolaImport.parse(csv()))
            let folder = try #require(store.listFolders().first)
            try store.renameFolder(id: folder.id, name: "Imported from Granola")
            let unrelated = try store.createFolder(name: "Imported from Granola")
            var db: OpaquePointer?
            #expect(sqlite3_open(store.resolvedDatabaseURL.path, &db) == SQLITE_OK)
            defer { sqlite3_close(db) }
            #expect(sqlite3_exec(db, "DELETE FROM local_migrations WHERE identifier = 'granola_short_folder_name_v1'", nil, nil, nil) == SQLITE_OK)
            try store.migrateIfNeeded()
            #expect(try store.listFolders().first { $0.id == folder.id }?.name == "Granola")
            #expect(try store.listFolders().first { $0.id == unrelated }?.name == "Imported from Granola")
            #expect(try store.recentMeetings(limit: 10).first?.folderID == folder.id)
            try store.renameFolder(id: folder.id, name: "Imported from Granola")
            try store.migrateIfNeeded()
            #expect(try store.listFolders().first { $0.id == folder.id }?.name == "Imported from Granola")
        }
    }

}
