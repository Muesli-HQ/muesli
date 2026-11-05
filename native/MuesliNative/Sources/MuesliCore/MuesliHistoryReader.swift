import Foundation
import CryptoKit
import SQLite3

/// A bounded, revisioned quote from an optional recap source. Raw CUA traces and
/// unaccepted Cotypist suggestions are never part of this contract.
public struct MuesliHistorySource: Codable, Sendable, Equatable {
    public let kind: MuesliHistoryKind
    public let id: String
    public let parentID: String
    public let date: Date
    public let title: String
    public let text: String
    public let revision: String
    public var textIsTruncated: Bool = false
    public init(kind: MuesliHistoryKind, id: String, parentID: String, date: Date, title: String,
                text: String, revision: String, textIsTruncated: Bool = false) {
        self.kind = kind; self.id = id; self.parentID = parentID; self.date = date
        self.title = title; self.text = text; self.revision = revision; self.textIsTruncated = textIsTruncated
    }
}

/// Read-only source adapter. Uses original records, not a second search index.
/// Construct off the main actor; queries never load an entire application's history.
public final class MuesliHistoryReader {
    private let databaseURL: URL
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db); db = nil }
            throw Self.failure
        }
        sqlite3_busy_timeout(db, 5000)
    }
    deinit { sqlite3_close(db) }
    private static var failure: NSError { .init(domain: "RecapHistory", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "A selected recap source could not be read. Try again or deselect it in Sources."]) }
    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw Self.failure }
        return s
    }
    private func bind(_ value: String, _ s: OpaquePointer?, _ index: Int32) { sqlite3_bind_text(s, index, value, -1, transient) }
    private func exists(_ name: String) throws -> Bool {
        let s = try prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?")
        defer { sqlite3_finalize(s) }; bind(name, s, 1)
        let status = sqlite3_step(s)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw Self.failure }
        return status == SQLITE_ROW
    }
    private func query(_ kind: MuesliHistoryKind) throws -> String? {
        func unix(_ field: String) -> String { "round((julianday(\(field))-2440587.5)*86400.0,3)" }
        switch kind {
        case .meetings: return nil // Uses existing revisioned meeting-passage retrieval.
        case .dictations, .commands:
            guard try exists("dictations") else { return nil }
            let source = kind == .commands ? "cua" : "dictation"
            return """
                SELECT CAST(id AS TEXT) AS id,CAST(id AS TEXT) AS parent_id,\(unix("timestamp")) AS event_time,
                coalesce(target_app_name,'') AS title,coalesce(raw_text,'') AS text
                FROM dictations WHERE deleted_at IS NULL AND coalesce(source,'dictation')='\(source)'
                """
        case .quill:
            guard try exists("quill_conversation_turns"), try exists("quill_conversations") else { return nil }
            return """
                SELECT t.turn_id AS id,CAST(c.id AS TEXT) AS parent_id,
                \(unix("json_extract(t.body,'$.timestamp')")) AS event_time,'Quill' AS title,
                coalesce(json_extract(t.body,'$.question'),'') || char(10) || coalesce(json_extract(t.body,'$.answer'),'') AS text
                FROM quill_conversation_turns t JOIN quill_conversations c ON c.id=t.conversation_id
                WHERE c.deleted_at IS NULL AND json_valid(t.body)
                """
        case .cotypist:
            guard try exists("cotypist_suggestions"), try exists("cotypist_sessions") else { return nil }
            return """
                SELECT CAST(e.id AS TEXT) AS id,CAST(c.id AS TEXT) AS parent_id,\(unix("e.timestamp")) AS event_time,
                c.target_app_name AS title,e.accepted_text AS text
                FROM cotypist_suggestions e JOIN cotypist_sessions c ON c.id=e.session_id
                WHERE c.deleted_at IS NULL AND e.accepted_text!=''
                """
        case .chat:
            guard try exists("meeting_chat_sessions"), try exists("meeting_chat_turns") else { return nil }
            // Chat has no per-turn wall-clock timestamp. Use the conversation's
            // update time and explicitly label this basis in the evidence packet.
            return """
                SELECT c.id AS id,c.id AS parent_id,c.updated_at AS event_time,
                coalesce(json_extract(c.body,'$.title'),'Chat') AS title,
                coalesce((SELECT group_concat(quote,char(10)) FROM (
                    SELECT coalesce(json_extract(t.body,'$.question'),'') || char(10) ||
                        coalesce(json_extract(t.body,'$.originalAnswer'),'') AS quote
                    FROM meeting_chat_turns t WHERE t.session_id=c.id AND t.state='completed' AND json_valid(t.body)
                    ORDER BY t.ordinal
                )),'') AS text FROM meeting_chat_sessions c WHERE json_valid(c.body)
                """
        }
    }

    /// Sample across six equal portions of the day; at most twelve records per
    /// optional class. Sparse sources cannot crowd out screen evidence.
    public func samples(kind: MuesliHistoryKind, interval: DateInterval, query text: String = "") throws -> [MuesliHistorySource] {
        guard let query = try query(kind) else { return [] }
        var output: [MuesliHistorySource] = []
        for bucket in 0..<6 {
            try Task.checkCancellation()
            let start = interval.start.addingTimeInterval(interval.duration * Double(bucket) / 6)
            let end = interval.start.addingTimeInterval(interval.duration * Double(bucket + 1) / 6)
            let s = try prepare("SELECT id,parent_id,event_time,title,text FROM (\(query)) WHERE event_time>=? AND event_time<? AND trim(text)!='' AND (?='' OR instr(lower(text || char(10) || title),lower(?))>0) ORDER BY event_time DESC,id LIMIT 2")
            defer { sqlite3_finalize(s) }
            sqlite3_bind_double(s, 1, start.timeIntervalSince1970); sqlite3_bind_double(s, 2, end.timeIntervalSince1970)
            bind(text, s, 3); bind(text, s, 4)
            var status = sqlite3_step(s)
            while status == SQLITE_ROW {
                let value = record(s, kind: kind)
                if try currentChat(value) { output.append(value) }
                status = sqlite3_step(s)
            }
            guard status == SQLITE_DONE else { throw Self.failure }
        }
        return output.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }

    /// Streaming digest of the selected day's eligible content, including rows
    /// outside the opening sample. Used only on explicit/scheduled recap checks.
    public func recapRevision(kinds: Set<MuesliHistoryKind>, interval: DateInterval) throws -> String {
        var digest = SHA256()
        for kind in MuesliHistoryKind.allCases where kinds.contains(kind) {
            let source: String?
            if kind == .meetings {
                source = try exists("meetings") ? """
                    SELECT CAST(id AS TEXT) AS id,round((julianday(start_time)-2440587.5)*86400.0,3) AS event_time,
                        title,coalesce(raw_transcript,'') || char(10) || coalesce(formatted_notes,'') || char(10) || coalesce(manual_notes,'') AS text
                    FROM meetings WHERE deleted_at IS NULL
                    """ : nil
            } else { source = try query(kind) }
            guard let source else { continue }
            let s = try prepare("SELECT id,event_time,title,text FROM (\(source)) WHERE event_time>=? AND event_time<? ORDER BY event_time,id")
            defer { sqlite3_finalize(s) }
            sqlite3_bind_double(s, 1, interval.start.timeIntervalSince1970)
            sqlite3_bind_double(s, 2, interval.end.timeIntervalSince1970)
            var status = sqlite3_step(s)
            while status == SQLITE_ROW {
                try Task.checkCancellation()
                let fields = [kind.rawValue] + (0..<4).map { column in
                    sqlite3_column_text(s, Int32(column)).map { String(cString: $0) } ?? ""
                }
                digest.update(data: try JSONEncoder().encode(fields))
                status = sqlite3_step(s)
            }
            guard status == SQLITE_DONE else { throw Self.failure }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func read(kind: MuesliHistoryKind, id: String, fullText: Bool = false) throws -> MuesliHistorySource? {
        guard let query = try query(kind) else { return nil }
        let s = try prepare("SELECT id,parent_id,event_time,title,text FROM (\(query)) WHERE id=?")
        defer { sqlite3_finalize(s) }; bind(id, s, 1)
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw Self.failure }
        let value = record(s, kind: kind, fullText: fullText)
        return try currentChat(value) ? value : nil
    }
    public func areCurrent(_ sources: [MuesliHistorySource]) throws -> Bool {
        for old in sources {
            guard let new = try read(kind: old.kind, id: old.id), new.revision == old.revision else { return false }
        }
        return true
    }
    private func record(_ s: OpaquePointer?, kind: MuesliHistoryKind, fullText: Bool = false) -> MuesliHistorySource {
        func text(_ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        let date = Date(timeIntervalSince1970: sqlite3_column_double(s, 2))
        let body = text(4)
        let values = [kind.rawValue, text(0), text(1), String(date.timeIntervalSince1970), text(3), body]
        // Length-delimited encoding avoids ambiguous field boundaries.
        let data = (try? JSONEncoder().encode(values)) ?? Data()
        return .init(kind: kind, id: text(0), parentID: text(1), date: date, title: text(3),
            text: fullText ? body : Self.prefix(body, limit: 16_000),
            revision: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), textIsTruncated: !fullText && body.utf8.count > 16_000)
    }
    private static func prefix(_ text: String, limit: Int) -> String {
        var result = "", bytes = 0
        for scalar in text.unicodeScalars {
            let size = scalar.utf8.count
            guard bytes + size <= limit else { break }
            result.unicodeScalars.append(scalar); bytes += size
        }
        return result
    }
    private func currentChat(_ source: MuesliHistorySource) throws -> Bool {
        guard source.kind == .chat else { return true }
        guard let id = UUID(uuidString: source.id) else { return false }
        let store = MeetingChatStore(databaseURL: databaseURL, readOnly: true)
        let turns = try store.turns(sessionID: id).filter { $0.state == .completed }
        guard !turns.isEmpty else { return false }
        for turn in turns {
            guard try store.dependenciesAreCurrent(store.dependencies(turnID: turn.id)) else { return false }
            // File-derived chat text needs the same live original-file validation
            // as Chat; do not promote unverified attachment answers into a recap.
            let files = (turn.fileDependencies ?? []) + (turn.fileAttachments ?? [])
            if !files.isEmpty { return false }
        }
        return true
    }
}
