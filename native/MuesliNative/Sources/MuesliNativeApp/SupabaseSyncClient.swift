import Foundation
import MuesliCore

enum SupabaseSyncError: LocalizedError {
    case missingConfiguration(String)
    case invalidURL(String)
    case requestFailed(Int, String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let field):
            return "Missing Supabase \(field)."
        case .invalidURL(let value):
            return "Invalid Supabase URL: \(value)"
        case .requestFailed(let status, let body):
            return "Supabase request failed with HTTP \(status): \(body)"
        case .encodingFailed:
            return "Supabase payload could not be encoded."
        }
    }
}

struct SalesAssistLibrarySnapshot: Equatable {
    var knowledgeBase: String
    var objections: [SalesAssistObjection]
    var liveCues: [SalesAssistLiveCue]
    var updatedAt: String?

    var isEmpty: Bool {
        knowledgeBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && objections.isEmpty
            && liveCues.isEmpty
    }
}

struct SupabaseMeetingRecord: Codable, Equatable {
    var id: String
    var workspaceID: String
    var localID: String
    var appInstallID: String
    var userID: String?
    var title: String
    var source: String
    var transcript: String
    var summary: String
    var startedAt: String
    var endedAt: String?
    var metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case localID = "local_id"
        case appInstallID = "app_install_id"
        case userID = "user_id"
        case title
        case source
        case transcript
        case summary
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case metadata
    }

    static func record(from meeting: MeetingRecord, config: AppConfig) throws -> SupabaseMeetingRecord {
        let userID = SupabaseSyncClient.resolvedUserID(config)
        let startedAt = ISO8601DateFormatter.supabaseNormalizedString(from: meeting.startTime) ?? meeting.startTime
        let endedAt = ISO8601DateFormatter.supabaseEndString(
            startTime: meeting.startTime,
            durationSeconds: meeting.durationSeconds
        )
        var metadata: [String: String] = [
            "local_schema_version": "1",
            "sync_source": "sales_caddie_desktop",
            "status": meeting.status.rawValue,
            "word_count": String(meeting.wordCount),
            "duration_seconds": String(meeting.durationSeconds),
            "notes_state": meeting.notesState.rawValue,
        ]
        if let calendarEventID = meeting.calendarEventID { metadata["calendar_event_id"] = calendarEventID }
        if let folderID = meeting.folderID { metadata["folder_id"] = String(folderID) }
        if let templateID = meeting.selectedTemplateID { metadata["template_id"] = templateID }
        if let templateName = meeting.selectedTemplateName { metadata["template_name"] = templateName }
        if let templateKind = meeting.selectedTemplateKind { metadata["template_kind"] = templateKind.rawValue }
        if !meeting.manualNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["manual_notes"] = meeting.manualNotes
        }

        return SupabaseMeetingRecord(
            id: SupabaseSyncClient.stableUUIDString(
                seed: "meeting|\(config.supabaseWorkspaceID)|\(config.salesCaddieInstallID)|\(meeting.id)"
            ),
            workspaceID: try SupabaseSyncClient.required(config.supabaseWorkspaceID, field: "workspace ID"),
            localID: String(meeting.id),
            appInstallID: config.salesCaddieInstallID,
            userID: userID.isEmpty ? nil : userID,
            title: meeting.title,
            source: meeting.source.rawValue,
            transcript: meeting.rawTranscript,
            summary: meeting.formattedNotes,
            startedAt: startedAt,
            endedAt: endedAt,
            metadata: metadata
        )
    }
}

struct SupabaseCallInsightRecord: Codable, Equatable {
    var workspaceID: String
    var appInstallID: String
    var userID: String?
    var kind: String
    var name: String
    var evidence: String
    var guidance: String
    var confidence: Double?
    var metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case appInstallID = "app_install_id"
        case userID = "user_id"
        case kind
        case name
        case evidence
        case guidance
        case confidence
        case metadata
    }

    static func record(
        from alert: SalesAssistAlert,
        localMeetingID: Int64?,
        config: AppConfig
    ) throws -> SupabaseCallInsightRecord {
        let userID = SupabaseSyncClient.resolvedUserID(config)
        var metadata: [String: String] = [
            "local_schema_version": "1",
            "sync_source": "sales_caddie_desktop",
            "priority": alert.priority,
            "client_observed_at": ISO8601DateFormatter.supabase.string(from: alert.updatedAt),
        ]
        if let localMeetingID {
            metadata["local_meeting_id"] = String(localMeetingID)
        }

        return SupabaseCallInsightRecord(
            workspaceID: try SupabaseSyncClient.required(config.supabaseWorkspaceID, field: "workspace ID"),
            appInstallID: config.salesCaddieInstallID,
            userID: userID.isEmpty ? nil : userID,
            kind: alert.kind,
            name: alert.objection,
            evidence: alert.quote,
            guidance: alert.talkTrack,
            confidence: nil,
            metadata: metadata
        )
    }
}

struct SupabaseSalesLibraryItem: Codable, Equatable {
    var id: String
    var workspaceID: String?
    var kind: String
    var name: String
    var content: String
    var triggerPhrases: [String]
    var guidance: String
    var priority: Int
    var isEnabled: Bool?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case kind
        case name
        case content
        case triggerPhrases = "trigger_phrases"
        case guidance
        case priority
        case isEnabled = "is_enabled"
        case updatedAt = "updated_at"
    }

    var normalizedKind: String {
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "kb", "knowledge", "knowledge_base", "knowledge-base":
            return "knowledge_base"
        case "battlecard", "battlecards", "competitor":
            return "competitor"
        default:
            return kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    var priorityLabel: String {
        switch priority {
        case 2...:
            return "high"
        case ..<0:
            return "low"
        default:
            return "medium"
        }
    }

    static func snapshot(from records: [SupabaseSalesLibraryItem]) -> SalesAssistLibrarySnapshot {
        let enabled = records.filter { $0.isEnabled ?? true }
        let knowledgeBase = enabled
            .filter { $0.normalizedKind == "knowledge_base" }
            .sorted(by: recordSort)
            .map(\.content)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        let objections = enabled
            .filter { $0.normalizedKind == "objection" }
            .sorted(by: recordSort)
            .map { record in
                SalesAssistObjection(
                    id: record.id,
                    name: record.name,
                    priority: record.priorityLabel,
                    triggerPhrases: record.triggerPhrases.joined(separator: "\n"),
                    guidance: record.guidance.isEmpty ? record.content : record.guidance
                )
            }

        let liveCueKinds = Set(SalesAssistLiveCue.supportedKinds.filter { $0 != "objection" })
        let liveCues = enabled
            .filter { liveCueKinds.contains($0.normalizedKind) }
            .sorted(by: recordSort)
            .map { record in
                SalesAssistLiveCue(
                    id: record.id,
                    kind: record.normalizedKind,
                    name: record.name,
                    priority: record.priorityLabel,
                    triggerPhrases: record.triggerPhrases.joined(separator: "\n"),
                    guidance: record.guidance.isEmpty ? record.content : record.guidance
                )
            }

        let updatedAt = enabled.compactMap(\.updatedAt).max()
        return SalesAssistLibrarySnapshot(
            knowledgeBase: knowledgeBase,
            objections: objections,
            liveCues: liveCues,
            updatedAt: updatedAt
        )
    }

    static func records(from config: AppConfig) throws -> [SupabaseSalesLibraryItem] {
        let configuredWorkspaceID = config.supabaseWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cloudWorkspaceSlug = config.salesCaddieCloudWorkspaceSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceID = try SupabaseSyncClient.required(
            configuredWorkspaceID.isEmpty ? cloudWorkspaceSlug : configuredWorkspaceID,
            field: "workspace ID"
        )
        var records: [SupabaseSalesLibraryItem] = []

        let knowledgeBase = config.salesAssistKnowledgeBase.trimmingCharacters(in: .whitespacesAndNewlines)
        if !knowledgeBase.isEmpty {
            records.append(SupabaseSalesLibraryItem(
                id: config.salesAssistKnowledgeBaseItemID,
                workspaceID: workspaceID,
                kind: "knowledge_base",
                name: "Sales Knowledge Base",
                content: knowledgeBase,
                triggerPhrases: [],
                guidance: "",
                priority: 1,
                isEnabled: true,
                updatedAt: nil
            ))
        }

        records += config.salesAssistObjections.map { objection in
            SupabaseSalesLibraryItem(
                id: objection.id,
                workspaceID: workspaceID,
                kind: "objection",
                name: objection.name,
                content: "",
                triggerPhrases: triggerPhrases(from: objection.triggerPhrases),
                guidance: objection.guidance,
                priority: priorityValue(objection.priority),
                isEnabled: true,
                updatedAt: nil
            )
        }

        records += config.salesAssistLiveCues.map { cue in
            SupabaseSalesLibraryItem(
                id: cue.id,
                workspaceID: workspaceID,
                kind: cue.kind,
                name: cue.name,
                content: "",
                triggerPhrases: triggerPhrases(from: cue.triggerPhrases),
                guidance: cue.guidance,
                priority: priorityValue(cue.priority),
                isEnabled: true,
                updatedAt: nil
            )
        }

        return records
    }

    private static func recordSort(_ lhs: SupabaseSalesLibraryItem, _ rhs: SupabaseSalesLibraryItem) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func triggerPhrases(from text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n,;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func priorityValue(_ value: String) -> Int {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high":
            return 2
        case "low":
            return -1
        default:
            return 1
        }
    }
}

struct SupabaseSyncClient {
    private static let schema = "sales_app"

    static func syncSalesAgentHistoryItem(_ item: SalesAgentHistoryItem, config: AppConfig) async throws {
        guard config.supabaseSyncEnabled, config.supabaseSyncJessicaHistory else { return }

        let userID = trimmed(config.supabaseUserID).isEmpty
            ? trimmed(config.userName)
            : trimmed(config.supabaseUserID)

        var payload: [String: Any] = [
            "id": item.id,
            "workspace_id": try required(config.supabaseWorkspaceID, field: "workspace ID"),
            "app_install_id": config.salesCaddieInstallID,
            "provider": item.provider,
            "status": item.status,
            "transcript": item.transcript,
            "response": item.response,
            "client_created_at": ISO8601DateFormatter.supabase.string(from: item.createdAt),
            "source_app": AppIdentity.displayName,
            "metadata": [
                "local_schema_version": 1,
                "sync_source": "sales_caddie_desktop",
            ],
        ]

        if !userID.isEmpty {
            payload["user_id"] = userID
        }
        if let plannerCommand = item.plannerCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plannerCommand.isEmpty {
            payload["planner_command"] = plannerCommand
        }

        try await upsert(
            table: "sales_caddie_agent_events",
            payload: [payload],
            onConflict: "id",
            config: config
        )
    }

    static func syncMeeting(_ meeting: MeetingRecord, config: AppConfig) async throws {
        guard config.supabaseSyncEnabled, config.supabaseSyncTranscripts else { return }
        let record = try SupabaseMeetingRecord.record(from: meeting, config: config)
        let payload = try jsonPayload(from: [record])
        try await upsert(
            table: "sales_caddie_meetings",
            payload: payload,
            onConflict: "id",
            config: config
        )
    }

    static func syncMeetings(_ meetings: [MeetingRecord], config: AppConfig) async throws {
        guard config.supabaseSyncEnabled, config.supabaseSyncTranscripts else { return }
        let records = try meetings.map { try SupabaseMeetingRecord.record(from: $0, config: config) }
        guard !records.isEmpty else { return }
        let payload = try jsonPayload(from: records)
        try await upsert(
            table: "sales_caddie_meetings",
            payload: payload,
            onConflict: "id",
            config: config
        )
    }

    static func syncCallInsight(
        alert: SalesAssistAlert,
        localMeetingID: Int64?,
        config: AppConfig
    ) async throws {
        guard config.supabaseSyncEnabled else { return }
        let record = try SupabaseCallInsightRecord.record(
            from: alert,
            localMeetingID: localMeetingID,
            config: config
        )
        let payload = try jsonPayload(from: [record])
        try await insert(
            table: "sales_caddie_call_insights",
            payload: payload,
            config: config
        )
    }

    static func fetchSalesLibrarySnapshot(config: AppConfig) async throws -> SalesAssistLibrarySnapshot {
        guard config.supabaseSyncEnabled, config.supabaseSyncSalesLibrary else {
            return SalesAssistLibrarySnapshot(knowledgeBase: "", objections: [], liveCues: [], updatedAt: nil)
        }

        let workspaceID = try required(config.supabaseWorkspaceID, field: "workspace ID")
        let records: [SupabaseSalesLibraryItem] = try await get(
            table: "sales_caddie_library_items",
            queryItems: [
                URLQueryItem(name: "select", value: "id,workspace_id,kind,name,content,trigger_phrases,guidance,priority,is_enabled,updated_at"),
                URLQueryItem(name: "workspace_id", value: "eq.\(workspaceID)"),
                URLQueryItem(name: "is_enabled", value: "eq.true"),
                URLQueryItem(name: "order", value: "priority.desc,name.asc"),
            ],
            config: config
        )
        return SupabaseSalesLibraryItem.snapshot(from: records)
    }

    static func syncSalesLibrarySnapshot(config: AppConfig) async throws {
        guard config.supabaseSyncEnabled, config.supabaseSyncSalesLibrary else { return }
        let records = try SupabaseSalesLibraryItem.records(from: config)
        guard !records.isEmpty else { return }
        let payload = try jsonPayload(from: records)
        try await upsert(
            table: "sales_caddie_library_items",
            payload: payload,
            onConflict: "id",
            config: config
        )
    }

    private static func insert(
        table: String,
        payload: [[String: Any]],
        config: AppConfig
    ) async throws {
        let url = try restURL(table: table, queryItems: [], config: config)
        let anonKey = try required(config.supabaseAnonKey, field: "anon key")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(schema, forHTTPHeaderField: "Accept-Profile")
        request.setValue(schema, forHTTPHeaderField: "Content-Profile")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseSyncError.requestFailed(httpResponse.statusCode, body)
        }
    }

    private static func upsert(
        table: String,
        payload: [[String: Any]],
        onConflict: String,
        config: AppConfig
    ) async throws {
        let url = try restURL(
            table: table,
            queryItems: [URLQueryItem(name: "on_conflict", value: onConflict)],
            config: config
        )
        let anonKey = try required(config.supabaseAnonKey, field: "anon key")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(schema, forHTTPHeaderField: "Accept-Profile")
        request.setValue(schema, forHTTPHeaderField: "Content-Profile")
        request.setValue("resolution=merge-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseSyncError.requestFailed(httpResponse.statusCode, body)
        }
    }

    private static func get<T: Decodable>(
        table: String,
        queryItems: [URLQueryItem],
        config: AppConfig
    ) async throws -> T {
        let url = try restURL(table: table, queryItems: queryItems, config: config)
        let anonKey = try required(config.supabaseAnonKey, field: "anon key")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(schema, forHTTPHeaderField: "Accept-Profile")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return try JSONDecoder().decode(T.self, from: data)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SupabaseSyncError.requestFailed(httpResponse.statusCode, body)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func restURL(
        table: String,
        queryItems: [URLQueryItem],
        config: AppConfig
    ) throws -> URL {
        let baseURLString = try required(config.supabaseURL, field: "URL")
        guard let baseURL = URL(string: baseURLString) else {
            throw SupabaseSyncError.invalidURL(baseURLString)
        }

        let restURL = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(table)

        guard var components = URLComponents(url: restURL, resolvingAgainstBaseURL: false) else {
            throw SupabaseSyncError.invalidURL(baseURLString)
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw SupabaseSyncError.invalidURL(baseURLString)
        }
        return url
    }

    private static func jsonPayload<T: Encodable>(from records: [T]) throws -> [[String: Any]] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        let data = try encoder.encode(records)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SupabaseSyncError.encodingFailed
        }
        return payload
    }

    static func resolvedUserID(_ config: AppConfig) -> String {
        let userID = trimmed(config.supabaseUserID)
        return userID.isEmpty ? trimmed(config.userName) : userID
    }

    static func stableUUIDString(seed: String) -> String {
        let bytes = Array(seed.utf8)
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in bytes {
            first ^= UInt64(byte)
            first &*= 0x100000001b3
            second ^= UInt64(byte) &+ 0x9e3779b97f4a7c15
            second &*= 0x100000001b3
        }

        var uuidBytes = withUnsafeBytes(of: first.bigEndian, Array.init)
            + withUnsafeBytes(of: second.bigEndian, Array.init)
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80

        return String(
            format: "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5],
            uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9],
            uuidBytes[10], uuidBytes[11], uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        )
    }

    static func required(_ value: String, field: String) throws -> String {
        let value = trimmed(value)
        guard !value.isEmpty else {
            throw SupabaseSyncError.missingConfiguration(field)
        }
        return value
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ISO8601DateFormatter {
    static let supabase: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func supabaseNormalizedString(from value: String) -> String? {
        guard let date = parseLenient(value) else { return nil }
        return supabase.string(from: date)
    }

    static func supabaseEndString(startTime: String, durationSeconds: Double) -> String? {
        guard let start = parseLenient(startTime) else { return nil }
        return supabase.string(from: start.addingTimeInterval(durationSeconds))
    }

    private static func parseLenient(_ value: String) -> Date? {
        if let date = supabase.date(from: value) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }
}
