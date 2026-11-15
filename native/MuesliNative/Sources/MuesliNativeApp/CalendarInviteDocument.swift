import Foundation

struct CalendarInviteDocument: Equatable, Sendable {
    let url: URL
    let title: String
    let hasInviteTitle: Bool

    var symbol: String {
        if url.host == "docs.google.com" {
            if url.path.hasPrefix("/spreadsheets/") { return "tablecells" }
            if url.path.hasPrefix("/presentation/") { return "rectangle.on.rectangle" }
            return "doc.text"
        }
        return url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc"
    }

    /// Resolve only known wrappers, without a network request. Never accept executable,
    /// local-file or credential-bearing URLs, including inside redirects.
    static func safeURL(_ value: String) -> URL? {
        var value = decodeHTML(value).trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<5 {
            guard let parts = URLComponents(string: value),
                  ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
                  let host = parts.host?.lowercased(), !host.isEmpty,
                  parts.user == nil, parts.password == nil, let url = parts.url else { return nil }
            let key: String?
            if ["www.google.com", "google.com"].contains(host), parts.path == "/url" {
                key = parts.queryItems?.contains(where: { $0.name == "q" }) == true ? "q" : "url"
            } else if host == "www.google.com", parts.path == "/calendar/event" {
                key = nil
            } else if host == "safelinks.protection.outlook.com" || host.hasSuffix(".safelinks.protection.outlook.com") {
                key = "url"
            } else { key = nil }
            guard let key else { return url }
            guard let destination = parts.queryItems?.first(where: { $0.name == key })?.value else { return nil }
            value = destination
        }
        return nil
    }

    static func extract(attachments: [[String: Any]] = [], text: String? = nil, eventURL: URL? = nil,
                        meetingURL: URL? = nil) -> [Self] {
        var result: [Self] = []
        func append(_ value: String, title: String? = nil) {
            guard let url = safeURL(value), !CalendarMonitor.isMeetingURL(url), !isConferenceBoilerplate(url),
                  url != meetingURL.flatMap({ safeURL($0.absoluteString) }) else { return }
            let decoded = title.map { decodeHTML($0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)) } ?? ""
            let clean = decoded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let meaningful = !clean.isEmpty && !clean.lowercased().hasPrefix("http") && !genericTitles.contains(clean.lowercased())
            result.append(Self(url: url, title: meaningful ? clean : fallbackTitle(url), hasInviteTitle: meaningful))
        }
        for attachment in attachments {
            if let url = attachment["fileUrl"] as? String { append(url, title: attachment["title"] as? String) }
        }
        if let text {
            // Parse titles without invoking AppKit's HTML importer (which can deadlock).
            let pattern = #"(?is)<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let url = Range(match.range(at: 1), in: text), let title = Range(match.range(at: 2), in: text) {
                        append(String(text[url]), title: String(text[title]))
                    }
                }
            }
            let plain = decodeHTML(text)
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                    if let url = match.url { append(url.absoluteString) }
                }
            }
        }
        if let eventURL { append(eventURL.absoluteString) }
        return merge(result)
    }

    static func merge(_ documents: [Self]) -> [Self] {
        var result: [Self] = []
        var indices: [String: Int] = [:]
        for document in documents {
            let key = identity(document.url)
            if let index = indices[key] {
                if document.hasInviteTitle && !result[index].hasInviteTitle { result[index] = document }
            } else {
                indices[key] = result.count
                result.append(document)
            }
        }
        return result
    }

    private static func identity(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let components = url.path.split(separator: "/")
        if ["docs.google.com", "drive.google.com"].contains(host) {
            if let d = components.firstIndex(of: "d"), components.indices.contains(d + 1) {
                return "google-file:\(components[d + 1])"
            }
            if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
                return "google-file:\(id)"
            }
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.host = host
        parts?.fragment = nil
        let queryItems = parts?.queryItems?.filter { !$0.name.hasPrefix("utm_") }.sorted { $0.name < $1.name }
        parts?.queryItems = queryItems
        if parts?.queryItems?.isEmpty == true { parts?.queryItems = nil }
        return parts?.string ?? url.absoluteString
    }

    private static func fallbackTitle(_ url: URL) -> String {
        if url.host == "docs.google.com" {
            if url.path.hasPrefix("/document/") { return "Google document" }
            if url.path.hasPrefix("/spreadsheets/") { return "Google spreadsheet" }
            if url.path.hasPrefix("/presentation/") { return "Google presentation" }
        }
        if url.host == "docs.google.com", url.path.hasPrefix("/forms/") { return "Google form" }
        if url.host == "forms.gle" { return "Google form" }
        if url.host == "drive.google.com" { return "Google Drive file" }
        if url.pathExtension.lowercased() == "pdf" { return url.deletingPathExtension().lastPathComponent }
        return url.host ?? "Document"
    }

    static func isConferenceBoilerplate(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "tel.meet" || host.hasSuffix(".tel.meet")
            || host == "meet.google.com"
            || (host == "support.google.com" && url.path.lowercased().hasPrefix("/meet"))
            || (host == "g.co" && url.path.lowercased().hasPrefix("/meet"))
    }

    var needsResolvedTitle: Bool {
        !hasInviteTitle || Self.genericTitles.contains(title.lowercased())
    }

    private static let genericTitles: Set<String> = [
        "google sheet", "google sheets", "google spreadsheet", "spreadsheet", "sheet",
        "google doc", "google docs", "google document", "document", "google slides", "google presentation",
        "form", "forms", "google form", "google forms", "link", "click here", "here", "google drive file"
    ]

    static func decodeHTML(_ text: String) -> String {
        var result = text
        for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let digitsRange = Range(match.range(at: 1), in: result),
                      let entityRange = Range(match.range, in: result) else { continue }
                let digits = String(result[digitsRange])
                let number = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let number, let scalar = UnicodeScalar(number) { result.replaceSubrange(entityRange, with: String(scalar)) }
            }
        }
        return result
    }
}
