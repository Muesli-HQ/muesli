import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Settings search")
struct SettingsSearchTests {
    @Test("empty and whitespace queries return no results")
    func emptyQueriesReturnEmpty() {
        #expect(SettingsSearchIndex.search("").isEmpty)
        #expect(SettingsSearchIndex.search("   \n\t  ").isEmpty)
    }

    @Test("case-insensitive, diacritic-insensitive, and multi-token matching")
    func multiTokenAndCaseDiacriticInsensitiveMatching() {
        let mixedCase = SettingsSearchIndex.search("ICLOUD SYNC")
        #expect(mixedCase.first?.id == "settings.general.icloudSync")

        let diacritic = SettingsSearchIndex.search("cléanup prömpt")
        #expect(diacritic.contains { $0.id == "settings.dictation.cleanupPreset" })

        let crossField = SettingsSearchIndex.search("meetings markdown")
        #expect(crossField.first?.id == "settings.meetings.autoExport")

        let partialMiss = SettingsSearchIndex.search("icloud nonexistenttoken")
        #expect(partialMiss.isEmpty)
    }

    @Test("ranking prioritizes exact title > prefix > word/substring > keyword prefix > keyword substring > section/pane > subtitle")
    func rankingPrecedenceOrder() {
        let entries = [
            SettingsSearchEntry(
                id: "subtitle",
                title: "Delta",
                subtitle: "Mentions alpha inside description",
                pane: .general,
                section: "Other",
                keywords: []
            ),
            SettingsSearchEntry(
                id: "section",
                title: "Gamma",
                subtitle: "Unrelated text",
                pane: .general,
                section: "Alpha Section",
                keywords: []
            ),
            SettingsSearchEntry(
                id: "keyword-substring",
                title: "Beta",
                subtitle: "Unrelated text",
                pane: .general,
                section: "Other",
                keywords: ["myalpha"]
            ),
            SettingsSearchEntry(
                id: "keyword-prefix",
                title: "Epsilon",
                subtitle: "Unrelated text",
                pane: .general,
                section: "Other",
                keywords: ["alphabetic"]
            ),
            SettingsSearchEntry(
                id: "title-word",
                title: "My Alpha Setting",
                subtitle: "Unrelated text",
                pane: .general,
                section: "Other",
                keywords: []
            ),
            SettingsSearchEntry(
                id: "title-prefix",
                title: "Alphabet",
                subtitle: "Unrelated text",
                pane: .general,
                section: "Other",
                keywords: []
            ),
            SettingsSearchEntry(
                id: "exact-title",
                title: "Alpha",
                subtitle: "Unrelated text",
                pane: .general,
                section: "Other",
                keywords: []
            ),
        ]

        let results = SettingsSearchIndex.search("alpha", in: entries)
        #expect(results.map(\.id) == [
            "exact-title",
            "title-prefix",
            "title-word",
            "keyword-prefix",
            "keyword-substring",
            "section",
            "subtitle",
        ])
    }

    @Test("ties preserve catalog order")
    func tieBreakPreservesCatalogOrder() {
        let entries = [
            SettingsSearchEntry(id: "first", title: "One", subtitle: "Shared keyword", pane: .general, section: "S", keywords: ["match"]),
            SettingsSearchEntry(id: "second", title: "Two", subtitle: "Shared keyword", pane: .dictation, section: "S", keywords: ["match"]),
            SettingsSearchEntry(id: "third", title: "Three", subtitle: "Shared keyword", pane: .meetings, section: "S", keywords: ["match"]),
        ]

        let results = SettingsSearchIndex.search("match", in: entries)
        #expect(results.map(\.id) == ["first", "second", "third"])
    }

    @Test("key user lookups resolve expected settings")
    func keyUserLookups() {
        #expect(SettingsSearchIndex.search("diarization").first?.id == "settings.meetings.inRoomSpeakers")
        #expect(SettingsSearchIndex.search("ultra dark").first?.id == "settings.appearance.theme")
        #expect(SettingsSearchIndex.search("icloud").first?.id == "settings.general.icloudSync")
        #expect(SettingsSearchIndex.search("permissions").first?.id == "settings.permissions")
        #expect(SettingsSearchIndex.search("cua").first?.id == "settings.experimental.computerUse")
        #expect(SettingsSearchIndex.search("quill").first?.id == FeatureTourTarget.quillSettings.rawValue)
        #expect(SettingsSearchIndex.search("time turner").first?.id == "settings.experimental.timeTurner")
        #expect(SettingsSearchIndex.search("hotkey").contains { $0.id == "settings.appearance.showHotkeyMenu" })
        #expect(SettingsSearchIndex.search("hotkey").contains { $0.id == "settings.dictation.pasteShortcut" })
        #expect(SettingsSearchIndex.search("calendar").first?.id == "settings.meetings.calendars")
        #expect(SettingsSearchIndex.search("post-meeting hook").first?.id == "settings.meetings.postMeetingHook")
        #expect(SettingsSearchIndex.search("next meeting").first?.id == "settings.appearance.showNextMeeting")
        #expect(SettingsSearchIndex.search("recordings").contains { $0.id == "settings.dictation.recordings" })
        #expect(SettingsSearchIndex.search("recordings").contains { $0.id == "settings.meetings.recordingPolicy" })
    }

    @Test("catalog invariants hold across all Settings panes")
    func catalogInvariants() {
        let entries = SettingsSearchIndex.entries
        #expect(!entries.isEmpty)

        let ids = entries.map(\.id)
        #expect(Set(ids).count == ids.count, "SettingsSearchIndex entry IDs must be unique")

        let coveredPanes = Set(entries.map(\.pane))
        #expect(coveredPanes == Set(SettingsPane.allCases), "Every SettingsPane must be covered by SettingsSearchIndex")

        for entry in entries {
            #expect(!entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!entry.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!entry.section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("every indexed entry ID is wired as an anchor in SettingsView")
    func allCatalogIDsAreAnchoredInSettingsView() throws {
        let settingsViewURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/MuesliNativeApp/SettingsView.swift")
        let source = try String(contentsOf: settingsViewURL, encoding: .utf8)

        let tourTargetsByRawValue: [String: String] = [
            FeatureTourTarget.dictationProviderSetting.rawValue: "FeatureTourTarget.dictationProviderSetting.rawValue",
            FeatureTourTarget.liveDictation.rawValue: "FeatureTourTarget.liveDictation.rawValue",
            FeatureTourTarget.cloudCleanupSetting.rawValue: "FeatureTourTarget.cloudCleanupSetting.rawValue",
            FeatureTourTarget.appFormatting.rawValue: "FeatureTourTarget.appFormatting.rawValue",
            FeatureTourTarget.liveCaptionsSetting.rawValue: "FeatureTourTarget.liveCaptionsSetting.rawValue",
            FeatureTourTarget.meetingSummaryProvider.rawValue: "FeatureTourTarget.meetingSummaryProvider.rawValue",
            FeatureTourTarget.recordingIndicatorStyle.rawValue: "FeatureTourTarget.recordingIndicatorStyle.rawValue",
            FeatureTourTarget.quillSettings.rawValue: "FeatureTourTarget.quillSettings.rawValue",
            FeatureTourTarget.cotypistSettings.rawValue: "FeatureTourTarget.cotypistSettings.rawValue",
        ]

        for entry in SettingsSearchIndex.entries {
            let expectedAnchorArgument = tourTargetsByRawValue[entry.id] ?? "\"\(entry.id)\""
            #expect(
                source.contains(".settingsSearchAnchor(\(expectedAnchorArgument)"),
                "Missing .settingsSearchAnchor for \(entry.id) in SettingsView.swift"
            )
        }
    }
}
