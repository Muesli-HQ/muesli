import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Planned folder for an upcoming meeting")
struct PlannedCalendarFolderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("choosing a folder is remembered without any meeting existing")
    func remembered() {
        var config = AppConfig()
        config.planFolder(7, for: "occ-a", startTime: now.addingTimeInterval(3600), now: now)
        #expect(config.plannedFolderID(for: "occ-a", existingFolderIDs: [7, 8]) == 7)
        #expect(config.plannedFolderID(for: "occ-b", existingFolderIDs: [7, 8]) == nil)
    }

    @Test("choosing All Meetings clears the choice")
    func cleared() {
        var config = AppConfig()
        config.planFolder(7, for: "occ-a", startTime: now.addingTimeInterval(3600), now: now)
        config.planFolder(nil, for: "occ-a", startTime: now.addingTimeInterval(3600), now: now)
        #expect(config.plannedFolderID(for: "occ-a", existingFolderIDs: [7]) == nil)
    }

    @Test("a deleted folder is ignored")
    func deletedFolder() {
        var config = AppConfig()
        config.planFolder(7, for: "occ-a", startTime: now.addingTimeInterval(3600), now: now)
        #expect(config.plannedFolderID(for: "occ-a", existingFolderIDs: [8]) == nil)
    }

    @Test("choices for meetings that started over a week ago are dropped on the next change")
    func pruned() {
        var config = AppConfig()
        config.planFolder(7, for: "old", startTime: now.addingTimeInterval(-8 * 86_400), now: now.addingTimeInterval(-8 * 86_400))
        config.planFolder(7, for: "new", startTime: now.addingTimeInterval(3600), now: now)
        #expect(config.plannedCalendarFolders["old"] == nil)
        #expect(config.plannedCalendarFolders["new"] != nil)
    }

    @Test("a postponed event keeps its choice when the calendar reports its new start")
    func postponed() {
        var config = AppConfig()
        let original = now.addingTimeInterval(86_400)
        let postponed = now.addingTimeInterval(20 * 86_400)
        config.planFolder(7, for: "moved", startTime: original, now: now)
        let later = now.addingTimeInterval(10 * 86_400)
        config.planFolder(8, for: "other", startTime: later.addingTimeInterval(3600),
                          currentStartTimes: ["moved": postponed], now: later)
        #expect(config.plannedCalendarFolders["moved"]?.startTime == postponed)
        #expect(config.plannedFolderID(for: "moved", existingFolderIDs: [7, 8]) == 7)
    }

    @Test("a stale choice for an event the calendar no longer lists is still pruned")
    func staleStillPruned() {
        var config = AppConfig()
        config.planFolder(7, for: "gone", startTime: now.addingTimeInterval(86_400), now: now)
        let later = now.addingTimeInterval(10 * 86_400)
        config.planFolder(8, for: "other", startTime: later.addingTimeInterval(3600), currentStartTimes: [:], now: later)
        #expect(config.plannedCalendarFolders["gone"] == nil)
    }

    @MainActor
    private func makeController(store: DictationStore, supportDirectory: URL) -> MuesliController {
        MuesliController(
            runtime: RuntimePaths(repoRoot: FileManager.default.temporaryDirectory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store,
            configStore: ConfigStore(supportDirectory: supportDirectory)
        )
    }

    @MainActor
    @Test("picking a folder on an upcoming event creates no meeting")
    func noMeetingCreated() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("planned-support-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let store = DictationStore(databaseURL: supportDirectory.appendingPathComponent("planned.db"))
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try store.migrateIfNeeded()
        let controller = makeController(store: store, supportDirectory: supportDirectory)
        let folderID = try store.createFolder(name: "Rush")
        controller.syncAppState()
        let start = Date().addingTimeInterval(3600)
        let event = UnifiedCalendarEvent(
            id: "evt-1", title: "Tuffsea", startDate: start, endDate: start.addingTimeInterval(3600),
            isAllDay: false, source: .eventKit, calendarID: "work")

        controller.planFolder(folderID, for: event)

        #expect(try store.recentMeetings(limit: 10).isEmpty)
        #expect(controller.plannedFolderID(for: event.resolvedCalendarOccurrence) == folderID)
        #expect(controller.appState.config.plannedFolderID(
            for: event.resolvedCalendarOccurrence.identityKey, existingFolderIDs: [folderID]) == folderID)
    }

    @MainActor
    @Test("a new meeting takes the planned folder unless one is inherited")
    func folderForNewMeeting() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("planned-support-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let store = DictationStore(databaseURL: supportDirectory.appendingPathComponent("planned.db"))
        try store.migrateIfNeeded()
        let controller = makeController(store: store, supportDirectory: supportDirectory)
        let planned = try store.createFolder(name: "Rush")
        let inherited = try store.createFolder(name: "Other")
        controller.syncAppState()
        let start = Date().addingTimeInterval(3600)
        let event = UnifiedCalendarEvent(
            id: "evt-2", title: "Sync", startDate: start, endDate: start.addingTimeInterval(3600),
            isAllDay: false, source: .eventKit, calendarID: "work")
        let occurrence = event.resolvedCalendarOccurrence
        controller.planFolder(planned, for: event)

        #expect(controller.folderIDForNewMeeting(inheritedFolderID: nil, calendarOccurrence: occurrence) == planned)
        #expect(controller.folderIDForNewMeeting(inheritedFolderID: inherited, calendarOccurrence: occurrence) == inherited)
        #expect(controller.folderIDForNewMeeting(inheritedFolderID: nil, calendarOccurrence: nil) == nil)

        try store.deleteFolder(id: planned)
        controller.syncAppState()
        #expect(controller.folderIDForNewMeeting(inheritedFolderID: nil, calendarOccurrence: occurrence) == nil)
    }

    @Test("the choice survives a save and load")
    func persisted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("planned-\(UUID())", isDirectory: true)
        let store = ConfigStore(supportDirectory: dir)
        var config = AppConfig()
        config.planFolder(7, for: "occ-a", startTime: now.addingTimeInterval(3600), now: now)
        store.save(config)
        #expect(store.load().plannedFolderID(for: "occ-a", existingFolderIDs: [7]) == 7)
        try? FileManager.default.removeItem(at: dir)
    }
}
