import Foundation
import SQLite3
import MuesliCore

/// App-owned validation keeps derived answers/recaps out of search after their evidence changes.
/// UI integration must discard superseded requests and refresh on source mutation before publication.
actor GlobalSearchWorker {
    private let databaseURL: URL
    private let screenRoot: URL?
    private var service: GlobalSearchService?
    private var attachedScreenHistory = false
    private var changeMonitor: GlobalSearchChangeMonitor?

    init(databaseURL: URL, screenRoot: URL?) {
        self.databaseURL = databaseURL
        self.screenRoot = screenRoot
    }

    func changeToken() throws -> [Int64] {
        if changeMonitor == nil {
            changeMonitor = GlobalSearchChangeMonitor(urls: [databaseURL] +
                (screenRoot.map { [$0.appendingPathComponent("catalog.sqlite")] } ?? []))
        }
        return try changeMonitor!.token()
    }

    func search(_ query: GlobalSearchQuery) throws -> [GlobalSearchResult] {
        let screenExists = screenRoot.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("catalog.sqlite").path) } ?? false
        if service == nil || screenExists != attachedScreenHistory {
            let screen = try screenRoot.flatMap { root -> VisualMemoryStore? in
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent("catalog.sqlite").path) else { return nil }
                return try VisualMemoryStore(root: root, readOnly: true)
            }
            service = try GlobalSearchService(databaseURL: databaseURL, screenHistory: screen)
            attachedScreenHistory = screen != nil
        }
        let databaseURL = databaseURL, screenRoot = screenRoot
        let chat = MeetingChatStore(databaseURL: databaseURL)
        guard let service else { return [] }
        return try service.search(query) { kind, id in
            switch kind {
            case .chat:
                guard let sessionID = UUID(uuidString: id) else { return false }
                let turns = try chat.turns(sessionID: sessionID)
                guard !turns.isEmpty, !turns.contains(where: { $0.state == .sourceDeleted }) else { return false }
                for turn in turns where turn.state == .completed {
                    guard try chat.dependenciesAreCurrent(chat.dependencies(turnID: turn.id)) else { return false }
                }
                return true
            case .recap:
                guard let saved = try TimeTurnerRecapStore(databaseURL: databaseURL).load(key: id) else { return false }
                return try TimeTurnerRecap.sourcesAreCurrent(saved.sources, root: screenRoot, databaseURL: databaseURL)
            default:
                return false
            }
        }
    }
}

/// Resolved from the source store at activation time, never from the cached search snippet.
enum GlobalSearchDestination: Sendable {
    case text(String)
    case meeting(MeetingRecord)
    case chat(UUID)
    case capture(VisualMemoryItem)
    case recap(SavedTimeTurnerRecap)
}

extension GlobalSearchWorker {
    func destination(for result: GlobalSearchResult) throws -> GlobalSearchDestination? {
        let store = DictationStore(databaseURL: databaseURL)
        switch result.kind {
        case .dictation, .command:
            guard let id = Int64(result.sourceID), let record = try store.dictation(id: id) else { return nil }
            return .text(record.rawText)
        case .quill:
            guard let id = Int64(result.sourceID), let record = try store.quillConversation(id: id) else { return nil }
            return .text(record.turns.map { [$0.question, $0.answer].compactMap { $0 }.joined(separator: "\n\n") }.joined(separator: "\n\n—\n\n"))
        case .cotypist:
            guard let id = Int64(result.sourceID), let record = try store.cotypistSession(id: id) else { return nil }
            return .text(record.acceptances.map(\.text).joined(separator: "\n\n"))
        case .meeting:
            guard let id = Int64(result.sourceID), let record = try store.meeting(id: id) else { return nil }
            return .meeting(record)
        case .chat:
            guard let id = UUID(uuidString: result.sourceID) else { return nil }
            let chat = MeetingChatStore(databaseURL: databaseURL)
            let turns = try chat.turns(sessionID: id)
            guard !turns.isEmpty, !turns.contains(where: { $0.state == .sourceDeleted }) else { return nil }
            for turn in turns where turn.state == .completed {
                guard try chat.dependenciesAreCurrent(chat.dependencies(turnID: turn.id)) else { return nil }
            }
            return .chat(id)
        case .screenHistory:
            guard let screenRoot,
                  let capture = try VisualMemoryStore(root: screenRoot, readOnly: true).moment(id: result.sourceID) else { return nil }
            return .capture(capture)
        case .recap:
            guard let recap = try TimeTurnerRecapStore(databaseURL: databaseURL).load(key: result.sourceID),
                  try TimeTurnerRecap.sourcesAreCurrent(recap.sources, root: screenRoot, databaseURL: databaseURL) else { return nil }
            return .recap(recap)
        }
    }
}

/// A persistent read connection makes PRAGMA data_version comparable between polls.
/// No source scans, FTS queries or dependency validation while the data is unchanged.
private final class GlobalSearchChangeMonitor {
    let urls: [URL]
    var connections: [String: OpaquePointer] = [:]
    init(urls: [URL]) { self.urls = urls }
    deinit { for db in connections.values { sqlite3_close(db) } }
    func token() throws -> [Int64] {
        try urls.map { url in
            guard FileManager.default.fileExists(atPath: url.path) else {
                if let old = connections.removeValue(forKey: url.path) { sqlite3_close(old) }
                return -1
            }
            if connections[url.path] == nil {
                var db: OpaquePointer?
                guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                      let db else {
                    if let db { sqlite3_close(db) }
                    throw CocoaError(.fileReadUnknown)
                }
                sqlite3_busy_timeout(db, 5000)
                connections[url.path] = db
            }
            let db = connections[url.path]
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
            return sqlite3_column_int64(statement, 0)
        }
    }
}
