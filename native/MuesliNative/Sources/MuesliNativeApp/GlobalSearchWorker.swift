import Foundation
import MuesliCore

/// App-owned validation keeps derived answers/recaps out of search after their evidence changes.
/// UI integration must discard superseded requests and refresh on source mutation before publication.
actor GlobalSearchWorker {
    private let databaseURL: URL
    private let screenRoot: URL?
    private var service: GlobalSearchService?
    private var attachedScreenHistory = false

    init(databaseURL: URL, screenRoot: URL?) {
        self.databaseURL = databaseURL
        self.screenRoot = screenRoot
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
