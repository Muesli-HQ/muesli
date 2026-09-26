import Foundation
import MuesliCore
import PDFKit
import SQLite3
import Testing
@testable import MuesliCLI
@testable import MuesliNativeApp

// Contract comparison: kenn-io/msgvault PR946 at
// fa2404eb5a8a83879e3e9c7915c41ae42e8c4846, internal/muesli/{reader,format}.go.
// These fixtures come from Muesli's migrations and write APIs, never a copied schema.
@Suite("Meeting archive compatibility")
struct MeetingArchiveCompatibilityTests {
    @Test("a query-only reader sees the real archive fields and cannot write")
    func queryOnlySchema() throws {
        let fixture = try ArchiveFixture()
        let id = try fixture.insert()
        try fixture.withReader { reader in
            let columns = try reader.query("PRAGMA table_info(meetings)")
            let types = Dictionary(uniqueKeysWithValues: columns.map { ($0["name"]!, $0["type"]!) })
            for field in ["title", "start_time", "end_time", "created_at", "meeting_status",
                          "source", "raw_transcript", "formatted_notes", "manual_notes"] {
                #expect(types[field] == "TEXT")
            }
            #expect(types["id"] == "INTEGER")
            #expect(types["word_count"] == "INTEGER")
            #expect(types["duration_seconds"] == "REAL")
            #expect(types["deleted_at"] == "REAL")
            let row = try #require(reader.meetings().first)
            #expect(row["id"] == String(id))
            #expect(row["title"] == "Synthetic call")
            #expect(row["start_time"] == "2026-04-01T10:00:00Z")
            #expect(row["end_time"] == "2026-04-01T10:01:00Z")
            #expect(row["meeting_status"] == "completed")
            #expect(row["source"] == "meeting")
            let created = try #require(row["created_at"])
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(secondsFromGMT: 0)
            parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
            #expect(parser.date(from: created) != nil)
            #expect(try reader.query("PRAGMA query_only").first?["query_only"] == "1")
            #expect(reader.attemptWrite() == SQLITE_READONLY)
        }
        #expect(try fixture.store.meeting(id: id)?.title == "Synthetic call")
    }

    @Test("the pinned reader excludes in-progress, tombstoned and empty meetings")
    func eligibility() throws {
        let fixture = try ArchiveFixture()
        let completed = try fixture.insert()
        let recording = try fixture.store.createLiveMeeting(
            title: "Synthetic recording", calendarEventID: nil, startTime: ArchiveFixture.start
        )
        try fixture.store.updateMeetingTranscript(id: recording, rawTranscript: "Partial words")
        let processing = try fixture.insert()
        try fixture.store.updateMeetingStatus(id: processing, status: .processing)
        let deleted = try fixture.insert()
        try fixture.store.deleteMeeting(id: deleted)
        let empty = try fixture.insert(transcript: " \n ", notes: "")
        let fallback = try fixture.insert(transcript: "", notes: "## Raw Transcript\nNo canonical text")
        let failedSummary = try fixture.insert(transcript: "", notes: "## Summary Failed\nTry again")
        let summaryOnly = try fixture.insert(transcript: "", notes: "## Summary\nSynthetic notes")
        let noteOnly = try fixture.insert(transcript: "", notes: "")
        try fixture.store.updateMeetingStatus(id: noteOnly, status: .noteOnly)
        try fixture.store.updateMeetingManualNotes(id: noteOnly, manualNotes: "Synthetic manual note")
        let failed = try fixture.insert()
        try fixture.store.updateMeetingStatus(id: failed, status: .failed)

        try fixture.withReader { reader in
            let rows = try reader.meetings()
            #expect(rows.count == 10) // The reader includes all rows; formatting filters them.
            let eligible = Set(rows.filter(pinnedEligibility).compactMap { $0["id"] })
            #expect(eligible == Set([completed, summaryOnly, noteOnly, failed].map(String.init)))
            let tombstone = try #require(rows.first { $0["id"] == String(deleted) })
            #expect(tombstone["deleted_at"] != nil)
            #expect(tombstone["raw_transcript"] == "")
            #expect(!eligible.contains(String(recording)))
            #expect(!eligible.contains(String(processing)))
            #expect(!eligible.contains(String(empty)))
            #expect(!eligible.contains(String(fallback)))
            #expect(!eligible.contains(String(failedSummary)))
        }
    }

    @Test("participant snapshots preserve contact and email identity without duplicating Contacts")
    func participantIdentity() throws {
        let fixture = try ArchiveFixture()
        let id = try fixture.insert()
        try fixture.store.attachMeetingParticipant(meetingID: id, participant: .init(
            participantIdentifier: "contact:synthetic-phone-card", displayName: "Ana Example"
        ))
        try fixture.store.attachMeetingParticipant(meetingID: id, participant: .init(
            participantIdentifier: "contact:synthetic-email-card", displayName: "Bo Example",
            emailAddress: "bo@example.test"
        ))
        try fixture.store.attachMeetingParticipant(meetingID: id, participant: .init(
            participantIdentifier: "email:eli@example.test", displayName: "Eli Example",
            emailAddress: "eli@example.test"
        ))
        try fixture.store.attachCalendarMeetingParticipants(meetingID: id, participants: [
            .init(participantIdentifier: "email:cy@example.test", displayName: "Cy Example",
                  emailAddress: "cy@example.test"),
            .init(participantIdentifier: "calendar:synthetic-attendee", displayName: "Dee Example",
                  emailAddress: "dee@example.test")
        ])
        try fixture.store.removeMeetingParticipant(meetingID: id, participantIdentifier: "email:cy@example.test")

        try fixture.withReader { reader in
            let columns = try reader.query("PRAGMA table_info(meeting_participants)")
            let types = Dictionary(uniqueKeysWithValues: columns.map { ($0["name"]!, $0["type"]!) })
            #expect(types["meeting_id"] == "INTEGER")
            #expect(types["participant_identifier"] == "TEXT")
            #expect(types["display_name"] == "TEXT")
            #expect(types["email_address"] == "TEXT")
            #expect(types["insertion_order"] == "INTEGER")
            #expect(types["source"] == "TEXT")
            #expect(types["is_suppressed"] == "INTEGER")
            #expect(types["phone"] == nil)
            #expect(types["company"] == nil)
            let people = try reader.participants()
            #expect(people.map { $0["participant_identifier"] } == [
                "contact:synthetic-phone-card", "contact:synthetic-email-card",
                "email:eli@example.test", "calendar:synthetic-attendee"
            ])
            #expect(people.map { $0["display_name"] } == ["Ana Example", "Bo Example", "Eli Example", "Dee Example"])
            #expect(people[0]["email_address"] == nil)
            #expect(people[1]["email_address"] == "bo@example.test")
            #expect(people[2]["email_address"] == "eli@example.test")
            #expect(people.map { $0["source"] } == ["manual", "manual", "manual", "calendar"])
            #expect(try reader.query("SELECT is_suppressed FROM meeting_participants WHERE participant_identifier = 'email:cy@example.test'").first?["is_suppressed"] == "1")
        }
        // No Contacts API is called: this proves the stored lookup key survives,
        // not that the synthetic phone-only card can be enriched on a user's Mac.
    }
    @Test("rescans see late roster edits even when the meeting timestamp is unchanged")
    func lateRosterEdits() throws {
        let fixture = try ArchiveFixture()
        let id = try fixture.insert()
        let before = try fixture.withReader { try #require($0.meetings().first) }
        try fixture.store.attachMeetingParticipant(meetingID: id, participant: .init(
            participantIdentifier: "contact:synthetic-card", displayName: "Ana Example"
        ))
        try fixture.withReader { reader in
            let row = try #require(reader.meetings().first)
            #expect(row["updated_at"] == before["updated_at"])
            #expect(row["created_at"] == before["created_at"])
            #expect(try reader.participants().first?["display_name"] == "Ana Example")
        }
        try fixture.store.removeMeetingParticipant(meetingID: id, participantIdentifier: "contact:synthetic-card")
        try fixture.withReader { reader in
            let participantsAfterRemoval = try reader.participants()
            let updatedAtAfterRemoval = try reader.meetings().first?["updated_at"]
            #expect(participantsAfterRemoval.isEmpty)
            #expect(updatedAtAfterRemoval == before["updated_at"])
        }
    }

    @Test("a reader snapshot stays consistent while a subsequent scan sees canonical edits")
    func snapshotAndLateTextEdits() throws {
        let fixture = try ArchiveFixture()
        let id = try fixture.insert()
        let corrected = "[10:00:01] You: Hello\n[10:00:02] Ana Example: Corrected words"
        let before = try fixture.withReader { reader in
            let original = try #require(reader.meetings().first)
            try fixture.store.updateMeetingTranscript(id: id, rawTranscript: corrected)
            try fixture.store.updateMeetingNotes(id: id, formattedNotes: "## Summary\nCorrected summary")
            try fixture.store.updateMeetingManualNotes(id: id, manualNotes: "Corrected manual notes")
            try fixture.store.attachMeetingParticipant(meetingID: id, participant: .init(
                participantIdentifier: "contact:synthetic-card", displayName: "Ana Example"
            ))
            #expect(try reader.meetings().first == original)
            #expect(try reader.participants().isEmpty)
            return original
        }
        try fixture.withReader { reader in
            let after = try #require(reader.meetings().first)
            #expect(after["id"] == before["id"])
            #expect(after["created_at"] == before["created_at"])
            #expect(after["raw_transcript"] == corrected)
            #expect(after["formatted_notes"] == "## Summary\nCorrected summary")
            #expect(after["manual_notes"] == "Corrected manual notes")
            #expect(try reader.participants().first?["display_name"] == "Ana Example")
        }
    }

    @Test("resume keeps row identity and insert time when the start time changes")
    func resumeIdentity() throws {
        let fixture = try ArchiveFixture()
        let id = try fixture.insert()
        let before = try fixture.withReader { try #require($0.meetings().first) }
        _ = try fixture.store.prepareMeetingForResume(id: id)
        try fixture.store.completeLiveMeeting(
            id: id, title: "Synthetic resumed call", calendarEventID: nil,
            startTime: ArchiveFixture.start.addingTimeInterval(-60),
            endTime: ArchiveFixture.start.addingTimeInterval(120),
            rawTranscript: "[10:00:02] Ana Example: Continued", formattedNotes: "Synthetic resumed summary",
            micAudioPath: nil, systemAudioPath: nil
        )
        try fixture.withReader { reader in
            let after = try #require(reader.meetings().first)
            #expect(after["start_time"] == "2026-04-01T09:59:00Z")
            #expect(after["start_time"] != before["start_time"])
            #expect(after["id"] == before["id"])
            #expect(after["created_at"] == before["created_at"])
            #expect(after["meeting_status"] == "completed")
        }
    }

    @MainActor
    @Test("current canonical names reach CLI, Markdown and PDF text; existing exports remain snapshots")
    func canonicalConsumers() async throws {
        let fixture = try ArchiveFixture()
        let id = try fixture.insert()
        let exporter = MeetingMarkdownAutoExporter(supportDirectory: fixture.directory)
        var config = AppConfig()
        config.autoExportMarkdownEnabled = true
        config.autoExportMarkdownFolderPath = fixture.directory.appendingPathComponent("exports").path
        config.autoExportMarkdownContent = MeetingExportContent.transcript.rawValue
        config.autoExportFileFormat = MeetingAutoExportFileFormat.markdownAndPDF.rawValue
        let original = try #require(try fixture.store.meeting(id: id))
        let originalExports = try #require(await exporter.performExport(meeting: original, config: config))
        let originalMarkdown = try #require(originalExports.first { $0.pathExtension == "md" })
        let originalPDF = try #require(originalExports.first { $0.pathExtension == "pdf" })
        let originalMarkdownBytes = try Data(contentsOf: originalMarkdown)
        let originalPDFBytes = try Data(contentsOf: originalPDF)

        // Named text is an input, not a claim of voice recognition at this revision.
        let corrected = "[10:00:01] You: Hello\n[10:00:02] Ana Example: Corrected words"
        try fixture.store.updateMeetingTranscript(id: id, rawTranscript: corrected)
        let current = try #require(try fixture.store.meeting(id: id))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MeetingDetailPayload(current)))
        let payload = try #require(json as? [String: Any])
        #expect(payload["rawTranscript"] as? String == corrected)
        let markdown = MeetingExporter.buildMarkdown(meeting: current, content: .transcript)
        #expect(markdown.contains(corrected))
        #expect(try Data(contentsOf: originalMarkdown) == originalMarkdownBytes)
        #expect(try Data(contentsOf: originalPDF) == originalPDFBytes)

        let currentExports = try #require(await exporter.performExport(meeting: current, config: config))
        let currentMarkdown = try #require(currentExports.first { $0.pathExtension == "md" })
        let currentPDF = try #require(currentExports.first { $0.pathExtension == "pdf" })
        #expect(currentMarkdown != originalMarkdown)
        #expect(currentPDF != originalPDF)
        #expect(try String(contentsOf: currentMarkdown, encoding: .utf8).contains(corrected))
        let pdfText = try #require(PDFDocument(url: currentPDF)?.string)
        #expect(pdfText.contains("Ana Example: Corrected words"))
        #expect(try Data(contentsOf: originalMarkdown) == originalMarkdownBytes)
        #expect(try Data(contentsOf: originalPDF) == originalPDFBytes)
        exporter.waitForPendingLogWrites()
    }
}

// This is the pinned Go formatter's eligibility rule, not a new Muesli policy.
// In particular, note_only and failed rows with content can be archived.
// Adapted from msgvault (MIT License), Copyright (c) 2025-2026 Wes McKinney.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
private func pinnedEligibility(_ row: [String: String]) -> Bool {
    if row["deleted_at"] != nil || ["recording", "processing"].contains(row["meeting_status"] ?? "") {
        return false
    }
    let transcript = (row["raw_transcript"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let manual = (row["manual_notes"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let notes = (row["formatted_notes"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let fallback = ["## raw transcript", "## summary failed"].contains { notes == $0 || notes.hasPrefix($0 + "\n") }
    return !transcript.isEmpty || !manual.isEmpty || (!notes.isEmpty && !fallback)
}

private final class ArchiveFixture {
    static let start = Date(timeIntervalSince1970: 1_775_037_600)
    let directory: URL
    let store: DictationStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = DictationStore(databaseURL: directory.appendingPathComponent("synthetic.db"))
        try store.migrateIfNeeded()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func insert(transcript: String = "[10:00:01] You: Hello\n[10:00:02] Speaker 1: Hi", notes: String = "Synthetic summary") throws -> Int64 {
        try store.insertMeeting(
            title: "Synthetic call", calendarEventID: nil, startTime: Self.start,
            endTime: Self.start.addingTimeInterval(60), rawTranscript: transcript,
            formattedNotes: notes, micAudioPath: nil, systemAudioPath: nil
        )
    }

    func withReader<T>(_ body: (ArchiveReader) throws -> T) throws -> T {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(store.databasePath().path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard result == SQLITE_OK else { throw ArchiveSQLiteError(code: result) }
        let reader = ArchiveReader(db: db)
        try reader.execute("PRAGMA query_only=ON")
        try reader.execute("BEGIN") // Meeting and participant reads share one WAL snapshot.
        defer { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        return try body(reader)
    }
}

private struct ArchiveSQLiteError: Error { let code: Int32 }

private struct ArchiveReader {
    let db: OpaquePointer?

    func execute(_ sql: String) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw ArchiveSQLiteError(code: result) }
    }

    func attemptWrite() -> Int32 {
        sqlite3_exec(db, "UPDATE meetings SET title = 'Forbidden write'", nil, nil, nil)
    }

    func meetings() throws -> [[String: String]] {
        try query("SELECT * FROM meetings ORDER BY id")
    }

    func participants() throws -> [[String: String]] {
        try query("""
        SELECT meeting_id, participant_identifier, display_name, email_address, source, insertion_order
        FROM meeting_participants
        WHERE COALESCE(is_suppressed, 0) = 0
        ORDER BY meeting_id, insertion_order, participant_identifier
        """)
    }

    func query(_ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard result == SQLITE_OK else { throw ArchiveSQLiteError(code: result) }
        var rows: [[String: String]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw ArchiveSQLiteError(code: step) }
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                if let name = sqlite3_column_name(statement, column), let value = sqlite3_column_text(statement, column) {
                    row[String(cString: name)] = String(cString: value)
                }
            }
            rows.append(row)
        }
    }
}
