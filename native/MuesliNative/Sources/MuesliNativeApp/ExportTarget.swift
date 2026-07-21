import Foundation
import MuesliCore

/// A pluggable one-way export destination for meetings + dictations. Muesli is the source
/// of truth; each target is a mirror. Targets are enumerated off the `updated_at`
/// write-clock via `DictationStore.*NeedingExport(target:)` and marked with `markExported`
/// so an edit re-exports. Notion is the first target; adding another means implementing
/// this protocol — no schema changes (state lives in the generic `publish_state_json`).
protocol ExportTarget: AnyObject {
    /// Matches the `publish_state_json` target key, e.g. "notion".
    var key: String { get }
    /// Called once per run: prepare/validate (auth). Throw to abort the whole run.
    func begin() async throws
    /// Exports one record, reusing `existingRemoteID` when present. Returns the remote id
    /// to persist. `persistRemoteID` MUST be called with the remote id the moment it exists
    /// (before writing the body), so a mid-export failure still records the id and the retry
    /// reuses the same remote page instead of creating a duplicate.
    func export(_ record: ExportRecord, existingRemoteID: String?, persistRemoteID: (String) async -> Void) async throws -> String
    /// Classifies auth/permission failures so the run can pause with a reconnect prompt.
    func isAuthError(_ error: Error) -> Bool
    /// Archives (deletes) the remote page for a locally-deleted record — one-way delete
    /// propagation. A record already gone in the target should be treated as success. Default:
    /// no-op (stub conformers/targets without delete support opt out).
    func unpublish(remoteID: String) async throws
    /// Called once per run, before every return from `ExportCoordinator.run` (including
    /// auth-abort and error paths), so batch targets can flush/tear down. Default: no-op.
    func finish() async
}

extension ExportTarget {
    func unpublish(remoteID: String) async throws {}
    func finish() async {}
}

/// Per-run outcome from `ExportCoordinator.run`.
struct ExportRunResult: Sendable {
    var pushed = 0
    var failed = 0
    /// Count of remote pages archived because their local record was deleted (one-way delete
    /// propagation).
    var unpublished = 0
    /// Set when the run was aborted by an auth/permission failure (bad token, or a remote
    /// database not shared with the integration) — the UI should prompt to reconnect.
    var authError: String?
    var firstError: String?

    var pushedTotal: Int { pushed }
}

/// Drives a single export run against one target: begins the target (auth/validate),
/// enumerates dirty meetings + dictations, exports each, and records success. Never throws
/// — per-record failures are surfaced (counted + `firstError`) and the run continues, except
/// an auth/permission error aborts early (further exports fail alike). Drains the backlog by
/// looping while a full batch keeps coming back and records keep progressing.
struct ExportCoordinator {
    /// Safety cap on drain iterations so a persistent write failure can't spin forever.
    private static let maxDrainIterations = 100

    func run(target: ExportTarget, store: DictationStore, limit: Int = 500) async -> ExportRunResult {
        var result = ExportRunResult()
        do {
            try await target.begin()
        } catch {
            if target.isAuthError(error) {
                result.authError = error.localizedDescription
            } else {
                result.firstError = error.localizedDescription
            }
            await target.finish()
            return result
        }

        var iterations = 0
        while iterations < Self.maxDrainIterations {
            iterations += 1
            // Halt promptly when the run is cancelled (e.g. the user disabled sync mid-push)
            // instead of finishing the whole batch. finish() still runs on the way out.
            if Task.isCancelled { break }

            // FIX C: surface query failures instead of masquerading as "up to date".
            let meetings: [ExportRecord]
            let dictations: [ExportRecord]
            do {
                meetings = try store.meetingsNeedingExport(target: target.key, limit: limit)
                dictations = try store.dictationsNeedingExport(target: target.key, limit: limit)
            } catch {
                if result.firstError == nil { result.firstError = error.localizedDescription }
                result.failed += 1
                await target.finish()
                return result
            }

            let batch = meetings + dictations
            if batch.isEmpty { break }

            var progressedThisBatch = false
            for record in batch {
                if Task.isCancelled { break }
                do {
                    // FIX B: the id must persist the moment the remote page exists (dedup),
                    // while syncedAt (export complete) persists only on full success
                    // (completeness). recordExportPageID keeps the record still needing export.
                    let remoteID = try await target.export(
                        record,
                        existingRemoteID: record.existingRemoteID,
                        persistRemoteID: { id in
                            do {
                                try store.recordExportPageID(kind: record.kind, id: record.localID, target: target.key, remoteID: id)
                            } catch {
                                // Best-effort: a failure here is rare and only costs a possible
                                // re-create on retry. Log, don't crash the run.
                                fputs("recordExportPageID failed for \(record.kind) \(record.localID): \(error)\n", stderr)
                            }
                        }
                    )
                    // FIX C: markExported must not be try?-swallowed. Only count a push AFTER it
                    // succeeds — a pushed-but-unrecorded record would duplicate next run.
                    do {
                        try store.markExported(kind: record.kind, id: record.localID, target: target.key, remoteID: remoteID, syncedAt: record.updatedAt)
                        result.pushed += 1
                        progressedThisBatch = true
                    } catch {
                        result.failed += 1
                        if result.firstError == nil { result.firstError = error.localizedDescription }
                    }
                } catch {
                    if target.isAuthError(error) {
                        result.authError = error.localizedDescription
                        await target.finish()
                        return result
                    }
                    result.failed += 1
                    if result.firstError == nil { result.firstError = error.localizedDescription }
                }
            }

            // FIX E: drain — fetch another batch only if this one filled `limit` for either
            // kind (more may remain) AND at least one record progressed (avoids an infinite
            // loop when writes persistently fail). Otherwise we're done.
            let sawFullBatch = meetings.count >= limit || dictations.count >= limit
            if !sawFullBatch || !progressedThisBatch { break }
        }

        // One-way delete propagation: archive the remote page for any locally-deleted record
        // that still carries a remote id, then clear its export state so it isn't re-archived.
        // Drain in a loop (mirroring the push drain) so a bulk delete of more than one batch
        // (the store caps `recordsNeedingUnpublish` at 200) is fully propagated instead of
        // leaving pages behind. Each successful unpublish clears the row's export state, so the
        // next fetch returns the following batch; we stop on an empty batch, no progress, an auth
        // error, or the safety cap.
        var unpublishIterations = 0
        unpublishDrain: while unpublishIterations < Self.maxDrainIterations {
            unpublishIterations += 1
            if Task.isCancelled { break }

            let toUnpublish: [UnpublishTarget]
            do {
                toUnpublish = try store.recordsNeedingUnpublish(target: target.key)
            } catch {
                if result.firstError == nil { result.firstError = error.localizedDescription }
                result.failed += 1
                break
            }
            if toUnpublish.isEmpty { break }

            var progressedThisBatch = false
            for rec in toUnpublish {
                if Task.isCancelled { break }
                do {
                    try await target.unpublish(remoteID: rec.remoteID)
                    try store.clearExportState(kind: rec.kind, id: rec.localID, target: target.key)
                    result.unpublished += 1
                    progressedThisBatch = true
                } catch {
                    if target.isAuthError(error) { result.authError = error.localizedDescription; break unpublishDrain }
                    result.failed += 1
                    if result.firstError == nil { result.firstError = error.localizedDescription }
                }
            }

            // Stop if nothing progressed this batch (persistent failures) — otherwise the same
            // records would be refetched forever.
            if !progressedThisBatch { break }
        }

        await target.finish()
        return result
    }
}
