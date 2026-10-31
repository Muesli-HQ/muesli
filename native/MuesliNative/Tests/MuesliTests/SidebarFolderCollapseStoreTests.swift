import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("SidebarFolderCollapseStore")
struct SidebarFolderCollapseStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "muesli-sidebar-collapse-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("starts with every folder expanded")
    func startsExpanded() {
        #expect(SidebarFolderCollapseStore(defaults: makeDefaults()).load().isEmpty)
    }

    @Test("collapsed folders survive a relaunch")
    func collapsedFoldersSurviveRelaunch() {
        let defaults = makeDefaults()
        SidebarFolderCollapseStore(defaults: defaults).save([3, 7], existingFolderIDs: [1, 3, 7])

        // A new store over the same defaults is what the next launch sees.
        #expect(SidebarFolderCollapseStore(defaults: defaults).load() == [3, 7])
    }

    @Test("expanding every folder clears the saved state")
    func expandingEverythingClearsState() {
        let defaults = makeDefaults()
        let store = SidebarFolderCollapseStore(defaults: defaults)
        store.save([3], existingFolderIDs: [3])
        store.save([], existingFolderIDs: [3])

        #expect(store.load().isEmpty)
        #expect(defaults.object(forKey: SidebarFolderCollapseStore.defaultsKey) == nil)
    }

    @Test("deleted folders are dropped when saving")
    func deletedFoldersAreDropped() {
        let store = SidebarFolderCollapseStore(defaults: makeDefaults())
        store.save([3, 9], existingFolderIDs: [1, 3])

        #expect(store.load() == [3])
    }

    @Test("nothing is pruned before the folder list loads")
    func nothingPrunedBeforeFoldersLoad() {
        let store = SidebarFolderCollapseStore(defaults: makeDefaults())
        store.save([3, 9])

        #expect(store.load() == [3, 9])
    }
}
