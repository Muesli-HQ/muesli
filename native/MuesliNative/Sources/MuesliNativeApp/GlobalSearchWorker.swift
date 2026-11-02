import Foundation
import SQLite3
import MuesliCore

/// App-owned validation keeps derived answers/recaps out of search after their evidence changes.
/// UI integration must discard superseded requests and refresh on source mutation before publication.
actor GlobalSearchWorker {
    private let databaseURL: URL
    private let screenRoot: URL?
    private var service: GlobalSearchService?
    private let mainMonitor: GlobalSearchDatabaseMonitor
    private let screenMonitor: GlobalSearchDatabaseMonitor?
    private var screenStore: VisualMemoryStore?
    private var screenRevision: Int64?
    private var screenIdentity: String?
    private var mainIdentity: String?
    private var screenRetryAt: Date?
    private var screenRetryDelay: TimeInterval = 5
    private var retryRevision: Int64 = 0
    private let now: @Sendable () -> Date
    private let openScreen: @Sendable (URL) throws -> VisualMemoryStore

    init(databaseURL: URL, screenRoot: URL?, now: @escaping @Sendable () -> Date = { Date() },
         openScreen: @escaping @Sendable (URL) throws -> VisualMemoryStore = { try VisualMemoryStore(root: $0, readOnly: true) }) {
        self.databaseURL = databaseURL
        self.screenRoot = screenRoot
        mainMonitor = GlobalSearchDatabaseMonitor(url: databaseURL, required: true)
        screenMonitor = screenRoot.map { GlobalSearchDatabaseMonitor(url: $0.appendingPathComponent("catalog.sqlite"), required: false) }
        self.openScreen = openScreen
        self.now = now
    }

    private func scheduleRetryIfDue() {
        if let screenRetryAt, screenRetryAt <= now() {
            screenRevision = nil; self.screenRetryAt = nil; retryRevision += 1
        }
    }

    func changeToken() throws -> [Int64] {
        scheduleRetryIfDue()
        return try [mainMonitor.revision()] + (screenMonitor.map { [try $0.revision()] } ?? []) + [retryRevision]
    }

    func search(_ query: GlobalSearchQuery) throws -> [GlobalSearchResult] {
        _ = try mainMonitor.revision()
        if service == nil || mainIdentity != mainMonitor.fileIdentity {
            service = try GlobalSearchService(databaseURL: databaseURL)
            mainIdentity = mainMonitor.fileIdentity
        }
        if query.kinds.contains(.screenHistory), let screenMonitor, let screenRoot {
            scheduleRetryIfDue()
            let revision = try screenMonitor.revision()
            if screenRevision != revision {
                if !screenMonitor.isAvailable || screenIdentity != screenMonitor.fileIdentity { screenStore = nil }
                if screenStore == nil, screenMonitor.isAvailable {
                    do {
                        screenStore = try openScreen(screenRoot)
                        screenRetryAt = nil; screenRetryDelay = 5
                    } catch {
                        screenRetryAt = now().addingTimeInterval(screenRetryDelay)
                        screenRetryDelay = min(60, screenRetryDelay * 2)
                    }
                } else if !screenMonitor.isAvailable { screenRetryAt = nil }
                screenIdentity = screenMonitor.fileIdentity
                screenRevision = revision
            }
            if screenMonitor.isPresent && screenStore == nil && query.kinds == [.screenHistory] {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let databaseURL = databaseURL, screenRoot = screenRoot
        let chat = MeetingChatStore(databaseURL: databaseURL)
        guard let service else { return [] }
        return try service.search(query, screenHistoryStore: screenStore) { kind, id in
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

/// A persistent connection compares SQLite data_version across polls. File identity
/// detects replacement; a failed optional catalog is retried only after its file/WAL
/// changes. Transient lock/I/O errors are retried without manufacturing new revisions.
private final class GlobalSearchDatabaseMonitor {
    private let url: URL
    private let required: Bool
    private var db: OpaquePointer?
    private var identity: String?
    var fileIdentity: String? { identity }
    private var failedFingerprint: String?
    private var lastState: String?
    private var counter: Int64 = 0
    private(set) var isAvailable = false
    private(set) var isPresent = false

    init(url: URL, required: Bool) { self.url = url; self.required = required }
    deinit { sqlite3_close(db) }

    private func attributes(_ path: String) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: path)
    }
    private func stamp(_ info: [FileAttributeKey: Any]?) -> String {
        guard let info else { return "missing" }
        return [info[.systemNumber], info[.systemFileNumber], info[.size], info[.modificationDate], info[.posixPermissions]]
            .map { value in (value as? Date).map { String($0.timeIntervalSince1970) } ?? String(describing: value) }.joined(separator: "|")
    }
    private func publish(_ state: String) -> Int64 {
        if state != lastState { counter += 1; lastState = state }
        return counter
    }
    private func close() { sqlite3_close(db); db = nil }

    func revision() throws -> Int64 {
        let info = attributes(url.path)
        isPresent = info != nil
        guard let info else {
            close(); identity = nil; failedFingerprint = nil; isAvailable = false
            if required { throw CocoaError(.fileReadNoSuchFile) }
            return publish("missing")
        }
        let fingerprint = stamp(info) + stamp(attributes(url.path + "-wal"))
        let fileID = "\(String(describing: info[.systemNumber]))|\(String(describing: info[.systemFileNumber]))|\(String(describing: info[.creationDate]))"
        if identity != fileID { close(); identity = fileID; failedFingerprint = nil }
        if failedFingerprint == fingerprint { return publish("unavailable|" + fingerprint) }
        do {
            if db == nil {
                guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                    throw CocoaError(.fileReadUnknown)
                }
                sqlite3_busy_timeout(db, 5000)
            }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadUnknown) }
            let version = sqlite3_column_int64(statement, 0)
            isAvailable = true; failedFingerprint = nil
            return publish("available|\(fileID)|\(version)")
        } catch {
            let code = sqlite3_errcode(db)
            // Reopening on each poll is useful only for transient failures. Retain
            // a file fingerprint for damaged catalogs until there is new content.
            failedFingerprint = [SQLITE_CORRUPT, SQLITE_NOTADB].contains(code) ? fingerprint : nil
            close(); isAvailable = false
            if required { throw error }
            return publish("unavailable|" + fingerprint)
        }
    }
}
