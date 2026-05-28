import Foundation

enum HighLevelCRMError: LocalizedError {
    case missingToken
    case missingLocationID
    case invalidURL(String)
    case requestFailed(Int, String)
    case noMatch

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "HighLevel token is missing."
        case .missingLocationID:
            return "HighLevel location ID is missing."
        case .invalidURL(let value):
            return "Invalid HighLevel URL: \(value)"
        case .requestFailed(let status, let body):
            return "HighLevel request failed with HTTP \(status): \(body)"
        case .noMatch:
            return "No matching HighLevel opportunity or contact was found."
        }
    }
}

struct HighLevelCRMConfig: Equatable {
    var baseURL: String
    var token: String
    var locationID: String
    var apiVersion: String = "2023-02-21"

    var isConfigured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !locationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum HighLevelCRMClient {
    static func fetchPreCallRecord(
        for event: UnifiedCalendarEvent,
        config: HighLevelCRMConfig
    ) async throws -> SalesCRMRecord {
        let query = searchQuery(for: event)
        if let opportunityRecord = try await searchOpportunity(query: query, config: config) {
            return opportunityRecord
        }
        if let contactRecord = try await searchContact(query: query, config: config) {
            return contactRecord
        }
        throw HighLevelCRMError.noMatch
    }

    static func testConnection(config: HighLevelCRMConfig) async throws {
        _ = try await searchOpportunity(query: "test", config: config, limit: 1)
    }

    private static func searchOpportunity(
        query: String,
        config: HighLevelCRMConfig,
        limit: Int = 5
    ) async throws -> SalesCRMRecord? {
        let locationID = try requiredLocationID(config)
        var components = URLComponents(url: try baseURL(config).appendingPathComponent("opportunities/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "location_id", value: locationID),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "status", value: "all"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "getTasks", value: "true"),
            URLQueryItem(name: "getNotes", value: "true"),
            URLQueryItem(name: "getCalendarEvents", value: "true"),
        ]
        guard let url = components?.url else {
            throw HighLevelCRMError.invalidURL(config.baseURL)
        }

        let json = try await sendJSONRequest(url: url, method: "GET", config: config)
        guard let opportunity = firstObject(in: json, keys: ["opportunities", "data", "items"]) else { return nil }
        let contact = opportunity["contact"] as? [String: Any]
        let accountName = stringValue(opportunity["name"])
            ?? stringValue(contact?["companyName"])
            ?? stringValue(contact?["name"])
            ?? query
        let contactName = stringValue(contact?["name"])
            ?? [stringValue(contact?["firstName"]), stringValue(contact?["lastName"])]
                .compactMap { $0 }
                .joined(separator: " ")
                .nonEmpty
        let value = numberValue(opportunity["monetaryValue"]).map { formatCurrency($0) }
        let tasks = stringList(from: opportunity["tasks"])
        let lastActivity = stringValue(opportunity["lastActionDate"])
            ?? stringValue(opportunity["updatedAt"])
            ?? stringValue(contact?["dateUpdated"])

        return SalesCRMRecord(
            provider: .highLevel,
            accountName: accountName,
            contactName: contactName,
            stage: stringValue(opportunity["pipelineStageId"]) ?? stringValue(opportunity["status"]),
            owner: stringValue(opportunity["assignedTo"]),
            value: value,
            source: stringValue(opportunity["source"]) ?? stringValue(contact?["source"]),
            lastActivity: lastActivity,
            openTasks: tasks,
            customFields: customFields(from: opportunity["customFields"])
        )
    }

    private static func searchContact(
        query: String,
        config: HighLevelCRMConfig
    ) async throws -> SalesCRMRecord? {
        let locationID = try requiredLocationID(config)
        let url = try baseURL(config).appendingPathComponent("contacts/search")
        let payload: [String: Any] = [
            "locationId": locationID,
            "page": 1,
            "pageLimit": 5,
            "query": query,
        ]
        let json = try await sendJSONRequest(url: url, method: "POST", payload: payload, config: config)
        guard let contact = firstObject(in: json, keys: ["contacts", "data", "items"]) else { return nil }
        let name = stringValue(contact["name"])
            ?? [stringValue(contact["firstName"]), stringValue(contact["lastName"])]
                .compactMap { $0 }
                .joined(separator: " ")
                .nonEmpty
            ?? query
        let company = stringValue(contact["companyName"]) ?? name

        return SalesCRMRecord(
            provider: .highLevel,
            accountName: company,
            contactName: name == company ? nil : name,
            stage: nil,
            owner: stringValue(contact["assignedTo"]),
            value: nil,
            source: stringValue(contact["source"]),
            lastActivity: stringValue(contact["dateUpdated"]) ?? stringValue(contact["dateAdded"]),
            openTasks: stringList(from: contact["tasks"]),
            customFields: customFields(from: contact["customFields"])
        )
    }

    private static func sendJSONRequest(
        url: URL,
        method: String,
        payload: [String: Any]? = nil,
        config: HighLevelCRMConfig
    ) async throws -> [String: Any] {
        let token = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw HighLevelCRMError.missingToken }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.apiVersion, forHTTPHeaderField: "Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw HighLevelCRMError.requestFailed(status, String(body.prefix(240)))
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private static func baseURL(_ config: HighLevelCRMConfig) throws -> URL {
        let value = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://services.leadconnectorhq.com"
            : config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value) else {
            throw HighLevelCRMError.invalidURL(value)
        }
        return url
    }

    private static func requiredLocationID(_ config: HighLevelCRMConfig) throws -> String {
        let value = config.locationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw HighLevelCRMError.missingLocationID }
        return value
    }

    private static func searchQuery(for event: UnifiedCalendarEvent) -> String {
        if let email = event.title.firstEmailAddress {
            return email
        }
        let tokens = event.title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .filter { !["call", "demo", "meeting", "skriber", "with", "the"].contains($0.lowercased()) }
        return tokens.prefix(4).joined(separator: " ").nonEmpty ?? event.title
    }

    private static func firstObject(in json: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let rows = json[key] as? [[String: Any]], let first = rows.first {
                return first
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func stringList(from value: Any?) -> [String] {
        guard let rows = value as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            stringValue(row["title"])
                ?? stringValue(row["body"])
                ?? stringValue(row["description"])
                ?? stringValue(row["name"])
        }
    }

    private static func customFields(from value: Any?) -> [String: String] {
        guard let rows = value as? [[String: Any]] else { return [:] }
        var fields: [String: String] = [:]
        for row in rows {
            guard let id = stringValue(row["id"]) ?? stringValue(row["fieldId"]) ?? stringValue(row["name"]) else { continue }
            let rawValue = row["fieldValue"] ?? row["value"]
            if let string = stringValue(rawValue) {
                fields[id] = string
            }
        }
        return fields
    }

    private static func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var firstEmailAddress: String? {
        let pattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, range: range),
              let swiftRange = Range(match.range, in: self) else { return nil }
        return String(self[swiftRange])
    }
}
