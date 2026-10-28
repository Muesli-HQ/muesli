import AppKit
import Foundation
import MuesliCore
import Testing
import TelemetryDeck
@testable import MuesliNativeApp

@Suite("App-specific dictation formatting")
struct DictationAppFormattingTests {
    @Test("Formatting has exact, repeatable semantics", arguments: [
        ("Hey Sam.", "hey sam"), ("Are you coming?", "are you coming?"),
        ("Great!", "great!"), ("Wait...", "wait..."), ("Wait…", "wait…"),
        ("Hello.\n", "hello\n"), ("One. Two.", "one. two"),
        ("Hello.  ", "hello  "), ("\"Hello.\"", "\"hello.\""), ("(Hello.)", "(hello.)"),
        ("İSTANBUL.", "i\u{307}stanbul"),
        ("API URL: https://EXAMPLE.com/Path.", "api url: https://example.com/path"),
        ("ÉTÉ. Привет. 你好。", "été. привет. 你好。"), ("", ""), (".", "."),
    ])
    func formatting(pair: (String, String)) {
        let result = DictationAppFormatting.lowercaseChat.apply(to: pair.0)
        #expect(result == pair.1)
        #expect(DictationAppFormatting.lowercaseChat.apply(to: result) == result)
        #expect(DictationAppFormatting.unchanged.apply(to: pair.0) == pair.0)
    }

    @Test("Only an exact destination bundle matches")
    func matching() {
        let rules = [DictationAppFormattingRule(bundleID: "net.whatsapp.WhatsApp", appName: "WhatsApp", formatting: .lowercaseChat)]
        #expect(DictationAppFormattingRule.apply("Hi.", bundleID: "net.whatsapp.WhatsApp", rules: rules) == "hi")
        for id in [nil, "com.apple.mail", "net.whatsapp.WhatsApp.fake"] {
            #expect(DictationAppFormattingRule.apply("Hi.", bundleID: id, rules: rules) == "Hi.")
            #expect(!DictationAppFormattingRule.shouldBufferStreaming(bundleID: id, rules: rules))
        }
        #expect(DictationAppFormattingRule.shouldBufferStreaming(bundleID: "net.whatsapp.WhatsApp", rules: rules))
        #expect(!DictationAppFormattingRule.shouldBufferStreaming(bundleID: "unchanged", rules:
            [.init(bundleID: "unchanged", appName: "Unchanged")]))
    }

    #if DEBUG
    @MainActor
    private static let disabledTelemetry: Void = {
        // Production initializes telemetry in AppDelegate. Controller failure
        // callbacks also report diagnostics, but tests must never send analytics.
        let config = TelemetryDeck.Config(appID: "00000000-0000-0000-0000-000000000000")
        config.analyticsDisabled = true
        TelemetryDeck.initialize(config: config)
    }()

    @MainActor
    private func streamingFixture() throws -> (URL, DictationStore, ConfigStore, MuesliController, NSPasteboard) {
        _ = Self.disabledTelemetry
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try database.migrateIfNeeded()
        let store = ConfigStore(supportDirectory: directory)
        var config = AppConfig()
        config.enableDictionaryCorrectionPrompts = true
        config.dictationAppFormattingRules = [.init(bundleID: "start.app", appName: "Start", formatting: .lowercaseChat)]
        if let recipientID = NSRunningApplication.current.bundleIdentifier {
            config.dictationAppFormattingRules.append(.init(bundleID: recipientID, appName: "Recipient", formatting: .lowercaseChat))
        }
        store.save(config)
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: database, configStore: store)
        let board = NSPasteboard(name: .init("muesli-streaming-\(UUID())"))
        board.setString("original clipboard", forType: .string)
        return (directory, database, store, controller, board)
    }

    @Test("Only the starting app controls buffering, even after focus or settings change", arguments: [true, false])
    @MainActor
    func streamingRouting(buffered: Bool) async throws {
        let (directory, database, store, controller, board) = try streamingFixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        var typed = ""
        var pasted = ""
        var monitored: [String] = []
        controller.dictationOutputTestHooks = .init(pasteboard: board, typeText: { typed += $0 },
            dispatchPaste: { _ in pasted += board.string(forType: .string) ?? ""; return true },
            monitorCorrections: { monitored.append($0) })
        let id = controller.startStreamingFormattingForTesting(bundleID: buffered ? "start.app" : "unruled.app")
        controller.receiveStreamingFormattingForTesting("Hello", sessionID: id)
        controller.updateConfig { $0.dictationAppFormattingRules = [] }
        controller.receiveStreamingFormattingForTesting("Hello.", sessionID: id)
        #expect(typed == (buffered ? "" : "Hello."))
        let expected = buffered ? DictationAppFormattingRule.apply("Hello.",
            bundleID: NSRunningApplication.current.bundleIdentifier,
            rules: [.init(bundleID: NSRunningApplication.current.bundleIdentifier ?? "", appName: "Recipient", formatting: .lowercaseChat)]) : "Hello."
        if buffered {
            await withCheckedContinuation { continuation in
                controller.dictationOutputTestHooks?.settled = { continuation.resume() }
                controller.finishStreamingFormattingForTesting("Hello.", sessionID: id)
            }
            #expect(pasted == expected + " ")
            #expect(monitored == [expected])
        } else {
            controller.finishStreamingFormattingForTesting("Hello.", sessionID: id)
            #expect(pasted.isEmpty)
            #expect(monitored.isEmpty)
        }
        controller.receiveStreamingFormattingForTesting("Late words.", sessionID: id)
        controller.finishStreamingFormattingForTesting("Duplicate.", sessionID: id)
        let records = try database.recentDictations()
        #expect(records.count == 1)
        #expect(records.first?.rawText == expected)
        #expect(store.load().dictationAppFormattingRules.isEmpty)
        #expect(board.string(forType: .string) == "original clipboard")
    }

    @Test("Buffered failure recovers once; failed paste preserves raw history and newer clipboard", arguments: ["success", "ownership", "dispatch"])
    @MainActor
    func streamingFailure(outcome: String) async throws {
        let (directory, database, _, controller, board) = try streamingFixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        controller.updateConfig { $0.enableAutomaticDiagnosticIssuePrompts = true }
        var deliveries = 0
        var monitored: [String] = []
        var warnings: [String] = []
        controller.dictationOutputTestHooks = .init(pasteboard: board, targetApplication: {
            if outcome == "ownership" { board.clearContents(); board.setString("new copy", forType: .string) }
            return .current
        }, typeText: { _ in Issue.record("Buffered text must not type live") },
            dispatchPaste: { _ in deliveries += 1; return outcome != "dispatch" },
            monitorCorrections: { monitored.append($0) }, warning: { warnings.append($0) })
        let id = controller.startStreamingFormattingForTesting(bundleID: "start.app")
        controller.receiveStreamingFormattingForTesting("Partial words.", sessionID: id)
        await withCheckedContinuation { continuation in
            controller.dictationOutputTestHooks?.settled = { continuation.resume() }
            controller.finishStreamingFormattingForTesting("", sessionID: id, failure: true)
            // Stop completion, repeated failure and late partial must not recover twice.
            controller.finishStreamingFormattingForTesting("Duplicate.", sessionID: id)
            controller.finishStreamingFormattingForTesting("", sessionID: id, failure: true)
            controller.receiveStreamingFormattingForTesting("Late partial.", sessionID: id)
        }
        let records = try database.recentDictations()
        #expect(records.count == 1)
        if outcome == "success" {
            let expected = NSRunningApplication.current.bundleIdentifier == nil ? "Partial words." : "partial words"
            #expect(records.first?.rawText == expected)
            #expect(monitored == [expected])
            #expect(warnings == ["Streaming stopped early. Partial dictation recovered."])
        } else {
            #expect(records.first?.rawText == "Partial words.")
            #expect(records.first?.targetAppBundleID == nil)
            #expect(monitored.isEmpty)
            #expect(warnings == ["Dictation wasn't pasted. Find it in History."])
        }
        #expect(deliveries == (outcome == "ownership" ? 0 : 1))
        #expect(controller.appState.pendingDiagnosticIncident == nil)
        #expect(board.string(forType: .string) == (outcome == "ownership" ? "new copy" : "original clipboard"))
    }

    @Test("Buffered stop retains the spoken unlock and an unruled recipient's original text")
    @MainActor
    func bufferedUnlock() async throws {
        let (directory, database, store, controller, board) = try streamingFixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        var pasted = ""
        controller.dictationOutputTestHooks = .init(pasteboard: board, targetApplication: { nil },
            dispatchPaste: { _ in pasted = board.string(forType: .string) ?? ""; return true })
        let phrase = "I solemnly swear that I am up to no good."
        let id = controller.startStreamingFormattingForTesting(bundleID: "start.app")
        controller.receiveStreamingFormattingForTesting(phrase, sessionID: id)
        await withCheckedContinuation { continuation in
            controller.dictationOutputTestHooks?.settled = { continuation.resume() }
            controller.finishStreamingFormattingForTesting(phrase, sessionID: id)
        }
        #expect(store.load().maraudersMapUnlocked)
        #expect(pasted == phrase + " ")
        #expect(try database.recentDictations().first?.rawText == phrase)
    }

    @Test("Voice notes never buffer for app rules or insert text")
    @MainActor
    func streamingVoiceNote() throws {
        let (directory, database, _, controller, board) = try streamingFixture()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        controller.dictationOutputTestHooks = .init(pasteboard: board,
            typeText: { _ in Issue.record("Voice note typed") },
            dispatchPaste: { _ in Issue.record("Voice note pasted"); return false })
        let id = controller.startStreamingFormattingForTesting(bundleID: "start.app", voiceNote: true)
        controller.receiveStreamingFormattingForTesting("Voice note.", sessionID: id)
        controller.finishStreamingFormattingForTesting("Voice note.", sessionID: id)
        #expect(try database.recentDictations().first?.rawText == "Voice note.")
        #expect(board.string(forType: .string) == "original clipboard")
    }
    #endif

    @Test("Old configs preserve output; rules and setup dismissal round trip")
    func persistence() throws {
        let old = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(old.dictationAppFormattingRules.isEmpty)
        #expect(old.dictationFormattingTemplates.isEmpty)
        #expect(!old.dictationFormattingSetupDismissed)
        var config = old
        config.dictationAppFormattingRules = [.init(bundleID: "test.app", appName: "Test", formatting: .lowercaseChat)]
        config.dictationFormattingTemplates = [.init(id: "saved_test", name: "My chat style", formatting: .lowercaseChat)]
        config.dictationAppFormattingRules[0].templateID = "saved_test"
        config.dictationFormattingSetupDismissed = true
        let restored = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(restored.dictationAppFormattingRules == config.dictationAppFormattingRules)
        #expect(restored.dictationFormattingTemplates == config.dictationFormattingTemplates)
        #expect(restored.dictationFormattingSetupDismissed)
        #expect(DictationAppFormattingRule.activeRules([.init(bundleID: "other", appName: "Other")]).isEmpty)
    }

    @Test("Existing app rules resolve to built-in templates without changing their output")
    func legacyTemplates() throws {
        let rule = try JSONDecoder().decode(DictationAppFormattingRule.self, from:
            Data(#"{"bundleID":"old.app","appName":"Old","formatting":{"letterCase":"lowercase","finalPeriod":"remove"}}"#.utf8))
        #expect(rule.templateID == nil)
        #expect(DictationFormattingTemplate.selected(for: rule, saved: [])?.id == "lowercase_chat")
        let retired = DictationAppFormattingRule(bundleID: "old.app", appName: "Old",
            formatting: .init(letterCase: .lowercase), templateID: "lowercase")
        #expect(DictationFormattingTemplate.selected(for: retired, saved: []) == nil)
        #expect(retired.formatting.apply(to: "Hello.") == "hello.")
        for template in DictationFormattingTemplate.builtIns {
            let rule = DictationAppFormattingRule(bundleID: "test", appName: "Test", formatting: template.formatting)
            #expect(DictationFormattingTemplate.selected(for: rule, saved: [])?.id == template.id)
        }
    }

    @Test("Named templates can be reused without coupling app rules")
    @MainActor
    func reusableTemplates() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try database.migrateIfNeeded()
        let store = ConfigStore(supportDirectory: directory)
        var initial = AppConfig()
        let source = DictationAppFormattingRule(bundleID: "one.app", appName: "One", formatting: .lowercaseChat)
        initial.dictationAppFormattingRules = [source, .init(bundleID: "two.app", appName: "Two")]
        store.save(initial)
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: database, configStore: store)

        try controller.saveDictationFormattingTemplate(name: "  My messages  ", from: source)
        let template = try #require(store.load().dictationFormattingTemplates.first)
        #expect(template.name == "My messages")
        #expect(store.load().dictationAppFormattingRules.first?.templateID == template.id)
        let definition = try #require(controller.settingsDefinitions().first { $0.id == "dictation_format_preset_two.app" })
        #expect(definition.publicDiscovery?.id == "dictation_app_formatting")
        try await controller.applySetting(definition.id, value: template.id)
        #expect(store.load().dictationAppFormattingRules.last?.formatting == .lowercaseChat)
        #expect(store.load().dictationAppFormattingRules.last?.templateID == template.id)

        #expect(throws: (any Error).self) { try controller.saveDictationFormattingTemplate(name: "MY MESSAGES", from: source) }
        #expect(throws: (any Error).self) { try controller.saveDictationFormattingTemplate(name: "Casual", from: source) }
        #expect(throws: (any Error).self) { try controller.saveDictationFormattingTemplate(name: " ", from: source) }

        try await controller.applySetting("dictation_format_case_one.app", value: "unchanged")
        #expect(store.load().dictationAppFormattingRules.first?.templateID == nil)
        #expect(store.load().dictationAppFormattingRules.last?.formatting == .lowercaseChat)
        #expect(store.load().dictationFormattingTemplates.first?.formatting == .lowercaseChat)
        #expect(throws: (any Error).self) { try controller.saveDictationFormattingTemplate(name: "Stale snapshot", from: source) }

        controller.removeDictationFormattingTemplate(id: template.id)
        #expect(store.load().dictationFormattingTemplates.isEmpty)
        #expect(store.load().dictationAppFormattingRules.last?.templateID == nil)
        #expect(store.load().dictationAppFormattingRules.last?.formatting == .lowercaseChat)
        #expect(definition.availability(template.id) != nil)
    }

    @Test("Suggestions rank real app usage and exclude configured or unattributed rows")
    func suggestions() {
        let usage: [InsightsUsage] = [
            .init(id: "unknown", name: "Unknown", sessions: 100, words: 500),
            .init(id: "bundle:net.whatsapp.WhatsApp", name: "WhatsApp", sessions: 3, words: 50),
            .init(id: "bundle:com.apple.mail", name: "Mail", sessions: 9, words: 500),
            .init(id: "name:slack", name: "Slack", sessions: 20, words: 500),
            .init(id: "bundle:", name: "Empty", sessions: 15, words: 500),
        ]
        let ranked = DictationFormattingSuggestion.ranked(usage: usage, excluding: [])
        #expect(ranked.map(\.appName) == ["Mail", "WhatsApp"])
        #expect(!ranked[0].suggestsLowercaseChat)
        #expect(ranked[1].suggestsLowercaseChat)
        #expect(DictationFormattingSuggestion.ranked(usage: usage,
            excluding: [.init(bundleID: "com.apple.mail", appName: "Mail")]).count == 1)
    }

    @Test("Output formatting uses the dispatch target and preserves clipboard restoration")
    @MainActor
    func pasteIntegration() async {
        let board = NSPasteboard(name: .init("muesli-app-format-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("previous clipboard", forType: .string)
        var delivered = ""
        var prepared = ""
        var targetRead = false
        var preparationCount = 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PasteController.paste(text: "Hey Sam.", appendDictationSentenceSpace: true,
                prepareTextForTarget: { text, target in
                    #expect(targetRead)
                    #expect(target?.processIdentifier == NSRunningApplication.current.processIdentifier)
                    preparationCount += 1
                    return DictationAppFormatting.lowercaseChat.apply(to: text)
                }, onTextPrepared: { prepared = $0 }, pasteboard: board,
                requireStagedClipboardOwnership: true,
                targetApplicationProvider: { targetRead = true; return .current },
                simulatePasteAction: { _ in delivered = board.string(forType: .string) ?? ""; return true },
                onClipboardSettled: { continuation.resume() })
        }
        #expect(delivered == "hey sam ")
        #expect(prepared == "hey sam")
        #expect(preparationCount == 1)
        #expect(board.string(forType: .string) == "previous clipboard")
    }

    @Test("Formatting never overwrites a newer clipboard owner")
    @MainActor
    func clipboardOwnership() async {
        let board = NSPasteboard(name: .init("muesli-format-owner-\(UUID())"))
        defer { board.releaseGlobally() }
        var formatted = false
        var dispatched = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PasteController.paste(text: "Hi.", prepareTextForTarget: { text, _ in formatted = true; return text.lowercased() },
                pasteboard: board, requireStagedClipboardOwnership: true,
                targetApplicationProvider: { board.clearContents(); board.setString("new owner", forType: .string); return nil },
                simulatePasteAction: { _ in dispatched = true; return true },
                onClipboardSettled: { continuation.resume() })
        }
        #expect(!formatted)
        #expect(!dispatched)
        #expect(board.string(forType: .string) == "new owner")
    }

    @Test("Canonical controls persist changes without exposing app names in discovery")
    @MainActor
    func canonicalSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = DictationStore(databaseURL: directory.appendingPathComponent("muesli.db"))
        try database.migrateIfNeeded()
        let store = ConfigStore(supportDirectory: directory)
        var initial = AppConfig()
        initial.dictationAppFormattingRules = [.init(bundleID: "private.app", appName: "Private App")]
        store.save(initial)
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: database, configStore: store)
        let definition = try #require(controller.settingsDefinitions().first { $0.id == "dictation_format_preset_private.app" })
        #expect(definition.publicDiscovery?.id == "dictation_app_formatting")
        try await controller.applySetting(definition.id, value: "lowercase_chat")
        #expect(store.load().dictationAppFormattingRules.first?.formatting == .lowercaseChat)
        #expect(!definition.choices.contains { $0.id == "lowercase" })
        try await controller.applySetting("dictation_format_period_private.app", value: "keep")
        #expect(definition.read(store.load()) == "Custom")
        #expect(store.load().dictationAppFormattingRules.first?.formatting.apply(to: "Hello.") == "hello.")
        try await controller.applySetting(definition.id, value: "unchanged")
        #expect(store.load().dictationAppFormattingRules.isEmpty)
        #expect(definition.availability("lowercase_chat") != nil)

        // The app can be customized again after resetting its rule.
        controller.addDictationFormattingApp(bundleID: "private.app", name: "Private App")
        try await controller.applySetting("dictation_format_period_private.app", value: "remove")
        #expect(store.load().dictationAppFormattingRules.first?.formatting.finalPeriod == .remove)
        try await controller.applySetting("dictation_format_period_private.app", value: "keep")
        #expect(store.load().dictationAppFormattingRules.isEmpty)
    }
}
