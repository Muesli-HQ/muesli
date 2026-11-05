import Foundation
import Testing
import MuesliCore
@testable import MuesliCLI
@testable import MuesliNativeApp

@Suite("Muesli history skills")
struct MuesliHistorySkillTests {
    private let day = Date(timeIntervalSince1970: 1_700_000_000)
    private func fixture() throws -> (URL, URL, DictationStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = root.appendingPathComponent("muesli.db")
        let store = DictationStore(databaseURL: db); try store.migrateIfNeeded()
        return (root, db, store)
    }

    @Test func editingATemplateUpdatesTheTaggedSkillWithoutBreakingItsDraft() throws {
        var personal = CustomMeetingTemplate(name: "Commitments", prompt: "List my promises.")
        let original = MuesliHistoryTask.catalog(custom: [personal])
        let skill = try #require(original.first { $0.personal })
        let draft = "$" + skill.id + " from yesterday"
        personal.name = "My commitments"
        personal.prompt = "List only commitments I made."
        let updated = MuesliHistoryTask.catalog(custom: [personal])
        let run = try #require(MuesliSkillInvocation(draft: draft, catalog: updated))
        #expect(run.skill.title == personal.name)
        #expect(try run.skill.loadInstructions() == personal.prompt)
        #expect(SkillTagPresentation.displayText(draft, catalog: updated) == "My commitments from yesterday")
        #expect(MuesliSkillInvocation(draft: draft, catalog: MuesliHistoryTask.catalog(custom: [])) == nil)
    }

    @Test func registryAndCLIDiscoveryAgree() throws {
        #expect(Set(MuesliHistoryTask.allCases.map(\.id)).count == 5)
        #expect(MuesliHistoryTask.allCases.allSatisfy { $0.version == 1 })
        let spec = Set(MuesliCLI.specPayload().commands.map(\.name))
        #expect(Set(["skills list", "skills get", "history sample", "history read"]).isSubset(of: spec))
        #expect(MuesliHistorySkill.markdown.hasPrefix("---\nname: muesli-history"))
        #expect(MuesliHistorySkill.markdown.contains("muesli-cli spec"))
        for task in MuesliHistoryTask.allCases {
            #expect(try SkillsGet.parse([task.id]).id == task.id)
        }
        #expect(throws: (any Error).self) { try HistorySample.date("2026-11-04T12:00:00") }
        #expect(try HistorySample.date("2026-11-04T12:00:00+05:30") == HistorySample.date("2026-11-04T06:30:00Z"))
    }

    @Test func malformedSkillPreferencesReturnStructuredCLIError() throws {
        let (root, _, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.json")
        try Data("{broken".utf8).write(to: config)
        do {
            try SkillsGet.parse(["daily-recap", "--support-dir", root.path]).run()
            Issue.record("Corrupt config should fail")
        } catch let error as CLIError {
            #expect(error.errorBody.code == "database_error")
        }
    }

    @Test func agentDatesUseExplicitTimezoneAndFractionalSeconds() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = historyDateEncoding
        let date = try HistorySample.date("2026-11-04T06:30:00.123Z")
        let encoded = String(decoding: try encoder.encode([date]), as: UTF8.self)
        #expect(encoded.contains("2026-11-04T06:30:00.123Z"))
    }

    @Test func slashDiscoveryFiltersAndPreservesSurroundingDraft() throws {
        func query(_ text: String) -> MuesliSkillQuery? {
            MuesliSkillQuery.find(in: text, selection: NSRange(location: (text as NSString).length, length: 0))
        }
        #expect(query("/")?.matches.count == 5)
        #expect(query("/ski")?.matches.count == 5)
        #expect(query("/project")?.matches == [.projectBrief])
        #expect(query("/no-match")?.matches.isEmpty == true)
        for text in ["/etc", "/v2", "/no-match"] {
            #expect(query(text)?.interceptsSubmission(in: MuesliHistoryTask.allCases) == false)
        }
        #expect(query("/project")?.interceptsSubmission(in: MuesliHistoryTask.allCases) == true)
        #expect(query("https://example.com/") == nil)
        #expect(query("/Users/example") == nil)
        #expect(query("some /project") == nil)
        #expect(query("/project brief") == nil)
        let text = "🦉 My draft\n  /resume"
        let parsed = try #require(query(text))
        #expect(parsed.removing(from: text) == "🦉 My draft\n  ")
        #expect(parsed.removing(from: "different") == "different")
        #expect(MuesliSkillQuery.find(in: "/", selection: NSRange(location: 0, length: 1)) == nil)
        #expect(MuesliSkillQuery.find(in: "/", selection: NSRange(location: NSNotFound, length: 0)) == nil)
    }

    @Test func taggedSkillKeepsFreeformPromptForModel() throws {
        let run = try #require(MuesliSkillInvocation(draft: "$follow-ups What did I promise yesterday?"))
        #expect(run.skill == .followUps)
        #expect(run.prompt == "What did I promise yesterday?")
        #expect(MuesliSkillInvocation(draft: "Explain $follow-ups") == nil)
        #expect(MuesliSkillInvocation(draft: "$unknown") == nil)
    }

    @Test func skillTitlesRoundTripOnlyWhenTagged() throws {
        for skill in MuesliHistoryTask.allCases {
            let raw = "  $" + skill.id + " 🦉 my prompt"
            let tag = try #require(SkillTagPresentation(draft: raw))
            let display = NSMutableAttributedString(string: SkillTagPresentation.displayText(raw))
            #expect(!display.string.contains("$"))
            #expect(SkillTagPresentation.draft(from: display) == display.string)
            display.addAttribute(SkillTagPresentation.attribute, value: skill.id, range: tag.visibleRange)
            #expect(SkillTagPresentation.draft(from: display) == raw)
            let prompt = (raw as NSString).range(of: "🦉 my prompt")
            #expect(tag.displayRange(for: prompt) == (display.string as NSString).range(of: "🦉 my prompt"))
            #expect(tag.draftRange(for: tag.displayRange(for: prompt)) == prompt)
        }
    }

    @Test func samplingIsBoundedAndDoesNotWidenEmptySelection() throws {
        let (root, db, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let visualRoot = root.appendingPathComponent("visual-memory")
        let visual = try VisualMemoryStore(root: visualRoot)
        try visual.save((0..<150).map { n in
            VisualMemoryItem(id: String(n), kind: .moment, capturedAt: day.addingTimeInterval(Double(n) * 500),
                source: "Editor", bundleID: "test", text: "Orion work \(n)", path: "\(n).png")
        })
        for n in 0..<150 {
            _ = try store.insertDictation(text: "Orion dictation \(n)", durationSeconds: 1,
                startedAt: day.addingTimeInterval(Double(n) * 500), endedAt: day.addingTimeInterval(Double(n) * 500))
        }
        let service = MuesliHistoryAccess(databaseURL: db, screenRoot: visualRoot)
        let empty = try service.sample(interval: .init(start: day, duration: 86400), kinds: [])
        #expect(!empty.captures.isEmpty && empty.captures.count <= 36)
        #expect(empty.history.isEmpty && empty.meetings.isEmpty)
        let selected = try service.sample(interval: .init(start: day, duration: 86400), kinds: [.dictations], query: "Orion")
        #expect(!selected.history.isEmpty && selected.history.count <= 12)
        #expect(selected.coverage.contains("Partial"))
        #expect(selected.history.allSatisfy { $0.text.contains("Orion") })
        #expect(try service.sample(interval: .init(start: day, duration: 86400), kinds: [.dictations], query: "NO_MATCH").history.isEmpty)
        #expect(throws: (any Error).self) { try service.sample(interval: .init(start: day, duration: 32 * 86400), kinds: []) }
    }

    @Test func sharedValidationRejectsDeletedOrChangedSources() throws {
        let (root, db, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let id = try store.insertDictation(text: "Orion", durationSeconds: 1, startedAt: day, endedAt: day)
        let access = MuesliHistoryAccess(databaseURL: db, screenRoot: nil)
        let packet = try access.sample(interval: .init(start: day, duration: 86400), kinds: [.dictations])
        #expect(packet.history.count == 1)
        #expect(try access.areCurrent(captures: [], meetings: [], history: packet.history))
        try store.deleteDictation(id: id)
        #expect(try !access.areCurrent(captures: [], meetings: [], history: packet.history))
        #expect(try MuesliHistoryReader(databaseURL: db).read(kind: .dictations, id: String(id)) == nil)
    }

    @Test func unicodeTruncationRetainsFullRevision() throws {
        let (root, db, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = String(repeating: "🦉", count: 5000)
        let id = try store.insertDictation(text: original, durationSeconds: 1, startedAt: day, endedAt: day)
        let source = try #require(try MuesliHistoryReader(databaseURL: db).read(kind: .dictations, id: String(id)))
        #expect(source.textIsTruncated)
        #expect(source.text.utf8.count <= 16000)
        #expect(original.hasPrefix(source.text))
        #expect(try MuesliHistoryReader(databaseURL: db).areCurrent([source]))
    }
}
