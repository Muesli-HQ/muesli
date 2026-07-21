import Foundation

/// Thin async client for the slice of the Notion API the sync engine needs: validate a
/// token, read a target database, create/update pages, and append/replace block content.
/// Mirrors `MeetingSummaryClient`'s stateless-enum + URLSession shape. Bodies are plain
/// `[String: Any]` (Notion's block/property schema is deeply variant, so JSONSerialization
/// is cleaner than Codable here). Respects Notion's 429/529 rate limits via `Retry-After`.
enum NotionClient {
    static let apiBase = URL(string: "https://api.notion.com/v1")!
    /// The modern data-sources API version. A *database* is now a container of one or more
    /// *data sources*; pages live under a data source, and the property schema lives on the
    /// data source (see `retrieveDataSource`).
    static let notionVersion = "2026-03-11"

    /// The Muesli app icon, hosted in the public repo, used as the icon for every page and
    /// database Muesli creates in Notion (an `external` icon — Notion fetches + caches it).
    // Pinned to an immutable commit SHA so a future rename/move of the asset doesn't break
    // icons/covers on databases we already created (Notion caches the URL it was given).
    static let muesliIconURL = "https://raw.githubusercontent.com/Muesli-HQ/muesli/503de73283e72b48c2c7940dd5b66c949ec3d941/assets/muesli_app_icon.png"
    static var muesliIcon: [String: Any] {
        ["type": "external", "external": ["url": muesliIconURL]]
    }

    /// The Muesli banner image, used as the `cover` of the database Muesli creates in Notion
    /// (an `external` cover — Notion fetches + caches it).
    // Pinned to an immutable commit SHA (see muesliIconURL) so the cover survives asset moves.
    static let muesliBannerURL = "https://raw.githubusercontent.com/Muesli-HQ/muesli/503de73283e72b48c2c7940dd5b66c949ec3d941/assets/muesli-readme-og.jpg"
    static var muesliCover: [String: Any] {
        ["type": "external", "external": ["url": muesliBannerURL]]
    }

    // MARK: - Endpoints

    struct NotionIdentity { let integrationName: String; let ownerName: String?; let workspaceName: String? }

    /// `GET /users/me` — validates the token and returns the integration name plus, for a
    /// bot token, the name of the person who owns the integration and the workspace it is
    /// bound to (so the UI can name the database after the owner and show *where* data syncs).
    static func validateToken(_ token: String) async throws -> NotionIdentity {
        let json = try jsonObject(try await send(request(path: "users/me", method: "GET", token: token)))
        return parseIdentity(json)
    }

    /// Parse a `/users/me` response body into a `NotionIdentity`. Extracted so it can be
    /// exercised in isolation. `ownerName` comes from `bot.owner.user.name` (all optional).
    static func parseIdentity(_ json: [String: Any]) -> NotionIdentity {
        let bot = json["bot"] as? [String: Any]
        let owner = bot?["owner"] as? [String: Any]
        let ownerUser = owner?["user"] as? [String: Any]
        return NotionIdentity(
            integrationName: (json["name"] as? String) ?? (json["id"] as? String) ?? "Notion integration",
            ownerName: ownerUser?["name"] as? String,
            workspaceName: bot?["workspace_name"] as? String
        )
    }

    /// Derive the database title `"<FirstName>’s Muesli Notes"` from a name. Prefers the name
    /// the user entered in Muesli onboarding (`userName`) — internal integrations don't expose
    /// `bot.owner.user.name` — falling back to the Notion workspace name, else plain
    /// `"Muesli Notes"`. Uses a curly apostrophe to match Notion's typographic style.
    static func muesliDatabaseTitle(userName: String?, identity: NotionIdentity) -> String {
        let source = [userName, identity.ownerName, identity.workspaceName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let firstName = source.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return firstName.isEmpty ? "Muesli Notes" : "\(firstName)’s Muesli Notes"
    }

    /// A data source's schema, read from `GET /data_sources/{id}`. In the 2026-03-11 API a
    /// *database* is a container of one or more data sources; pages live under a data source
    /// and the property schema lives here (not on the database).
    struct NotionDataSource {
        let id: String
        let title: String
        /// property name → Notion property type (e.g. "title", "date", "select").
        let properties: [String: String]

        /// The name of the data source's single title property (every one has one).
        var titleProperty: String { properties.first { $0.value == "title" }?.key ?? "Name" }
        /// The name of a date property to populate, if the data source has one.
        var dateProperty: String? { properties.first { $0.value == "date" }?.key }
    }

    /// `GET /data_sources/{id}` — reads a data source's title (for the settings confirmation)
    /// and its property schema (to locate the title and date properties, whose names vary).
    /// The title field may be a rich-text array (`title` → join `plain_text`) or a plain
    /// string (`name`); read `title` first and fall back to `name`.
    static func retrieveDataSource(id: String, token: String) async throws -> NotionDataSource {
        let data = try await send(request(path: "data_sources/\(id)", method: "GET", token: token))
        let json = try jsonObject(data)
        var props: [String: String] = [:]
        for (name, value) in (json["properties"] as? [String: Any]) ?? [:] {
            if let dict = value as? [String: Any], let type = dict["type"] as? String {
                props[name] = type
            }
        }
        let title = dataSourceTitle(json)
        return NotionDataSource(id: json["id"] as? String ?? id,
                                title: title.isEmpty ? "Untitled data source" : title,
                                properties: props)
    }

    struct NotionDatabaseSummary: Identifiable, Equatable, Sendable {
        /// The **data source id** — the sync target we store — from `createDatabase` or a
        /// `listDataSources` result. (Pages are a separate `NotionPage` type so a page id and a
        /// data-source id are never confused at the create-database call site.)
        let id: String
        let title: String
        var url: String = ""
    }

    /// A page the integration can see, used as the parent when creating a new database. A
    /// deliberately separate type from `NotionDatabaseSummary` so a page id and a data-source id
    /// aren't interchangeable at the `createDatabase(parentPageID:)` call site.
    struct NotionPage: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
    }

    /// Runs a cursor-paginated Notion endpoint to exhaustion. `makeRequest` builds the request
    /// for a given `start_cursor` (nil on the first page); `collect` receives each page's parsed
    /// JSON body. Advances via the response's `has_more` / `next_cursor`.
    private static func paginate(
        makeRequest: (_ cursor: String?) throws -> URLRequest,
        collect: (_ json: [String: Any]) -> Void
    ) async throws {
        var cursor: String?
        repeat {
            let json = try jsonObject(try await send(makeRequest(cursor)))
            collect(json)
            cursor = (json["has_more"] as? Bool == true) ? json["next_cursor"] as? String : nil
        } while cursor != nil
    }

    /// `POST /search` filtered to data sources — lists every data source shared with the
    /// integration, so we can converge a second machine on an existing "…Muesli Notes" one.
    static func listDataSources(token: String) async throws -> [NotionDatabaseSummary] {
        var out: [NotionDatabaseSummary] = []
        try await paginate(makeRequest: { cursor in
            var body: [String: Any] = [
                "filter": ["value": "data_source", "property": "object"],
                "page_size": 100,
            ]
            if let cursor { body["start_cursor"] = cursor }
            return try request(path: "search", method: "POST", token: token, body: body)
        }, collect: { json in
            for ds in (json["results"] as? [[String: Any]]) ?? [] {
                guard let id = ds["id"] as? String else { continue }
                let title = dataSourceTitle(ds)
                out.append(NotionDatabaseSummary(id: id, title: title.isEmpty ? "Untitled data source" : title))
            }
        })
        return out
    }

    /// A data source object's title: prefer the rich-text `title` array (join `plain_text`),
    /// fall back to a plain `name` string.
    private static func dataSourceTitle(_ obj: [String: Any]) -> String {
        let fromArray = ((obj["title"] as? [[String: Any]]) ?? [])
            .compactMap { $0["plain_text"] as? String }
            .joined()
        if !fromArray.isEmpty { return fromArray }
        return (obj["name"] as? String) ?? ""
    }

    /// `POST /search` filtered to pages — pages the integration can see, used as parents
    /// when creating a new database.
    static func listPages(token: String) async throws -> [NotionPage] {
        var topLevel: [NotionPage] = []
        var nested: [NotionPage] = []
        try await paginate(makeRequest: { cursor in
            var body: [String: Any] = ["filter": ["value": "page", "property": "object"], "page_size": 100]
            if let cursor { body["start_cursor"] = cursor }
            return try request(path: "search", method: "POST", token: token, body: body)
        }, collect: { json in
            for page in (json["results"] as? [[String: Any]]) ?? [] {
                guard let id = page["id"] as? String else { continue }
                let summary = NotionPage(id: id, title: pageTitle(page))
                // Prefer workspace-level (top-level) pages so the Muesli page lands as close
                // to the sidebar root as the API allows.
                if (page["parent"] as? [String: Any])?["type"] as? String == "workspace" {
                    topLevel.append(summary)
                } else {
                    nested.append(summary)
                }
            }
        })
        return topLevel + nested
    }

    /// The result of creating a database: the id we actually store and sync against is the
    /// **data source id** (`dataSourceID`), extracted from `data_sources[0].id`. `databaseID`
    /// is the parent container id, kept for logging/URL only.
    struct CreatedDatabase {
        let databaseID: String
        let dataSourceID: String
        let title: String
        var url: String = ""
    }

    /// Build the `POST /databases` request body (pure, so it can be shape-tested). In the
    /// 2026-03-11 API the property schema nests under `initial_data_source`; `title`, `icon`,
    /// `cover`, and `description` stay at the database top level. The database is always
    /// created under `parentPageID` (a page the user shared with the integration): internal
    /// integration tokens cannot create anything at the workspace root — Notion rejects it
    /// with "Internal integrations aren't owned by a single user."
    static func createDatabaseBody(parentPageID: String, title: String) -> [String: Any] {
        let trimmedParent = parentPageID.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent: [String: Any] = ["type": "page_id", "page_id": trimmedParent]
        // Welcome copy — two lines separated by a blank line; Notion preserves the newlines
        // inside a single rich_text `text.content`. Inlined here (the only remaining rich-text
        // need) now that the block converter is gone.
        let welcome = "👋 Welcome to your meeting notes in Notion!\n\nThis database seamlessly connects with Muesli to help you capture your meeting notes."
        return [
            "parent": parent,
            "title": [["type": "text", "text": ["content": title]]],
            "icon": muesliIcon,
            "cover": muesliCover,
            // DOC-UNCERTAIN (isolated): if top-level `description` is rejected at 2026-03-11,
            // dropping this one line is the whole fix (it's non-critical branding copy).
            "description": [["type": "text", "text": ["content": welcome]]],
            "initial_data_source": [
                "properties": [
                    "Name": ["title": [String: Any]()],
                    "Date": ["date": [String: Any]()],
                    "Type": ["select": ["options": [["name": "Meeting"], ["name": "Dictation"]]]],
                    "Meeting type": ["select": [String: Any]()],
                    "Created by": ["rich_text": [String: Any]()],
                ],
            ],
        ]
    }

    /// `POST /databases` — creates a branded database with `Name` (title), `Date`, `Type`,
    /// `Meeting type`, and `Created by` properties, matching the Granola-style layout the
    /// push populates. Returns the created database, **including the data source id** we store
    /// and use for everything else (extracted from `data_sources[0].id`).
    static func createDatabase(parentPageID: String, title: String, token: String) async throws -> CreatedDatabase {
        let body = createDatabaseBody(parentPageID: parentPageID, title: title)
        let json = try jsonObject(try await send(request(path: "databases", method: "POST", token: token, body: body)))
        let databaseID = json["id"] as? String ?? ""
        let created = ((json["title"] as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
        // The sync target: the first data source of the new database.
        guard let dataSourceID = (json["data_sources"] as? [[String: Any]])?.first?["id"] as? String,
              !dataSourceID.isEmpty else {
            throw NotionError.unexpectedResponse("create database: missing data_sources[0].id")
        }
        return CreatedDatabase(databaseID: databaseID,
                               dataSourceID: dataSourceID,
                               title: created.isEmpty ? title : created,
                               url: json["url"] as? String ?? "")
    }

    private static func pageTitle(_ page: [String: Any]) -> String {
        for (_, value) in (page["properties"] as? [String: Any]) ?? [:] {
            if let prop = value as? [String: Any], prop["type"] as? String == "title",
               let arr = prop["title"] as? [[String: Any]] {
                let text = arr.compactMap { $0["plain_text"] as? String }.joined()
                if !text.isEmpty { return text }
            }
        }
        return "Untitled page"
    }

    /// Build the `POST /pages` request body (pure, so it can be shape-tested). The parent is a
    /// `data_source_id`; the page body is a Notion-flavored Markdown string under `markdown`
    /// (mutually exclusive with `children`, which we never send).
    static func createPageBody(dataSourceID: String, properties: [String: Any], markdown: String, icon: [String: Any]?) -> [String: Any] {
        var body: [String: Any] = [
            "parent": ["type": "data_source_id", "data_source_id": dataSourceID],
            "properties": properties,
            "markdown": markdown,
        ]
        if let icon { body["icon"] = icon }
        return body
    }

    /// `POST /pages` — creates a page under `dataSourceID` with `properties`, an `icon`, and a
    /// Notion-flavored Markdown body. Returns the new page id.
    @discardableResult
    static func createPage(
        dataSourceID: String,
        properties: [String: Any],
        markdown: String,
        token: String,
        icon: [String: Any]? = nil
    ) async throws -> String {
        let body = createPageBody(dataSourceID: dataSourceID, properties: properties, markdown: markdown, icon: icon)
        let data = try await send(request(path: "pages", method: "POST", token: token, body: body))
        guard let id = try jsonObject(data)["id"] as? String else {
            throw NotionError.unexpectedResponse("create page: missing id")
        }
        return id
    }

    /// `PATCH /pages/{id}` — updates a page's properties (title/date/status on re-push).
    static func updatePageProperties(pageID: String, properties: [String: Any], token: String) async throws {
        _ = try await send(request(path: "pages/\(pageID)", method: "PATCH", token: token,
                                   body: ["properties": properties]))
    }

    /// `GET /blocks/{pageID}/children` — the ids of a page's direct child blocks, paginated
    /// (page_size 100). Used to clear a page's body before re-inserting fresh Markdown, since
    /// the markdown endpoint has no working full-replace op (see `insertPageMarkdown`).
    static func pageChildBlockIDs(pageID: String, token: String) async throws -> [String] {
        var ids: [String] = []
        try await paginate(makeRequest: { cursor in
            var path = "blocks/\(pageID)/children?page_size=100"
            if let cursor {
                // Notion cursors are opaque base64 and can contain +, /, = — percent-encode so
                // they don't malform the query string. Encode everything but unreserved chars.
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                let encoded = cursor.addingPercentEncoding(withAllowedCharacters: allowed) ?? cursor
                path += "&start_cursor=\(encoded)"
            }
            return try request(path: path, method: "GET", token: token)
        }, collect: { json in
            for block in (json["results"] as? [[String: Any]]) ?? [] {
                if let id = block["id"] as? String { ids.append(id) }
            }
        })
        return ids
    }

    /// `DELETE /blocks/{blockID}` — archives a block (a page/database/child block). Used to
    /// clear a synced page's existing body blocks before re-inserting fresh Markdown.
    static func deleteBlock(blockID: String, token: String) async throws {
        _ = try await send(request(path: "blocks/\(blockID)", method: "DELETE", token: token))
    }

    /// `PATCH /pages/{pageID}/markdown` — appends Notion-flavored Markdown to a page's body.
    /// The endpoint's `type` is one of `insert_content` / `replace_content_range` /
    /// `update_content`; the doc's `replace_content` op does NOT exist at this API version.
    /// `insert_content` only *appends*, so a full-body re-sync clears the page's child blocks
    /// first (via `pageChildBlockIDs` + `deleteBlock`) and then inserts the fresh Markdown.
    static func insertPageMarkdown(pageID: String, markdown: String, token: String) async throws {
        _ = try await send(request(path: "pages/\(pageID)/markdown", method: "PATCH", token: token,
                                   body: ["type": "insert_content",
                                          "insert_content": ["content": markdown]]))
    }

    // MARK: - Request plumbing

    private static func request(path: String, method: String, token: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: "\(apiBase.absoluteString)/\(path)") else {
            throw NotionError.unexpectedResponse("bad url for \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    /// Executes a request with a bounded retry. Retries on 429/529 for ALL methods (honoring
    /// `Retry-After`), since a rate-limited request was rejected, not processed. Transient 5xx
    /// (500/502/503/504) and URLSession transport errors are retried ONLY for idempotent methods
    /// (GET/HEAD/DELETE): a POST/PATCH may have reached Notion and mutated state even though the
    /// response was lost, so retrying it would duplicate the write (e.g. a second `POST /pages`).
    /// Non-retryable 4xx (except 429) throw immediately.
    private static func send(_ request: URLRequest, maxRetries: Int = 4) async throws -> Data {
        var attempt = 0
        let method = (request.httpMethod ?? "GET").uppercased()
        let idempotent = ["GET", "HEAD", "DELETE"].contains(method)
        // Capped exponential-ish backoff shared by every retry path.
        func backoff(retryAfterHeader: String? = nil) async throws {
            let hinted = retryAfterHeader.flatMap(Double.init) ?? Double(attempt)
            try await Task.sleep(nanoseconds: UInt64(min(max(hinted, 1), 30) * 1_000_000_000))
        }
        while true {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                // Transport error (connection dropped, timeout, DNS, …) — retry bounded, but only
                // for idempotent methods so a non-idempotent write that may already have landed
                // isn't duplicated.
                if idempotent, attempt < maxRetries {
                    attempt += 1
                    try await backoff()
                    continue
                }
                throw NotionError.requestFailed(error)
            }
            guard let http = response as? HTTPURLResponse else {
                throw NotionError.unexpectedResponse("no HTTP response")
            }
            if (200..<300).contains(http.statusCode) { return data }
            let isRateLimited = http.statusCode == 429 || http.statusCode == 529
            let isTransient5xx = [500, 502, 503, 504].contains(http.statusCode)
            // Rate limits are safe to retry for any method (rejected, not processed). Transient
            // 5xx is only safe for idempotent methods — a POST/PATCH may have mutated state.
            let shouldRetry = isRateLimited || (isTransient5xx && idempotent)
            if shouldRetry, attempt < maxRetries {
                attempt += 1
                try await backoff(retryAfterHeader: isRateLimited ? http.value(forHTTPHeaderField: "Retry-After") : nil)
                continue
            }
            throw NotionError.http(status: http.statusCode, message: errorMessage(from: data))
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotionError.unexpectedResponse("response was not a JSON object")
        }
        return obj
    }

    private static func errorMessage(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? "unknown error"
        }
        // Notion errors: { "code": ..., "message": ... }
        return (obj["message"] as? String) ?? (obj["code"] as? String) ?? "unknown error"
    }
}

enum NotionError: LocalizedError {
    case http(status: Int, message: String)
    case requestFailed(Error)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case let .http(status, message):
            return "Notion returned \(status): \(message)"
        case let .requestFailed(error):
            return "Notion request failed: \(error.localizedDescription)"
        case let .unexpectedResponse(detail):
            return "Unexpected Notion response: \(detail)"
        }
    }

    /// Auth failures (expired/invalid token) or missing permission (database not shared).
    /// The UI should surface these as "reconnect"; the sync pauses and resumes once fixed.
    var isAuthOrPermission: Bool {
        if case let .http(status, _) = self { return status == 401 || status == 403 }
        return false
    }

    /// The referenced page/block no longer exists — e.g. a synced page was deleted in
    /// Notion. The engine recreates it on the next push.
    var isNotFound: Bool {
        if case let .http(status, _) = self { return status == 404 }
        return false
    }

    /// The page exists but is archived (in Notion's trash) and can't be edited — treated
    /// like a deletion, so the engine recreates it.
    var isArchived: Bool {
        if case let .http(status, message) = self { return status == 400 && message.lowercased().contains("archived") }
        return false
    }
}
