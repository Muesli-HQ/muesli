import Foundation
import os
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Dictionary file operation ownership")
struct DictionaryFileOperationsTests {
    private func fixture() throws -> (MuesliController, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = DictationStore(databaseURL: root.appendingPathComponent("test.db"))
        try database.migrateIfNeeded()
        let config = ConfigStore(supportDirectory: root)
        config.save(AppConfig())
        return (MuesliController(runtime: .init(repoRoot: root, menuIcon: nil, appIcon: nil, bundlePath: nil),
                                dictationStore: database, configStore: config), root)
    }

    @Test func importSurvivesNavigationRejectsDuplicatesAndPreservesConcurrentEdits() async throws {
        let (controller, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = Set(controller.config.customWords.map(\.word))
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let original = CustomWord(word: "original", replacement: "Original")
        controller.addCustomWord(original)
        let task = try #require(controller.importDictionary(from: root.appendingPathComponent("input.json")) { _ in
            #expect(!Thread.isMainThread)
            started.withLock { $0 = true }
            _ = release.wait(timeout: .now() + 30)
            return [CustomWord(word: "imported", replacement: "Imported")]
        })
        for _ in 0..<500 where !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
        #expect(started.withLock { $0 })
        controller.appState.selectedTab = .timeline
        controller.appState.selectedTab = .dictionary
        #expect(controller.appState.dictionaryFileOperation == .importing)
        #expect(controller.importDictionary(from: root.appendingPathComponent("second.json")) == nil)
        #expect(controller.exportDictionary(to: root.appendingPathComponent("output.json")) == nil)
        controller.removeCustomWord(id: original.id)
        controller.addCustomWord(CustomWord(word: "concurrent", replacement: "Concurrent"))
        release.signal()
        await task.value
        #expect(Set(controller.config.customWords.map(\.word)) == baseline.union(["imported", "concurrent"]))
        #expect(controller.appState.config.customWords == controller.config.customWords)
        #expect(controller.appState.dictionaryFileOperation == nil)
        #expect(controller.appState.dictionaryFileMessage?.contains("Imported 1 new") == true)
    }

    @Test func exportUsesCurrentConfigAndFailureReleasesTheOperation() async throws {
        let (controller, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        controller.addCustomWord(CustomWord(word: "current", replacement: "Current"))
        let expected = controller.config.customWords.map(\.word)
        let output = root.appendingPathComponent("output.json")
        let export = try #require(controller.exportDictionary(to: output))
        await export.value
        #expect(try CustomWordDictionaryCodec.decode(Data(contentsOf: output)).map(\.word) == expected)
        let failed = try #require(controller.importDictionary(from: root.appendingPathComponent("missing.json")))
        await failed.value
        #expect(controller.appState.dictionaryFileOperation == nil)
        #expect(controller.appState.dictionaryFileMessage?.contains("Could not import") == true)
        #expect(controller.config.customWords.map(\.word) == expected)
    }
}
