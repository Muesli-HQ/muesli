import Foundation
import SQLite3

// Named speakers (voiceprints).
//
// Embeddings are biometric data. Everything in this file is device-local: none of these
// tables feed SyncTextRecord, CloudKit, telemetry, exports, CLI JSON, or logs. Public
// read models expose names and counts only, never vectors.

/// One diarized remote speaker of a meeting, as produced by the diarization pipeline.
public struct MeetingSpeakerObservation: Sendable, Equatable {
    /// The label printed in the raw transcript ("Speaker N").
    public let label: String
    /// Normalized centroid, or nil when the speaker had too little usable audio.
    public let centroid: [Float]?
    public let speechSeconds: Double

    public init(label: String, centroid: [Float]?, speechSeconds: Double) {
        self.label = label
        self.centroid = centroid
        self.speechSeconds = speechSeconds
    }
}

/// A meeting's diarized speaker as shown in the naming UI.
public struct MeetingSpeaker: Sendable, Equatable, Identifiable {
    public var id: String { label }
    /// The token currently printed for this speaker in the meeting's raw transcript.
    public let label: String
    public let profileID: Int64?
    public let profileName: String?
    /// Whether this meeting kept a centroid that can become a voiceprint.
    public let hasVoiceprintSource: Bool
    /// Whether the assigned profile holds a voiceprint taken from this meeting.
    public let hasVoiceprintFromMeeting: Bool
}

public struct SpeakerProfileSummary: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let name: String
    public let voiceprintCount: Int
    public let meetingCount: Int
}

public struct SpeakerAssignmentResult: Sendable, Equatable {
    public let profileID: Int64
    public let profileName: String
    public let transcriptRewritten: Bool
    public let voiceprintStored: Bool
}

public enum SpeakerIdentityError: Error, Equatable, LocalizedError {
    case emptyName
    case reservedName
    case reservedLabel
    case speakerNotFound
    case nameInUseInMeeting
    case meetingNotFound

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name."
        case .reservedName: "That name is reserved for transcript labels. Choose another name."
        case .reservedLabel: "Only diarized speakers can be named."
        case .speakerNotFound: "This speaker is no longer part of the meeting."
        case .nameInUseInMeeting: "Another speaker in this meeting already has that name."
        case .meetingNotFound: "The meeting could not be found."
        }
    }
}

enum SpeakerIdentitySQL {
    static func migrate(db: OpaquePointer?) throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS speaker_profiles (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_speaker_profiles_name
            ON speaker_profiles(name COLLATE NOCASE);
        CREATE TABLE IF NOT EXISTS speaker_voiceprints (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            profile_id INTEGER NOT NULL REFERENCES speaker_profiles(id) ON DELETE CASCADE,
            embedding BLOB NOT NULL,
            dimension INTEGER NOT NULL,
            source_meeting_id INTEGER,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_speaker_voiceprints_profile
            ON speaker_voiceprints(profile_id, source_meeting_id);
        CREATE TABLE IF NOT EXISTS meeting_speakers (
            meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
            label TEXT NOT NULL,
            embedding BLOB,
            profile_id INTEGER REFERENCES speaker_profiles(id) ON DELETE SET NULL,
            PRIMARY KEY (meeting_id, label)
        );
        """, db: db)
    }

    /// Meetings are soft-deleted, so `ON DELETE CASCADE` never fires for them. The
    /// meeting delete paths call this so a deleted meeting keeps no biometric centroid.
    static func deleteMeetingSpeakers(meetingID: Int64?, db: OpaquePointer?) throws {
        if let meetingID {
            try execute("DELETE FROM meeting_speakers WHERE meeting_id = ?", [.integer(meetingID)], db: db)
        } else {
            try execute("DELETE FROM meeting_speakers", db: db)
        }
    }

    enum Value {
        case text(String), integer(Int64), real(Double), blob(Data), null
    }

    static func execute(_ sql: String, _ values: [Value] = [], db: OpaquePointer?) throws {
        if values.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db) }
            return
        }
        _ = try rows(sql, values, db: db) { _ in () }
    }

    static func rows<T>(_ sql: String, _ values: [Value] = [], db: OpaquePointer?, map: (OpaquePointer?) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw error(db) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let integer): sqlite3_bind_int64(statement, index, integer)
            case .real(let real): sqlite3_bind_double(statement, index, real)
            case .blob(let data):
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error(db) }
            result.append(try map(statement))
        }
    }

    static func transaction<T>(db: OpaquePointer?, _ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE", db: db)
        do {
            let result = try operation()
            try execute("COMMIT", db: db)
            return result
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }

    static func integer(_ statement: OpaquePointer?, _ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    static func blob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    /// Float32, host byte order (little-endian on every supported Mac).
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Generic message: SQLite error text can quote values, and these rows hold names.
    private static func error(_ db: OpaquePointer?) -> NSError {
        NSError(domain: "SpeakerIdentityDB", code: Int(sqlite3_errcode(db)),
                userInfo: [NSLocalizedDescriptionKey: "Speaker storage could not be updated."])
    }
}

extension DictationStore {
    // MARK: Pipeline

    /// Highest numeric suffix among `"Speaker N"` labels in `existingLabels` or line
    /// prefixes in `transcript`. Used when resuming a meeting so new sessions do not
    /// reuse earlier `"Speaker N"` labels.
    public static func highestSpeakerNumber(inTranscript transcript: String, existingLabels: [String]) -> Int {
        var highest = 0
        if let labelRegex = try? NSRegularExpression(pattern: "^Speaker (\\d+)$") {
            for label in existingLabels {
                let range = NSRange(label.startIndex..., in: label)
                if let match = labelRegex.firstMatch(in: label, range: range),
                   let numberRange = Range(match.range(at: 1), in: label),
                   let number = Int(label[numberRange]) {
                    highest = max(highest, number)
                }
            }
        }
        if let transcriptRegex = try? NSRegularExpression(pattern: "(?m)^(?:\\[[0-9]{2}:[0-9]{2}(?::[0-9]{2})?\\]\\s+)?Speaker (\\d+):") {
            let range = NSRange(transcript.startIndex..., in: transcript)
            transcriptRegex.enumerateMatches(in: transcript, range: range) { match, _, _ in
                guard let match,
                      let numberRange = Range(match.range(at: 1), in: transcript),
                      let number = Int(transcript[numberRange]) else { return }
                highest = max(highest, number)
            }
        }
        return highest
    }

    /// Next available `"Speaker N"` index for a meeting, strictly greater than any
    /// existing `"Speaker N"` in `meeting_speakers` or its transcript.
    public func nextSpeakerNumber(forMeetingID meetingID: Int64, priorTranscript: String? = nil) throws -> Int {
        try withChatDatabase { db in
            try nextSpeakerNumber(forMeetingID: meetingID, priorTranscript: priorTranscript, db: db)
        }
    }

    private func nextSpeakerNumber(forMeetingID meetingID: Int64, priorTranscript: String?, db: OpaquePointer?) throws -> Int {
        let existingLabels = try SpeakerIdentitySQL.rows(
            "SELECT label FROM meeting_speakers WHERE meeting_id = ?", [.integer(meetingID)], db: db
        ) { SpeakerIdentitySQL.text($0, 0) ?? "" }
        let dbTranscript = try SpeakerIdentitySQL.rows(
            "SELECT COALESCE(raw_transcript, '') FROM meetings WHERE id = ?", [.integer(meetingID)], db: db
        ) { SpeakerIdentitySQL.text($0, 0) ?? "" }.first ?? ""
        let combined = [dbTranscript, priorTranscript ?? ""].joined(separator: "\n")
        return Self.highestSpeakerNumber(inTranscript: combined, existingLabels: existingLabels) + 1
    }

    /// Records this meeting's diarized speakers, then matches the centroids against saved
    /// voiceprints. When `preservingExisting` is false, replaces all rows for the meeting;
    /// when true (resumed meetings), keeps existing rows and offsets any colliding
    /// `"Speaker N"` labels past the highest existing speaker number. Returns
    /// `observed label -> profile name` for confident matches when `renderNames` is true;
    /// when false (private meetings) the match is recorded locally but nothing is returned
    /// for the transcript.
    public func recordMeetingSpeakers(
        meetingID: Int64,
        observations: [MeetingSpeakerObservation],
        renderNames: Bool,
        preservingExisting: Bool = false
    ) throws -> [String: String] {
        try withChatDatabase { db in
            try SpeakerIdentitySQL.transaction(db: db) {
                if !preservingExisting {
                    try SpeakerIdentitySQL.deleteMeetingSpeakers(meetingID: meetingID, db: db)
                }
                // A discard or delete can race with the end of processing; never leave a
                // centroid behind for a meeting that is gone.
                let live = try SpeakerIdentitySQL.rows(
                    "SELECT COALESCE(raw_transcript, '') FROM meetings WHERE id = ? AND deleted_at IS NULL", [.integer(meetingID)], db: db
                ) { SpeakerIdentitySQL.text($0, 0) ?? "" }
                guard let existingTranscript = live.first else { return [:] }
                let existingLabels: Set<String>
                var nextNumber: Int
                if preservingExisting {
                    let labels = try SpeakerIdentitySQL.rows(
                        "SELECT label FROM meeting_speakers WHERE meeting_id = ?", [.integer(meetingID)], db: db
                    ) { SpeakerIdentitySQL.text($0, 0) ?? "" }
                    existingLabels = Set(labels)
                    nextNumber = Self.highestSpeakerNumber(inTranscript: existingTranscript, existingLabels: labels) + 1
                } else {
                    existingLabels = []
                    nextNumber = 1
                }
                let speakers = observations.filter { !SpeakerVoiceprintMatcher.reservedLabels.contains($0.label) }
                let matches = SpeakerVoiceprintMatcher.match(
                    candidates: speakers.map { .init(label: $0.label, centroid: $0.centroid) },
                    profiles: try loadMatcherProfiles(db: db)
                )
                let names = try profileNames(ids: Array(matches.values), db: db)
                var rendered: [String: String] = [:]
                var usedLabels = existingLabels
                for speaker in speakers {
                    let assignedSpeakerLabel: String
                    if preservingExisting,
                       usedLabels.contains(speaker.label) || Self.highestSpeakerNumber(inTranscript: "", existingLabels: [speaker.label]) > 0 && Self.highestSpeakerNumber(inTranscript: "", existingLabels: [speaker.label]) < nextNumber {
                        while usedLabels.contains("Speaker \(nextNumber)") { nextNumber += 1 }
                        assignedSpeakerLabel = "Speaker \(nextNumber)"
                        nextNumber += 1
                    } else {
                        assignedSpeakerLabel = speaker.label
                    }
                    usedLabels.insert(assignedSpeakerLabel)
                    let profileID = matches[speaker.label]
                    let name = profileID.flatMap { names[$0] }
                    let label = renderNames ? (name ?? assignedSpeakerLabel) : assignedSpeakerLabel
                    if renderNames, let name { rendered[speaker.label] = name }
                    let embedding = speaker.centroid.flatMap { SpeakerVoiceprintMatcher.isUsable($0) ? SpeakerIdentitySQL.encode($0) : nil }
                    try SpeakerIdentitySQL.execute(
                        """
                        INSERT INTO meeting_speakers (meeting_id, label, embedding, profile_id)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(meeting_id, label) DO UPDATE SET
                          embedding = COALESCE(meeting_speakers.embedding, excluded.embedding),
                          profile_id = COALESCE(meeting_speakers.profile_id, excluded.profile_id)
                        """,
                        [.integer(meetingID), .text(label), embedding.map { .blob($0) } ?? .null, profileID.map { .integer($0) } ?? .null],
                        db: db
                    )
                }
                return rendered
            }
        }
    }

    // MARK: Reads

    public func meetingSpeakers(meetingID: Int64) throws -> [MeetingSpeaker] {
        try withChatDatabase { db in
            try SpeakerIdentitySQL.rows("""
            SELECT ms.label, ms.profile_id, sp.name, ms.embedding IS NOT NULL,
                   EXISTS(SELECT 1 FROM speaker_voiceprints v WHERE v.profile_id = ms.profile_id AND v.source_meeting_id = ms.meeting_id)
            FROM meeting_speakers ms LEFT JOIN speaker_profiles sp ON sp.id = ms.profile_id
            WHERE ms.meeting_id = ?
            ORDER BY ms.rowid
            """, [.integer(meetingID)], db: db) { statement in
                MeetingSpeaker(
                    label: SpeakerIdentitySQL.text(statement, 0) ?? "",
                    profileID: SpeakerIdentitySQL.integer(statement, 1),
                    profileName: SpeakerIdentitySQL.text(statement, 2),
                    hasVoiceprintSource: sqlite3_column_int(statement, 3) != 0,
                    hasVoiceprintFromMeeting: sqlite3_column_int(statement, 4) != 0
                )
            }
        }
    }

    public func speakerProfiles() throws -> [SpeakerProfileSummary] {
        try withChatDatabase { db in
            try SpeakerIdentitySQL.rows("""
            SELECT p.id, p.name,
                   (SELECT COUNT(*) FROM speaker_voiceprints v WHERE v.profile_id = p.id),
                   (SELECT COUNT(DISTINCT ms.meeting_id) FROM meeting_speakers ms WHERE ms.profile_id = p.id)
            FROM speaker_profiles p
            ORDER BY p.name COLLATE NOCASE
            """, db: db) { statement in
                SpeakerProfileSummary(
                    id: sqlite3_column_int64(statement, 0),
                    name: SpeakerIdentitySQL.text(statement, 1) ?? "",
                    voiceprintCount: Int(sqlite3_column_int64(statement, 2)),
                    meetingCount: Int(sqlite3_column_int64(statement, 3))
                )
            }
        }
    }

    // MARK: Naming

    /// Names a meeting speaker ("This is Alex"). In one transaction: finds or creates the
    /// profile (case-insensitive, so an existing name merges), rewrites the label in the
    /// raw transcript unless the meeting is private, stores this meeting's centroid as a
    /// voiceprint, and moves any voiceprint this meeting gave a previous profile.
    /// Repeating the same call is a no-op.
    @discardableResult
    public func assignSpeaker(meetingID: Int64, label: String, name rawName: String) throws -> SpeakerAssignmentResult {
        let name = try Self.validatedSpeakerName(rawName)
        guard !SpeakerVoiceprintMatcher.reservedLabels.contains(label) else { throw SpeakerIdentityError.reservedLabel }
        let isPrivate = try isMeetingPrivate(id: meetingID)
        return try withChatDatabase { db in
            try SpeakerIdentitySQL.transaction(db: db) {
                try assignSpeaker(meetingID: meetingID, label: label, name: name, rewrite: !isPrivate, db: db)
            }
        }
    }

    private func assignSpeaker(meetingID: Int64, label: String, name: String, rewrite: Bool, db: OpaquePointer?) throws -> SpeakerAssignmentResult {
        let profileID = try findOrCreateProfile(named: name, db: db)
        let profileName = try profileNames(ids: [profileID], db: db)[profileID] ?? name
        guard let row = try meetingSpeakerRow(meetingID: meetingID, label: label, db: db) else {
            return try alreadyAssigned(meetingID: meetingID, label: profileName, profileID: profileID, db: db)
        }
        let newLabel = rewrite ? profileName : label
        if newLabel != label, try meetingSpeakerRow(meetingID: meetingID, label: newLabel, db: db) != nil {
            throw SpeakerIdentityError.nameInUseInMeeting
        }
        if try profileAssignedElsewhereInMeeting(meetingID: meetingID, profileID: profileID, label: label, db: db) {
            throw SpeakerIdentityError.nameInUseInMeeting
        }
        if let previous = row.profileID, previous != profileID {
            try forgetVoiceprints(profileID: previous, sourceMeetingID: meetingID, db: db)
        }
        let stored = try storeVoiceprint(row.embedding, profileID: profileID, meetingID: meetingID, db: db)
        try SpeakerIdentitySQL.execute(
            "UPDATE meeting_speakers SET label = ?, profile_id = ? WHERE meeting_id = ? AND label = ?",
            [.text(newLabel), .integer(profileID), .integer(meetingID), .text(label)], db: db
        )
        let rewritten = newLabel != label ? try rewriteTranscriptLabel(meetingID: meetingID, from: label, to: newLabel, db: db) : false
        return SpeakerAssignmentResult(profileID: profileID, profileName: profileName, transcriptRewritten: rewritten, voiceprintStored: stored)
    }

    /// A concurrent or repeated rename already moved the row to the new name.
    private func alreadyAssigned(meetingID: Int64, label: String, profileID: Int64, db: OpaquePointer?) throws -> SpeakerAssignmentResult {
        guard let row = try meetingSpeakerRow(meetingID: meetingID, label: label, db: db), row.profileID == profileID else {
            throw SpeakerIdentityError.speakerNotFound
        }
        return SpeakerAssignmentResult(profileID: profileID, profileName: label, transcriptRewritten: false, voiceprintStored: false)
    }

    // MARK: Forget / delete

    /// Deletes voiceprints of a profile; the profile stays. `sourceMeetingID == nil`
    /// forgets every voiceprint of the person.
    public func forgetVoiceprints(profileID: Int64, sourceMeetingID: Int64?) throws {
        try withChatDatabase { db in
            try forgetVoiceprints(profileID: profileID, sourceMeetingID: sourceMeetingID, db: db)
        }
    }

    /// Deletes the person. Voiceprints cascade; meeting rows keep their label (the typed
    /// name stays in transcripts) with `profile_id` set to NULL.
    public func deleteSpeakerProfile(id: Int64) throws {
        try withChatDatabase { db in
            try SpeakerIdentitySQL.execute("DELETE FROM speaker_profiles WHERE id = ?", [.integer(id)], db: db)
        }
    }

    // MARK: Transcript rewrite

    /// Replaces `label` only where it is the speaker prefix of a transcript line
    /// (`[HH:MM:SS] label: `). Body text and longer labels ("Speaker 12") are untouched.
    public static func rewriteSpeakerLabel(in transcript: String, from label: String, to replacement: String) -> String {
        let pattern = "(?m)^(\\[\\d{2}:\\d{2}:\\d{2}\\] )" + NSRegularExpression.escapedPattern(for: label) + "(?=: )"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return transcript }
        let template = "$1" + NSRegularExpression.escapedTemplate(for: replacement)
        let range = NSRange(transcript.startIndex..., in: transcript)
        return regex.stringByReplacingMatches(in: transcript, range: range, withTemplate: template)
    }

    static func validatedSpeakerName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SpeakerIdentityError.emptyName }
        // A name becomes a transcript line prefix, so it must not break that format.
        guard !isReservedSpeakerName(name), !name.contains(":"), !name.contains(where: \.isNewline) else {
            throw SpeakerIdentityError.reservedName
        }
        return name
    }

    static func isReservedSpeakerName(_ name: String) -> Bool {
        if SpeakerVoiceprintMatcher.reservedLabels.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return true
        }
        return name.range(of: "^speaker \\d+$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Private helpers

    private struct MeetingSpeakerRow {
        let embedding: Data?
        let profileID: Int64?
    }

    private func meetingSpeakerRow(meetingID: Int64, label: String, db: OpaquePointer?) throws -> MeetingSpeakerRow? {
        try SpeakerIdentitySQL.rows(
            "SELECT embedding, profile_id FROM meeting_speakers WHERE meeting_id = ? AND label = ?",
            [.integer(meetingID), .text(label)], db: db
        ) { MeetingSpeakerRow(embedding: SpeakerIdentitySQL.blob($0, 0), profileID: SpeakerIdentitySQL.integer($0, 1)) }.first
    }

    private func profileAssignedElsewhereInMeeting(meetingID: Int64, profileID: Int64, label: String, db: OpaquePointer?) throws -> Bool {
        try !SpeakerIdentitySQL.rows(
            "SELECT 1 FROM meeting_speakers WHERE meeting_id = ? AND profile_id = ? AND label <> ?",
            [.integer(meetingID), .integer(profileID), .text(label)], db: db
        ) { _ in () }.isEmpty
    }

    private func findOrCreateProfile(named name: String, db: OpaquePointer?) throws -> Int64 {
        try SpeakerIdentitySQL.execute(
            "INSERT OR IGNORE INTO speaker_profiles (name, created_at) VALUES (?, ?)",
            [.text(name), .real(Date().timeIntervalSince1970)], db: db
        )
        let ids = try SpeakerIdentitySQL.rows(
            "SELECT id FROM speaker_profiles WHERE name = ? COLLATE NOCASE", [.text(name)], db: db
        ) { sqlite3_column_int64($0, 0) }
        guard let id = ids.first else { throw SpeakerIdentityError.speakerNotFound }
        return id
    }

    private func profileNames(ids: [Int64], db: OpaquePointer?) throws -> [Int64: String] {
        var names: [Int64: String] = [:]
        for id in Set(ids) {
            let rows = try SpeakerIdentitySQL.rows("SELECT name FROM speaker_profiles WHERE id = ?", [.integer(id)], db: db) {
                SpeakerIdentitySQL.text($0, 0)
            }
            names[id] = rows.first ?? nil
        }
        return names
    }

    private func storeVoiceprint(_ embedding: Data?, profileID: Int64, meetingID: Int64, db: OpaquePointer?) throws -> Bool {
        guard let embedding else { return false }
        let vector = SpeakerIdentitySQL.decode(embedding)
        guard SpeakerVoiceprintMatcher.isUsable(vector) else { return false }
        let existing: [()] = try SpeakerIdentitySQL.rows(
            "SELECT 1 FROM speaker_voiceprints WHERE profile_id = ? AND source_meeting_id = ?",
            [.integer(profileID), .integer(meetingID)], db: db
        ) { _ in () }
        guard existing.isEmpty else { return true }
        try SpeakerIdentitySQL.execute(
            "INSERT INTO speaker_voiceprints (profile_id, embedding, dimension, source_meeting_id, created_at) VALUES (?, ?, ?, ?, ?)",
            [.integer(profileID), .blob(embedding), .integer(Int64(vector.count)), .integer(meetingID), .real(Date().timeIntervalSince1970)],
            db: db
        )
        return true
    }

    private func forgetVoiceprints(profileID: Int64, sourceMeetingID: Int64?, db: OpaquePointer?) throws {
        if let sourceMeetingID {
            try SpeakerIdentitySQL.execute(
                "DELETE FROM speaker_voiceprints WHERE profile_id = ? AND source_meeting_id = ?",
                [.integer(profileID), .integer(sourceMeetingID)], db: db
            )
        } else {
            try SpeakerIdentitySQL.execute("DELETE FROM speaker_voiceprints WHERE profile_id = ?", [.integer(profileID)], db: db)
        }
    }

    private func loadMatcherProfiles(db: OpaquePointer?) throws -> [SpeakerVoiceprintMatcher.Profile] {
        let rows = try SpeakerIdentitySQL.rows(
            "SELECT profile_id, embedding FROM speaker_voiceprints ORDER BY profile_id, id", db: db
        ) { (sqlite3_column_int64($0, 0), SpeakerIdentitySQL.blob($0, 1).map(SpeakerIdentitySQL.decode) ?? []) }
        let grouped = Dictionary(grouping: rows, by: \.0)
        return grouped.keys.sorted().map { id in
            SpeakerVoiceprintMatcher.Profile(id: id, voiceprints: grouped[id]?.map(\.1) ?? [])
        }
    }

    private func rewriteTranscriptLabel(meetingID: Int64, from label: String, to name: String, db: OpaquePointer?) throws -> Bool {
        let rows = try SpeakerIdentitySQL.rows(
            "SELECT COALESCE(raw_transcript, ''), COALESCE(manual_notes, '') FROM meetings WHERE id = ?",
            [.integer(meetingID)], db: db
        ) { (SpeakerIdentitySQL.text($0, 0) ?? "", SpeakerIdentitySQL.text($0, 1) ?? "") }
        guard let (transcript, manualNotes) = rows.first else { throw SpeakerIdentityError.meetingNotFound }
        let rewritten = Self.rewriteSpeakerLabel(in: transcript, from: label, to: name)
        guard rewritten != transcript else { return false }
        let wordCount = Self.countWords(in: rewritten) + Self.countWords(in: manualNotes)
        try SpeakerIdentitySQL.execute(
            "UPDATE meetings SET raw_transcript = ?, word_count = ?, updated_at = ?, sync_dirty = 1 WHERE id = ?",
            [.text(rewritten), .integer(Int64(wordCount)), .real(Date().timeIntervalSince1970), .integer(meetingID)], db: db
        )
        return true
    }
}
