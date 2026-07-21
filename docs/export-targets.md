# Adding an export target

Muesli can mirror meetings and dictations out to external destinations. Notion is the
first one, but the machinery is service-agnostic: destinations are **export targets**, and
almost everything hard (dirty-record tracking, idempotency, delete propagation, retries,
cross-device dedup) lives in a shared coordinator you get for free.

This guide shows how to add a new target (Obsidian, a filesystem folder, a webhook, …).

## The shape

There are three pieces:

- **`ExportTarget`** — a small protocol you implement, one per destination.
- **`ExportCoordinator`** — target-agnostic engine that drives a single export run.
- **`publish_state_json`** — a generic per-record column that stores where each record was
  exported, keyed by target. Adding a target needs **no schema change**.

```text
DictationStore ──dirty records──▶ ExportCoordinator ──per record──▶ YourTarget ──▶ service
       ▲                                    │
       └──────── publish_state_json ◀───────┘   (remote id + exported-at, keyed by target)
```

## The protocol

`ExportTarget` (see `native/MuesliNative/Sources/MuesliNativeApp/ExportTarget.swift`):

```swift
protocol ExportTarget: AnyObject {
    /// Matches the publish_state_json target key, e.g. "notion".
    var key: String { get }

    /// Once per run: prepare/validate (auth). Throw to abort the whole run.
    func begin() async throws

    /// Export one record, reusing `existingRemoteID` when present. Return the remote id to
    /// persist. Call `persistRemoteID` the MOMENT the remote object exists (before writing
    /// the body) — a mid-export failure then records the id, and the retry reuses the same
    /// remote object instead of creating a duplicate.
    func export(_ record: ExportRecord,
                existingRemoteID: String?,
                persistRemoteID: (String) async -> Void) async throws -> String

    /// Classify auth/permission failures so the run can pause with a reconnect prompt.
    func isAuthError(_ error: Error) -> Bool

    /// Archive/delete the remote object for a locally-deleted record (one-way delete
    /// propagation). A record already gone remotely counts as success. Default: no-op.
    func unpublish(remoteID: String) async throws

    /// Once per run, on every exit path — flush/tear down batch state. Default: no-op.
    func finish() async
}
```

`unpublish` and `finish` have default no-op implementations, so a minimal target only needs
`key`, `begin`, `export`, and `isAuthError`.

## What the coordinator gives you

`ExportCoordinator.run(target:store:)` handles all of this so your target doesn't have to:

- Enumerates dirty meetings **and** dictations off the `updated_at` write-clock (an edit
  re-exports automatically).
- **Idempotent create-vs-update** — persists the remote id the instant it exists, so a retry
  never duplicates.
- **Delete propagation** — drains locally-deleted records through `unpublish`.
- **Retry/backoff**, and an **auth-abort** path that surfaces a reconnect prompt.
- **Cancellation** (e.g. the user disables the target mid-run) and a drain loop with a safety
  cap so a persistent failure can't spin forever.
- **CloudKit replication** of the remote id, so two Macs converge on one remote object.

Your job is just: talk to the service, and render a record into whatever that service wants.

## A minimal target

```swift
final class FolderTarget: ExportTarget {
    let key = "folder"
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func begin() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func export(_ record: ExportRecord,
                existingRemoteID: String?,
                persistRemoteID: (String) async -> Void) async throws -> String {
        // Stable remote id = the file we write to (reused on edit → in-place update).
        let id = existingRemoteID ?? "\(record.localID).md"
        await persistRemoteID(id)                       // record the id before writing the body
        let url = directory.appendingPathComponent(id)
        try record.notesMarkdown.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    func isAuthError(_ error: Error) -> Bool { false }  // a local folder never "de-auths"

    func unpublish(remoteID: String) async throws {     // optional: propagate deletes
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(remoteID))
        } catch CocoaError.fileNoSuchFile {
            // Already gone — treat as success (delete is idempotent).
        }
        // Any other error (permissions, I/O) propagates so the coordinator can retry.
    }
}
```

For real, compiled reference conformers, see the stub targets in
`native/MuesliNative/Tests/MuesliTests/ExportCoordinatorTests.swift` (`StubTarget`,
`UnpublishTracking`, `FinishTracking`) — they exercise idempotency, drain, delete
propagation, and error surfacing.

## Wiring it up

There's a single place a target is instantiated and run —
`MuesliController.swift`, where the Notion push builds its target and hands it to the
coordinator:

```swift
let target = NotionTarget(token: …, dataSourceID: …)
let coordinator = ExportCoordinator()
let result = await coordinator.run(target: target, store: store)
```

A new target follows the same three lines (construct it, run it), plus whatever
settings/enable toggle it needs in `SettingsView` and `AppConfig`. The storage layer and the
coordinator stay untouched.

## Scope

This is a one-way **export/mirror** framework (Muesli → service). It intentionally isn't a
two-way sync or a hosted-OAuth integration hub — that would require a token-exchange backend,
which is at odds with Muesli's local-first, no-server design. Within one-way export, though,
targets are meant to be cheap to add.
