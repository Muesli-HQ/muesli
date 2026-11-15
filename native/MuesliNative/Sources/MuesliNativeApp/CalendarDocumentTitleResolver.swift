import Foundation

/// Public document metadata only: no account integration, cookies, credentials,
/// subresources or document bodies. Unknown/intranet destinations retain invite titles.
@MainActor
final class CalendarDocumentTitleResolver {
    private struct Entry {
        let title: String?
        let expires: Date
    }
    private var cache: [URL: Entry] = [:]
    private let fetch: @Sendable (URL) async -> String?

    init(fetch: @escaping @Sendable (URL) async -> String? = { await CalendarDocumentTitleResolver.fetchPublicTitle($0) }) {
        self.fetch = fetch
    }

    func title(for document: CalendarInviteDocument) -> String {
        guard document.needsResolvedTitle else { return document.title }
        return cache[document.url]?.title ?? document.title
    }

    func resolve(_ documents: [CalendarInviteDocument]) async -> Bool {
        let now = Date()
        var seen: Set<URL> = []
        let urls = documents.filter {
            $0.needsResolvedTitle && Self.supportsMetadata($0.url)
                && (cache[$0.url]?.expires ?? .distantPast) <= now && seen.insert($0.url).inserted
        }.map(\.url)
        var changed = false
        // Bound concurrency and avoid repeatedly requesting inaccessible documents.
        for offset in stride(from: 0, to: urls.count, by: 4) {
            guard !Task.isCancelled else { break }
            let batch = urls[offset..<min(offset + 4, urls.count)]
            let fetch = self.fetch
            let results = await withTaskGroup(of: (URL, String?).self, returning: [(URL, String?)].self) { group in
                for url in batch { group.addTask { (url, await fetch(url)) } }
                var values: [(URL, String?)] = []
                for await value in group { values.append(value) }
                return values
            }
            guard !Task.isCancelled else { break }
            for (url, title) in results {
                changed = changed || title != nil
                cache[url] = Entry(title: title, expires: now.addingTimeInterval(title == nil ? 900 : 3600))
            }
        }
        if cache.count > 512 { cache = cache.filter { $0.value.expires > now } }
        return changed
    }

    nonisolated static func supportsMetadata(_ url: URL) -> Bool {
        guard let safe = CalendarInviteDocument.safeURL(url.absoluteString), safe == url,
              safe.scheme?.lowercased() == "https", safe.port == nil || safe.port == 443,
              let host = safe.host?.lowercased() else { return false }
        return ["docs.google.com", "drive.google.com", "forms.gle", "www.notion.so", "notion.so", "www.figma.com", "figma.com", "www.dropbox.com", "dropbox.com", "paper.dropbox.com"].contains(host)
            || host.hasSuffix(".notion.site") || host.hasSuffix(".atlassian.net")
    }

    nonisolated static func pageTitle(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<title\b[^>]*>(.*?)</title\s*>"#),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        var title = CalendarInviteDocument.decodeHTML(String(html[range]))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Avoid replacing useful fallbacks with authentication/error/product landing pages.
        let lower = title.lowercased()
        let placeholderTitles: Set<String> = [
            "sign in", "sign-in", "signin", "login", "log in", "access denied", "request access", "you need access", "page not found",
            "google accounts", "google docs", "google sheets", "google forms", "google drive", "notion", "figma", "dropbox",
            "google docs: sign-in", "google sheets: sign-in", "google drive: sign-in", "google forms: sign-in"
        ]
        guard !title.isEmpty, title.count <= 200, !placeholderTitles.contains(lower),
              !lower.hasPrefix("sign in - "), !lower.hasPrefix("error 404"), !lower.hasPrefix("error 403") else { return nil }
        for suffix in [" - Google Sheets", " - Google Docs", " - Google Slides", " - Google Forms", " - Google Drive", " – Figma", " | Figma", " | Notion"] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        return title.isEmpty ? nil : title
    }

    nonisolated private static func fetchPublicTitle(_ url: URL) async -> String? {
        guard supportsMetadata(url) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: DocumentMetadataRedirectGuard())
            guard let response = response as? HTTPURLResponse, [200, 206].contains(response.statusCode),
                  let destination = response.url, supportsMetadata(destination),
                  response.mimeType?.lowercased() == "text/html" else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard !Task.isCancelled, data.count < 65_536 else { return nil }
                data.append(byte)
                if byte == 62 { // Inspect only complete tags; stop before the document body.
                    let head = String(decoding: data, as: UTF8.self)
                    if head.lowercased().contains("</title>") { return pageTitle(head) }
                    if head.lowercased().contains("</head>") || head.lowercased().contains("<body") { return nil }
                }
            }
        } catch { return nil }
        return nil
    }
}

private final class DocumentMetadataRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, CalendarDocumentTitleResolver.supportsMetadata(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
