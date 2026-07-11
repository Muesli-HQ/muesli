import Foundation
import MuesliCore
import Testing
@testable import MuesliNativeApp

@MainActor
@Suite("Computer Use settings integration")
struct ComputerUseSettingsIntegrationTests {
    @Test("controller applies reversible settings and persists config receipts")
    func appliesAndPersistsReversibleSettings() async throws {
        var initial = AppConfig()
        initial.enableComputerUseHotkey = true
        initial.computerUseTimeoutSeconds = 120
        initial.enablePostProcessor = true
        initial.pauseMediaDuringDictation = false
        initial.muteSystemAudioDuringDictation = false
        initial.showFloatingIndicator = true
        initial.indicatorAnchor = .midTrailing
        initial.soundEnabled = true
        initial.darkMode = false
        initial.openDashboardOnLaunch = true

        let fixture = try makeFixture(config: initial)
        defer { fixture.remove() }

        let calls: [ComputerUseToolCall] = [
            .init(tool: .updateMuesliSettings, operation: .setComputerUseEnabled, enabled: false),
            .init(tool: .updateMuesliSettings, operation: .setComputerUseSafetyLimit, seconds: 300),
            .init(tool: .updateMuesliSettings, operation: .setAICleanup, enabled: false),
            .init(tool: .updateMuesliSettings, operation: .setPauseMediaDuringDictation, enabled: true),
            .init(tool: .updateMuesliSettings, operation: .setMuteSystemAudioDuringDictation, enabled: true),
            .init(tool: .updateMuesliSettings, operation: .setFloatingIndicatorEnabled, enabled: false),
            .init(tool: .updateMuesliSettings, operation: .setFloatingIndicatorPosition, position: "Bottom Center"),
            .init(tool: .updateMuesliSettings, operation: .setSoundEffects, enabled: false),
            .init(tool: .updateMuesliSettings, operation: .setTheme, theme: "dark"),
            .init(tool: .updateMuesliSettings, operation: .setOpenDashboardOnLaunch, enabled: false),
        ]

        for call in calls {
            let result = await fixture.controller.applyComputerUseSettings(call)
            expectChangedConfigReceipt(result)
        }

        let persisted = fixture.configStore.load()
        #expect(!persisted.enableComputerUseHotkey)
        #expect(persisted.computerUseTimeoutSeconds == 300)
        #expect(!persisted.enablePostProcessor)
        #expect(persisted.pauseMediaDuringDictation)
        #expect(persisted.muteSystemAudioDuringDictation)
        #expect(!persisted.showFloatingIndicator)
        #expect(persisted.indicatorAnchor == .bottomCenter)
        #expect(!persisted.soundEnabled)
        #expect(persisted.darkMode)
        #expect(!persisted.openDashboardOnLaunch)
    }

    @Test("controller persists dictionary add and remove as inverse operations")
    func persistsDictionaryRoundTrip() async throws {
        let fixture = try makeFixture(config: AppConfig())
        defer { fixture.remove() }

        let addResult = await fixture.controller.applyComputerUseSettings(.init(
            tool: .updateMuesliSettings,
            operation: .addDictionaryWord,
            word: "musli",
            replacement: "Muesli"
        ))
        expectChangedConfigReceipt(addResult)
        #expect(fixture.configStore.load().customWords.contains {
            $0.word == "musli" && $0.replacement == "Muesli"
        })

        let removeResult = await fixture.controller.applyComputerUseSettings(.init(
            tool: .updateMuesliSettings,
            operation: .removeDictionaryWord,
            word: "musli"
        ))
        expectChangedConfigReceipt(removeResult)
        #expect(!fixture.configStore.load().customWords.contains {
            $0.word.caseInsensitiveCompare("musli") == .orderedSame
        })
    }

    @Test("controller rejects invalid settings without changing persisted config")
    func rejectsInvalidSettingsWithoutPersistence() async throws {
        var initial = AppConfig()
        initial.computerUseTimeoutSeconds = 120
        let fixture = try makeFixture(config: initial)
        defer { fixture.remove() }

        let result = await fixture.controller.applyComputerUseSettings(.init(
            tool: .updateMuesliSettings,
            operation: .setComputerUseSafetyLimit,
            seconds: 601
        ))

        #expect(result.status == .failed)
        #expect(result.transaction == nil)
        #expect(fixture.controller.config.computerUseTimeoutSeconds == 120)
        #expect(fixture.configStore.load().computerUseTimeoutSeconds == 120)
    }

    private func expectChangedConfigReceipt(_ result: ComputerUseExecutionResult) {
        #expect(result.status == .executed)
        #expect(result.transaction?.route == "muesli_config")
        #expect(result.transaction?.posted == true)
        #expect(result.transaction?.effect == .changed)
        #expect(result.transaction?.targetStable == true)
    }

    private func makeFixture(config: AppConfig) throws -> Fixture {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-cua-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        let configStore = ConfigStore(supportDirectory: supportDirectory)
        configStore.save(config)
        let dictationStore = DictationStore(databaseURL: supportDirectory.appendingPathComponent("muesli.db"))
        try dictationStore.migrateIfNeeded()
        let controller = MuesliController(
            runtime: RuntimePaths(
                repoRoot: FileManager.default.temporaryDirectory,
                menuIcon: nil,
                appIcon: nil,
                bundlePath: nil
            ),
            dictationStore: dictationStore,
            configStore: configStore
        )
        return Fixture(
            controller: controller,
            configStore: configStore,
            supportDirectory: supportDirectory
        )
    }

    private struct Fixture {
        let controller: MuesliController
        let configStore: ConfigStore
        let supportDirectory: URL

        func remove() {
            try? FileManager.default.removeItem(at: supportDirectory)
        }
    }
}
