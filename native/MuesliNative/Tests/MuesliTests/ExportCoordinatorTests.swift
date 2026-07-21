import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

/// Exercises `ExportCoordinator` + the `DictationStore` export-id persistence semantics
/// (Fix B idempotency, Fix C error surfacing, Fix E drain) with stub targets — no network,
/// no real Notion calls.
@Suite("Export coordinator", .serialized)
struct ExportCoordinatorTests {
    private func makeStore() throws -> DictationStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-export-coord-\(UUID().uuidString).db")
        let store = DictationStore(databaseURL: url)
        try store.migrateIfNeeded()
        return store
    }

    @discardableResult
    private func seedMeeting(_ store: DictationStore, title: String = "Sync me") throws -> Int64 {
        try store.insertMeeting(
            title: title, calendarEventID: nil,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_600),
            rawTranscript: "hello world", formattedNotes: "## Summary\n- point",
            micAudioPath: nil, systemAudioPath: nil
        )
    }

    /// A stub target with an injectable `export` behavior. Records the `existingRemoteID` it
    /// was handed on its most recent call so tests can assert page reuse.
    private final class StubTarget: ExportTarget {
        let key = "notion"
        var lastExistingRemoteID: String??
        private let behavior: (ExportRecord, String?, (String) async -> Void) async throws -> String

        init(_ behavior: @escaping (ExportRecord, String?, (String) async -> Void) async throws -> String) {
            self.behavior = behavior
        }
        func begin() async throws {}
        func isAuthError(_ error: Error) -> Bool { false }
        func export(_ record: ExportRecord, existingRemoteID: String?, persistRemoteID: (String) async -> Void) async throws -> String {
            lastExistingRemoteID = existingRemoteID
            return try await behavior(record, existingRemoteID, persistRemoteID)
        }
    }

    struct StubError: Error {}

    @Test("mid-export failure persists the remote id and the record stays dirty; retry reuses the page")
    func idempotencyAfterMidExportFailure() async throws {
        let store = try makeStore()
        let id = try seedMeeting(store)

        // First run: persist "page-1" then throw before finishing.
        let failing = StubTarget { _, _, persist in
            await persist("page-1")
            throw StubError()
        }
        let coordinator = ExportCoordinator()
        let firstResult = await coordinator.run(target: failing, store: store)
        #expect(firstResult.failed == 1)
        #expect(firstResult.pushed == 0)

        // The meeting still needs export AND its id was persisted (dedup).
        let stillPending = try store.meetingsNeedingExport(target: "notion")
        let record = try #require(stillPending.first { $0.localID == id })
        #expect(record.existingRemoteID == "page-1")

        // Second run: succeed, echoing back the existing id (page reuse).
        let succeeding = StubTarget { _, existing, persist in
            let pageID = existing ?? "page-NEW"
            await persist(pageID)
            return pageID
        }
        let secondResult = await coordinator.run(target: succeeding, store: store)
        #expect(secondResult.pushed == 1)
        #expect(secondResult.failed == 0)
        // The retry REUSED the page — no duplicate created.
        #expect(succeeding.lastExistingRemoteID == "page-1")
        // After a full success the record no longer needs export.
        #expect(try store.meetingsNeedingExport(target: "notion").isEmpty)
    }

    @Test("recordExportPageID sets the id but keeps the record dirty; markExported clears it")
    func recordExportPageIDVsMarkExportedSemantics() async throws {
        let store = try makeStore()
        let id = try seedMeeting(store)
        let pending = try store.meetingsNeedingExport(target: "notion")
        let updatedAt = try #require(pending.first { $0.localID == id }?.updatedAt)

        // recordExportPageID: id set, still needs export.
        try store.recordExportPageID(kind: .meeting, id: id, target: "notion", remoteID: "page-1")
        let afterPageID = try store.meetingsNeedingExport(target: "notion")
        let stillDirty = try #require(afterPageID.first { $0.localID == id })
        #expect(stillDirty.existingRemoteID == "page-1")

        // markExported: now complete, no longer needs export, id preserved.
        try store.markExported(kind: .meeting, id: id, target: "notion", remoteID: "page-1", syncedAt: updatedAt)
        #expect(try store.meetingsNeedingExport(target: "notion").isEmpty)
    }

    @Test("a target that always throws surfaces the error and leaves the record needing export")
    func errorSurfacing() async throws {
        let store = try makeStore()
        let id = try seedMeeting(store)
        let alwaysThrows = StubTarget { _, _, _ in throw StubError() }
        let result = await ExportCoordinator().run(target: alwaysThrows, store: store)
        #expect(result.failed > 0)
        #expect(result.firstError != nil)
        #expect(result.pushed == 0)
        #expect(try store.meetingsNeedingExport(target: "notion").contains { $0.localID == id })
    }

    @Test("the run drains a backlog larger than the batch limit in a single call")
    func drainBacklog() async throws {
        let store = try makeStore()
        var ids: [Int64] = []
        for i in 0..<5 { ids.append(try seedMeeting(store, title: "Meeting \(i)")) }

        // Succeed, echoing existing id or minting one per record.
        var counter = 0
        let succeeding = StubTarget { _, existing, persist in
            counter += 1
            let pageID = existing ?? "page-\(counter)"
            await persist(pageID)
            return pageID
        }
        // limit = 2, so the coordinator must loop to drain all 5.
        let result = await ExportCoordinator().run(target: succeeding, store: store, limit: 2)
        #expect(result.pushed == 5)
        #expect(result.failed == 0)
        #expect(try store.meetingsNeedingExport(target: "notion").isEmpty)
        #expect(try store.dictationsNeedingExport(target: "notion").isEmpty)
    }

    @Test("a soft-deleted pushed record is unpublished and its export state cleared")
    func unpublishesDeletedRecord() async throws {
        /// Records the remote ids passed to `unpublish`.
        final class UnpublishTracking: ExportTarget {
            let key = "notion"
            var unpublishedIDs: [String] = []
            func begin() async throws {}
            func isAuthError(_ error: Error) -> Bool { false }
            func export(_ record: ExportRecord, existingRemoteID: String?, persistRemoteID: (String) async -> Void) async throws -> String {
                await persistRemoteID("p")
                return "p"
            }
            func unpublish(remoteID: String) async throws { unpublishedIDs.append(remoteID) }
        }

        let store = try makeStore()
        let id = try seedMeeting(store)
        let updatedAt = try #require(try store.meetingsNeedingExport(target: "notion").first?.updatedAt)
        try store.markExported(kind: .meeting, id: id, target: "notion", remoteID: "page-del", syncedAt: updatedAt)
        try store.deleteMeeting(id: id)

        let target = UnpublishTracking()
        let result = await ExportCoordinator().run(target: target, store: store)

        #expect(target.unpublishedIDs == ["page-del"])
        #expect(result.unpublished == 1)
        #expect(result.failed == 0)
        // Export state cleared → not re-queued for unpublish.
        #expect(try store.recordsNeedingUnpublish(target: "notion").isEmpty)
    }

    @Test("unpublish drains a backlog larger than the store's 200-record batch cap")
    func unpublishDrainsAcrossBatches() async throws {
        final class UnpublishCounter: ExportTarget {
            let key = "notion"
            var count = 0
            func begin() async throws {}
            func isAuthError(_ error: Error) -> Bool { false }
            func export(_ record: ExportRecord, existingRemoteID: String?, persistRemoteID: (String) async -> Void) async throws -> String {
                await persistRemoteID("p")
                return "p"
            }
            func unpublish(remoteID: String) async throws { count += 1 }
        }

        let store = try makeStore()
        // 201 pushed meetings → more than one `recordsNeedingUnpublish` batch (cap 200).
        let total = 201
        for i in 0..<total { _ = try seedMeeting(store, title: "M\(i)") }
        for record in try store.meetingsNeedingExport(target: "notion", limit: total) {
            try store.markExported(
                kind: .meeting, id: record.localID, target: "notion",
                remoteID: "page-\(record.localID)", syncedAt: record.updatedAt
            )
            try store.deleteMeeting(id: record.localID)
        }

        let target = UnpublishCounter()
        let result = await ExportCoordinator().run(target: target, store: store)

        #expect(target.count == total)
        #expect(result.unpublished == total)
        #expect(result.failed == 0)
        #expect(try store.recordsNeedingUnpublish(target: "notion").isEmpty)
    }

    @Test("finish() is called before returning from a successful run")
    func finishCalled() async throws {
        final class FinishTracking: ExportTarget {
            let key = "notion"
            var finished = false
            func begin() async throws {}
            func isAuthError(_ error: Error) -> Bool { false }
            func export(_ record: ExportRecord, existingRemoteID: String?, persistRemoteID: (String) async -> Void) async throws -> String {
                await persistRemoteID("p")
                return "p"
            }
            func finish() async { finished = true }
        }
        let store = try makeStore()
        _ = try seedMeeting(store)
        let target = FinishTracking()
        _ = await ExportCoordinator().run(target: target, store: store)
        #expect(target.finished)
    }
}
