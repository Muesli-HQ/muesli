import Foundation
import MuesliCore
import SQLite3
import Testing
@testable import MuesliNativeApp

@Suite("Cotypist history", .serialized)
struct CotypistHistoryTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-cotypist-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    private func event(_ text: String, accepted: String = "", before: String = "", outcome: CotypistSuggestionEvent.Outcome,
                       app: String = "com.apple.Notes", at seconds: TimeInterval) -> CotypistSuggestionEvent {
        CotypistSuggestionEvent(date: Date(timeIntervalSince1970: 1_790_000_000 + seconds), appBundleID: app,
                                appName: app == "com.apple.Notes" ? "Notes" : "Codex", trigger: "boundary",
                                suggestionText: text, acceptedText: accepted, contextBefore: before, outcome: outcome, firstWordLogProb: -1.2,
                                firstMs: 80, fullMs: 120, contextSource: "field", model: "test")
    }

    @Test("accepted suggestions in one app form a session; quiet spells and other apps start new ones")
    func sessions() throws {
        let store = try makeStore()
        // Not taken, and no session open yet: recorded but not in the timeline.
        #expect(try store.recordCotypistSuggestion(event("maybe", outcome: .ignored, at: 0)) == nil)
        let first = try #require(try store.recordCotypistSuggestion(event("the next word", accepted: "the next word", before: "It can predict ", outcome: .accepted, at: 10)))
        #expect(try store.recordCotypistSuggestion(event("later", outcome: .ignored, at: 20)) == first)
        #expect(try store.recordCotypistSuggestion(event("of a word.", accepted: "of", before: "stuck in the middle ", outcome: .partial, at: 30)) == first)
        let codex = try store.recordCotypistSuggestion(event("tests", accepted: "tests", outcome: .accepted, app: "com.openai.codex", at: 40))
        #expect(codex != first)
        let afterGap = try store.recordCotypistSuggestion(event("again", accepted: "again", outcome: .accepted,
                                                                at: 30 + DictationStore.cotypistSessionGap + 1))
        #expect(afterGap != first)

        let session = try #require(try store.cotypistSession(id: first))
        #expect(session.targetAppName == "Notes")
        #expect(session.acceptances == [CotypistAcceptance(contextBefore: "It can predict ", text: "the next word"),
                                        CotypistAcceptance(contextBefore: "stuck in the middle ", text: "of")])
        #expect(session.wordsAccepted == 4)
        #expect(session.suggestionsShown == 3)
        #expect(session.suggestionsAccepted == 2)
    }

    @Test("sessions appear in the timeline, follow the app filter, and can be removed")
    func timeline() throws {
        let store = try makeStore()
        let id = try #require(try store.recordCotypistSuggestion(event("the next word", accepted: "the next word", outcome: .accepted, at: 0)))
        _ = try store.insertDictation(text: "dictated", durationSeconds: 1, targetAppName: "Codex", targetAppBundleID: "com.openai.codex",
                                      startedAt: Date(timeIntervalSince1970: 1_790_000_100), endedAt: Date(timeIntervalSince1970: 1_790_000_101))

        let all = try store.timelineEntries(limit: 10)
        #expect(all.map(\.id) == ["dictation:1", "cotypist:\(id)"])
        let notes = try store.timelineEntries(limit: 10, targetApplication: DictationTargetApplication(name: "Notes", bundleID: "com.apple.Notes"))
        #expect(notes.map(\.id) == ["cotypist:\(id)"])
        #expect(try store.timelineEntries(limit: 10, origin: .fromIPhone).isEmpty)
        // Notes has only Cotypist history: a timeline filter choice, not a dictation one.
        #expect(try store.dictationTargetApplications().map(\.name) == ["Codex"])
        #expect(try store.timelineTargetApplications().map(\.name) == ["Codex", "Notes"])

        try store.deleteCotypistSession(id: id)
        #expect(try store.timelineEntries(limit: 10).map(\.id) == ["dictation:1"])
    }

    @Test("keeps the user's sentence only for accepted suggestions, removes it with the session, prunes old untaken ones")
    func privacy() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-cotypist-test-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        // Old enough to fall outside retention, and not taken: pruned by the next write.
        _ = try store.recordCotypistSuggestion(event("stale", before: "private draft ", outcome: .ignored,
                                                     at: -DictationStore.cotypistUnacceptedRetention - 60))
        let id = try #require(try store.recordCotypistSuggestion(event("the next word", accepted: "the next word",
                                                                       before: "It can predict ", outcome: .accepted, at: 0)))
        _ = try store.recordCotypistSuggestion(event("maybe", before: "a sentence I typed ", outcome: .ignored, at: 5))
        let otherApp = try #require(try store.recordCotypistSuggestion(event("elsewhere", accepted: "elsewhere", before: "In Codex ",
                                                                             outcome: .accepted, app: "com.openai.codex", at: 6)))

        func rows() throws -> [(String, String)] {
            var db: OpaquePointer?
            sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT suggestion_text, context_before FROM cotypist_suggestions ORDER BY id", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            var result: [(String, String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append((String(cString: sqlite3_column_text(statement, 0)), String(cString: sqlite3_column_text(statement, 1))))
            }
            return result
        }
        #expect(try rows().map(\.0) == ["the next word", "maybe", "elsewhere"])
        #expect(try rows().map(\.1) == ["It can predict ", "", "In Codex "])

        // Removing one session removes its rows and text, and nothing from another app's session.
        try store.deleteCotypistSession(id: id)
        #expect(try rows().map(\.0) == ["elsewhere"])
        #expect(try store.cotypistSession(id: id) == nil)
        #expect(try store.cotypistSession(id: otherApp)?.acceptances.map(\.text) == ["elsewhere"])
    }

    @Test("prunes old untaken suggestions without waiting for a new one")
    func pruneWithoutWrites() throws {
        let store = try makeStore()
        _ = try store.recordCotypistSuggestion(event("stale", outcome: .ignored, at: 0))
        let session = try #require(try store.recordCotypistSuggestion(event("kept", accepted: "kept", outcome: .accepted, at: 1)))
        try store.pruneCotypistHistory(now: Date(timeIntervalSince1970: 1_790_000_000 + DictationStore.cotypistUnacceptedRetention + 60))
        // The untaken suggestion is gone; the accepted one stays with its session.
        #expect(try store.cotypistSession(id: session)?.suggestionsShown == 1)
    }

    @Test("a newer request from the same helper supersedes older ones; other helpers are unaffected")
    func supersededRequests() {
        let ledger = CotypistRequestLedger()
        let first = ledger.note(client: "notes", generation: 4)
        let other = ledger.note(client: "codex", generation: 1)
        #expect(first())
        let second = ledger.note(client: "notes", generation: 5)
        #expect(!first())
        #expect(second())
        #expect(other())
        #expect(ledger.note(client: nil, generation: nil)())
    }

    @Test("with many helpers, forgets the least recently active one, not the others")
    func ledgerEviction() {
        let ledger = CotypistRequestLedger()
        let first = ledger.note(client: "notes", generation: 4)
        for index in 0..<63 { _ = ledger.note(client: "app\(index)", generation: 1) }
        _ = ledger.note(client: "notes", generation: 5)
        _ = ledger.note(client: "one more", generation: 1)  // 65 helpers: app0 is forgotten
        #expect(!first())
    }

    @Test("a build without the input method refuses every Cotypist setting and downloads nothing")
    @MainActor
    func settingsNeedTheBundledHelper() async throws {
        #expect(!CotypistSetup.isAvailable)  // the test runner bundles no helper
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try store.migrateIfNeeded()
        let controller = MuesliController(
            runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: ConfigStore(supportDirectory: directory))
        let changes = ["cotypist_enabled": "on", "cotypist_model": CotypistModel.qwen35_2b.rawValue,
                       "cotypist_length": CotypistSuggestionLength.allCases.last!.rawValue,
                       "cotypist_frequency": CotypistFrequency.allCases.last!.rawValue,
                       "cotypist_complete_words": controller.config.cotypistCompleteWords ? "off" : "on",
                       "cotypist_word_pause": CotypistWordPause.allCases.last!.rawValue,
                       "cotypist_screen_context": controller.config.cotypistUseScreenContext ? "off" : "on"]
        let before = controller.config
        for (id, value) in changes {
            await #expect(throws: (any Error).self, "\(id)") { try await controller.applySetting(id, value: value) }
        }
        #expect(controller.config.cotypistModel == before.cotypistModel)
        #expect(controller.config.cotypistCompleteWords == before.cotypistCompleteWords)
        CotypistSetup.shared.download(.qwen35_2b)
        if case .downloading = CotypistSetup.shared.state(of: .qwen35_2b) { Issue.record("started a download") }
    }

    @Test("keeps the sentence being written, up to the caret")
    @MainActor
    func sentenceContext() {
        #expect(CotypistService.sentence(endingAt: "Hi team.\nThanks for the notes. Let me know if you have any quest")
                == "Let me know if you have any quest")
        // A sentence only just started reaches back one more.
        #expect(CotypistService.sentence(endingAt: "The numbers look right. I will ") == "The numbers look right. I will ")
        #expect(CotypistService.sentence(endingAt: "word " + String(repeating: "more words ", count: 20), maxCharacters: 30)
                == "…words more words more words ")
        #expect(CotypistService.sentence(endingAt: "") == "")
    }

    @Test("reads the helper's outcome message")
    @MainActor
    func outcomeMessage() throws {
        let message: [String: Any] = ["type": "outcome", "app": "com.example.none", "trigger": "mid-word", "text": "dle of a word.",
                                      "accepted": "dle", "outcome": "partial", "first_ms": 90, "full_ms": 140,
                                      "first_word_logprob": -0.4, "source": "field"]
        let event = try #require(CotypistService.event(from: message))
        #expect(event.outcome == .partial)
        #expect(event.acceptedText == "dle")
        #expect(event.trigger == "mid-word")
        #expect(event.firstMs == 90)
        #expect(event.appName == "")
        #expect(CotypistService.event(from: ["text": "x", "outcome": "bogus"]) == nil)
    }
}
