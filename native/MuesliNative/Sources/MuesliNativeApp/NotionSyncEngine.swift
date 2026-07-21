import Foundation
import MuesliCore

/// One-way export of meetings + dictations into a user's Notion workspace (a single
/// "Muesli Notes" data source; a Type property distinguishes meetings from dictations).
/// Muesli is the source of truth; Notion is a mirror. Conforms to `ExportTarget` and is
/// driven by `ExportCoordinator`: `begin()` retrieves+caches the data source schema (an
/// auth/permission failure aborts the whole run early), `export` renders one record to a
/// Notion-flavored Markdown body and returns the resolved page id (the coordinator persists
/// it via `markExported`, so an edit re-exports). Requests are spaced to respect Notion's
/// ~3 req/s limit; `NotionClient` additionally honors 429/`Retry-After`.
final class NotionTarget: ExportTarget {
    let key = "notion"
    let token: String
    /// The single "Muesli Notes" data source; a Type property distinguishes meetings from
    /// dictations.
    let dataSourceID: String
    /// Minimum spacing between Notion API calls (~3 req/s).
    var minRequestInterval: TimeInterval

    /// Cached data source schema, retrieved once per run in `begin()`.
    private var schema: NotionClient.NotionDataSource?

    init(token: String, dataSourceID: String, minRequestInterval: TimeInterval = 0.34) {
        self.token = token
        self.dataSourceID = dataSourceID
        self.minRequestInterval = minRequestInterval
    }

    func begin() async throws {
        guard !dataSourceID.isEmpty else {
            throw NotionError.unexpectedResponse("No Notion data source configured.")
        }
        schema = try await throttled { try await NotionClient.retrieveDataSource(id: dataSourceID, token: token) }
    }

    func isAuthError(_ error: Error) -> Bool {
        (error as? NotionError)?.isAuthOrPermission == true
    }

    // MARK: - Per-record export

    func export(_ record: ExportRecord, existingRemoteID: String?, persistRemoteID: (String) async -> Void) async throws -> String {
        guard let schema else { throw NotionError.unexpectedResponse("No Notion data source configured.") }
        let properties = pageProperties(record, schema: schema)
        let markdown = NotionTarget.bodyMarkdown(record)

        // Reuse the stored page (updating its properties + replacing its whole body), or create
        // a fresh one. The markdown endpoint has no working full-replace op, so a full-body
        // re-sync must clear the page's existing child blocks and insert fresh Markdown.
        //
        // Insert-before-delete: capture the OLD child ids first, append the fresh body, THEN
        // delete the old blocks last. This keeps the page from ever being empty: a failure
        // after the insert leaves old+new content (recoverable — the next run self-heals by
        // re-inserting and re-deleting), and a failure before/at the insert leaves the old
        // content intact. Deleting first (the naive order) would blank the page on any failure.
        if let existing = existingRemoteID, !existing.isEmpty {
            do {
                let oldChildIDs = try await throttled { try await NotionClient.pageChildBlockIDs(pageID: existing, token: token) }
                try await throttled { try await NotionClient.updatePageProperties(pageID: existing, properties: properties, token: token) }
                try await throttled { try await NotionClient.insertPageMarkdown(pageID: existing, markdown: markdown, token: token) }
                for id in oldChildIDs {
                    do {
                        try await throttled { try await NotionClient.deleteBlock(blockID: id, token: token) }
                    } catch let error as NotionError where error.isNotFound || error.isArchived {
                        // A single child block already removed/moved in Notion is fine — the goal
                        // is for it to be gone. Swallow it here so it can't bubble up to the
                        // page-level recreate path and duplicate a page whose fresh body we just
                        // inserted (the page itself still exists).
                    }
                }
                return existing
            } catch let error as NotionError where error.isNotFound || error.isArchived {
                // The page itself is deleted/archived in Notion → fall through and recreate it.
            }
        }

        let pageID = try await throttled {
            try await NotionClient.createPage(dataSourceID: dataSourceID, properties: properties,
                                              markdown: markdown, token: token, icon: NotionClient.muesliIcon)
        }
        // Persist the remote id the instant the page exists so the record is idempotent on
        // retry (the coordinator records it via `markExported`).
        await persistRemoteID(pageID)
        return pageID
    }

    /// Archives the Notion page for a locally-deleted record (one-way delete propagation). A
    /// page already gone/archived in Notion is treated as success.
    func unpublish(remoteID: String) async throws {
        do {
            try await throttled { try await NotionClient.deleteBlock(blockID: remoteID, token: token) }
        } catch let error as NotionError where error.isNotFound || error.isArchived {
            // Already gone in Notion — treat as success.
        }
    }

    // MARK: - Payload building

    private func pageProperties(_ record: ExportRecord, schema: NotionClient.NotionDataSource) -> [String: Any] {
        let title = String(record.title.prefix(2000))
        var properties: [String: Any] = [
            schema.titleProperty: ["title": [["type": "text", "text": ["content": title]]]] as [String: Any],
        ]
        if let dateProperty = schema.dateProperty, let iso = isoDate(record.startTime) {
            properties[dateProperty] = ["date": ["start": iso]] as [String: Any]
        }
        // Type — Meeting vs Dictation (the one data source holds both).
        if schema.properties["Type"] == "select" {
            properties["Type"] = ["select": ["name": record.kind == .meeting ? "Meeting" : "Dictation"]] as [String: Any]
        }
        // Meeting type — the template/kind (Interview, 1:1, …), meetings only.
        if record.kind == .meeting, let meetingType = record.meetingType, !meetingType.isEmpty,
           schema.properties["Meeting type"] == "select" {
            properties["Meeting type"] = ["select": ["name": meetingType]] as [String: Any]
        }
        // Attribution — "Created by: Muesli" (matches Granola's "Created by" property).
        if schema.properties["Created by"] == "rich_text" {
            properties["Created by"] = ["rich_text": [["type": "text", "text": ["content": "Muesli"]]]] as [String: Any]
        }
        return properties
    }

    /// The page body as Notion-flavored Markdown (pure, testable). For a meeting: the AI
    /// notes, then optional manual notes under a heading, then the raw transcript tucked in a
    /// collapsible `<details>` toggle. For a dictation: just the dictated text — no transcript
    /// toggle, since the text IS the content and a toggle would duplicate it (this also fixes
    /// a latent duplication in the old block path, which emitted the text as the body AND
    /// again inside the transcript toggle).
    static func bodyMarkdown(_ record: ExportRecord) -> String {
        if record.kind == .dictation {
            return record.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        var parts: [String] = []
        if let notes = record.notesMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            parts.append(notes)
        }
        if let manual = record.manualNotes?.trimmingCharacters(in: .whitespacesAndNewlines), !manual.isEmpty {
            parts.append("## Manual notes\n\n" + manual)
        }
        if let transcript = record.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
            parts.append("<details>\n<summary>Transcript</summary>\n\n" + transcript + "\n\n</details>")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Request helpers

    /// Runs `op` then waits `minRequestInterval` so the whole run stays under ~3 req/s.
    private func throttled<T>(_ op: () async throws -> T) async throws -> T {
        let value = try await op()
        try? await Task.sleep(nanoseconds: UInt64(minRequestInterval * 1_000_000_000))
        return value
    }

    // MARK: - Formatting

    /// Reused across records — `ISO8601DateFormatter` is expensive to allocate, and `isoDate`
    /// runs once per exported record.
    private static let isoParser = ISO8601DateFormatter()
    private static let isoParserWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func isoDate(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        // start_time / timestamp are already stored ISO8601; accept if either parser accepts it.
        if NotionTarget.isoParser.date(from: raw) != nil { return raw }
        return NotionTarget.isoParserWithFractionalSeconds.date(from: raw) != nil ? raw : nil
    }
}
