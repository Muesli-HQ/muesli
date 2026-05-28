import Foundation
import MuesliCore

enum SalesCaddieCloudAPIError: LocalizedError {
    case missingConfiguration(String)
    case invalidURL(String)
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let field):
            return "Missing Sales Caddie Cloud \(field)."
        case .invalidURL(let value):
            return "Invalid Sales Caddie Cloud URL: \(value)"
        case .requestFailed(let status, let body):
            return "Sales Caddie Cloud request failed with HTTP \(status): \(body)"
        }
    }
}

struct SalesCaddieCloudAPIClient {
    static func heartbeat(config: AppConfig) async throws {
        guard config.salesCaddieCloudSyncEnabled else { return }
        try await post(path: "/v1/app-installs/heartbeat", payload: [
            "app": AppIdentity.displayName,
            "install_id": config.salesCaddieInstallID,
        ], config: config)
    }

    static func fetchIdentity(config: AppConfig) async throws -> SalesCaddieIdentityResponse {
        try await get(path: "/v1/me", config: config)
    }

    static func fetchWorkspaceMembers(config: AppConfig) async throws -> SalesCaddieMembersResponse {
        try await get(path: "/v1/admin/members", config: config)
    }

    static func upsertWorkspaceMember(_ member: SalesCaddieMemberUpsert, config: AppConfig) async throws {
        let data = try JSONEncoder().encode(member)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        try await post(path: "/v1/admin/members", payload: ["member": object], config: config)
    }

    static func createWorkspaceInvite(_ member: SalesCaddieMemberUpsert, config: AppConfig) async throws -> SalesCaddieInviteResponse {
        let data = try JSONEncoder().encode(member)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return try await post(path: "/v1/admin/invites", payload: ["member": object], config: config)
    }

    static func redeemInvite(token: String, apiURL: String) async throws -> SalesCaddieInviteRedeemResponse {
        let payload: [String: Any] = ["token": token]
        var request = try publicRequest(path: "/v1/invites/redeem", method: "POST", apiURL: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(data: data, response: response)
        return try JSONDecoder().decode(SalesCaddieInviteRedeemResponse.self, from: data)
    }

    static func syncSalesAgentHistoryItem(_ item: SalesAgentHistoryItem, config: AppConfig) async throws {
        guard config.salesCaddieCloudSyncEnabled, config.supabaseSyncJessicaHistory else { return }
        let payload: [String: Any] = [
            "events": [
                [
                    "id": item.id,
                    "provider": item.provider,
                    "status": item.status,
                    "transcript": item.transcript,
                    "response": item.response,
                    "planner_command": item.plannerCommand as Any,
                    "source_app": AppIdentity.displayName,
                    "client_created_at": ISO8601DateFormatter.supabase.string(from: item.createdAt),
                    "metadata": [
                        "local_schema_version": 1,
                        "sync_source": "sales_caddie_desktop",
                    ],
                ],
            ],
        ]
        try await post(path: "/v1/agent-events", payload: payload, config: config)
    }

    static func syncMeeting(_ meeting: MeetingRecord, config: AppConfig) async throws {
        guard config.salesCaddieCloudSyncEnabled, config.supabaseSyncTranscripts else { return }
        try await syncMeetings([meeting], config: config)
    }

    static func syncMeetings(_ meetings: [MeetingRecord], config: AppConfig) async throws {
        guard config.salesCaddieCloudSyncEnabled, config.supabaseSyncTranscripts else { return }
        let rows = meetings.map { meeting in
            [
                "local_id": String(meeting.id),
                "title": meeting.title,
                "source": meeting.source.rawValue,
                "transcript": meeting.rawTranscript,
                "summary": meeting.formattedNotes,
                "started_at": meeting.startTime,
                "duration_seconds": meeting.durationSeconds,
                "calendar_event_id": meeting.calendarEventID as Any,
                "metadata": [
                    "status": meeting.status.rawValue,
                    "word_count": meeting.wordCount,
                    "notes_state": meeting.notesState.rawValue,
                    "manual_notes": meeting.manualNotes,
                    "template_id": meeting.selectedTemplateID as Any,
                    "template_name": meeting.selectedTemplateName as Any,
                    "template_kind": meeting.selectedTemplateKind?.rawValue as Any,
                ],
            ] as [String: Any]
        }
        guard !rows.isEmpty else { return }
        try await post(path: "/v1/meetings/sync", payload: ["meetings": rows], config: config)
    }

    static func syncCallInsight(alert: SalesAssistAlert, localMeetingID: Int64?, config: AppConfig) async throws {
        guard config.salesCaddieCloudSyncEnabled else { return }
        let payload: [String: Any] = [
            "insights": [
                [
                    "kind": alert.kind,
                    "name": alert.objection,
                    "evidence": alert.quote,
                    "guidance": alert.talkTrack,
                    "local_meeting_id": localMeetingID.map(String.init) as Any,
                    "metadata": [
                        "priority": alert.priority,
                        "client_observed_at": ISO8601DateFormatter.supabase.string(from: alert.updatedAt),
                    ],
                ],
            ],
        ]
        try await post(path: "/v1/call-insights", payload: payload, config: config)
    }

    static func fetchSalesLibrarySnapshot(config: AppConfig) async throws -> SalesAssistLibrarySnapshot {
        guard config.salesCaddieCloudSyncEnabled, config.supabaseSyncSalesLibrary else {
            return SalesAssistLibrarySnapshot(knowledgeBase: "", objections: [], liveCues: [], updatedAt: nil)
        }
        let response: SalesLibraryResponse = try await get(path: "/v1/library-items", config: config)
        return SupabaseSalesLibraryItem.snapshot(from: response.items)
    }

    static func syncSalesLibrarySnapshot(config: AppConfig) async throws {
        guard config.salesCaddieCloudSyncEnabled, config.supabaseSyncSalesLibrary else { return }
        let records = try SupabaseSalesLibraryItem.records(from: config)
        let encoder = JSONEncoder()
        let data = try encoder.encode(records)
        let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        guard !items.isEmpty else { return }
        try await post(path: "/v1/library-items/sync", payload: ["items": items], config: config)
    }

    private static func get<T: Decodable>(path: String, config: AppConfig) async throws -> T {
        let request = try request(path: path, method: "GET", config: config)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(data: data, response: response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func post(path: String, payload: [String: Any], config: AppConfig) async throws {
        var request = try request(path: path, method: "POST", config: config)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonCleaned(payload), options: [])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(data: data, response: response)
    }

    private static func post<T: Decodable>(path: String, payload: [String: Any], config: AppConfig) async throws -> T {
        var request = try request(path: path, method: "POST", config: config)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonCleaned(payload), options: [])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(data: data, response: response)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func request(path: String, method: String, config: AppConfig) throws -> URLRequest {
        let baseURLString = try required(config.salesCaddieCloudAPIURL, field: "API URL")
        let token = try required(config.salesCaddieCloudAPIToken, field: "API token")
        guard let baseURL = URL(string: baseURLString) else {
            throw SalesCaddieCloudAPIError.invalidURL(baseURLString)
        }
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(workspaceSlug(config), forHTTPHeaderField: "x-sales-caddie-workspace")
        request.setValue(userEmail(config), forHTTPHeaderField: "x-sales-caddie-user-email")
        request.setValue(userName(config), forHTTPHeaderField: "x-sales-caddie-user-name")
        request.setValue(config.salesCaddieInstallID, forHTTPHeaderField: "x-sales-caddie-install-key")
        return request
    }

    private static func publicRequest(path: String, method: String, apiURL: String) throws -> URLRequest {
        let baseURLString = try required(apiURL, field: "API URL")
        guard let baseURL = URL(string: baseURLString) else {
            throw SalesCaddieCloudAPIError.invalidURL(baseURLString)
        }
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validate(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SalesCaddieCloudAPIError.requestFailed(httpResponse.statusCode, body)
        }
    }

    private static func required(_ value: String, field: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SalesCaddieCloudAPIError.missingConfiguration(field)
        }
        return trimmed
    }

    private static func workspaceSlug(_ config: AppConfig) -> String {
        let cloud = config.salesCaddieCloudWorkspaceSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cloud.isEmpty { return cloud }
        let supabase = config.supabaseWorkspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return supabase.isEmpty ? "default" : supabase
    }

    private static func userEmail(_ config: AppConfig) -> String {
        let cloudUser = config.supabaseUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        if cloudUser.contains("@") { return cloudUser }
        let userName = config.userName.trimmingCharacters(in: .whitespacesAndNewlines)
        if userName.contains("@") { return userName }
        let fallback = cloudUser.isEmpty ? userName : cloudUser
        return fallback.isEmpty ? "unknown@sales-caddie.local" : "\(fallback)@sales-caddie.local"
    }

    private static func userName(_ config: AppConfig) -> String {
        let name = config.salesAgentUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return config.userName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func jsonCleaned(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { result, pair in
                let cleaned = jsonCleaned(pair.value)
                if !(cleaned is NSNull) {
                    result[pair.key] = cleaned
                }
            }
        case let array as [Any]:
            return array.map(jsonCleaned).filter { !($0 is NSNull) }
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                guard let child = mirror.children.first else { return NSNull() }
                return jsonCleaned(child.value)
            }
            return value
        }
    }
}

struct SalesCaddieIdentityResponse: Decodable {
    let ok: Bool
    let workspace: SalesCaddieWorkspace
    let member: SalesCaddieWorkspaceMember
    let permissions: SalesCaddiePermissions
}

struct SalesCaddieMembersResponse: Decodable {
    let ok: Bool
    let members: [SalesCaddieWorkspaceMember]
}

struct SalesCaddieInviteResponse: Decodable {
    let ok: Bool
    let member: SalesCaddieWorkspaceMember
    let inviteURL: String
    let downloadURL: String
    let email: SalesCaddieInviteEmail
    let emailDelivery: SalesCaddieInviteEmailDelivery?

    enum CodingKeys: String, CodingKey {
        case ok
        case member
        case inviteURL = "invite_url"
        case downloadURL = "download_url"
        case email
        case emailDelivery = "email_delivery"
    }
}

struct SalesCaddieInviteEmailDelivery: Codable {
    let sent: Bool?
    let provider: String?
    let status: Int?
    let reason: String?
    let error: String?
}

struct SalesCaddieInviteEmail: Codable {
    let to: String
    let subject: String
    let body: String
    let mailtoURL: String

    enum CodingKeys: String, CodingKey {
        case to
        case subject
        case body
        case mailtoURL = "mailto_url"
    }
}

struct SalesCaddieInviteRedeemResponse: Decodable {
    let ok: Bool
    let workspace: SalesCaddieWorkspace
    let member: SalesCaddieWorkspaceMember
    let config: SalesCaddieInviteConfig
}

struct SalesCaddieInviteConfig: Decodable {
    let salesCaddieCloudSyncEnabled: Bool
    let salesCaddieCloudAPIURL: String
    let salesCaddieCloudAPIToken: String
    let salesCaddieCloudWorkspaceSlug: String
    let supabaseUserID: String
    let userName: String

    enum CodingKeys: String, CodingKey {
        case salesCaddieCloudSyncEnabled = "sales_caddie_cloud_sync_enabled"
        case salesCaddieCloudAPIURL = "sales_caddie_cloud_api_url"
        case salesCaddieCloudAPIToken = "sales_caddie_cloud_api_token"
        case salesCaddieCloudWorkspaceSlug = "sales_caddie_cloud_workspace_slug"
        case supabaseUserID = "supabase_user_id"
        case userName = "user_name"
    }
}

struct SalesCaddieWorkspace: Decodable {
    let id: String
    let slug: String
    let name: String
}

struct SalesCaddieWorkspaceMember: Decodable, Identifiable {
    let id: String
    let email: String
    let displayName: String?
    let role: String
    let managerMemberID: String?
    let isActive: Bool
    let crmUserID: String?
    let ghlUserID: String?
    let calendarEmail: String?
    let permissions: SalesCaddiePermissions?
    let metadata: SalesCaddieMemberMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case role
        case managerMemberID = "manager_member_id"
        case isActive = "is_active"
        case crmUserID = "crm_user_id"
        case ghlUserID = "ghl_user_id"
        case calendarEmail = "calendar_email"
        case permissions
        case metadata
    }
}

struct SalesCaddieMemberMetadata: Codable {
    let invite: SalesCaddieMemberInviteMetadata?
}

struct SalesCaddieMemberInviteMetadata: Codable {
    let status: String?
    let invitedAt: String?
    let acceptedAt: String?
    let expiresAt: String?
    let invitedByEmail: String?

    enum CodingKeys: String, CodingKey {
        case status
        case invitedAt = "invited_at"
        case acceptedAt = "accepted_at"
        case expiresAt = "expires_at"
        case invitedByEmail = "invited_by_email"
    }
}

struct SalesCaddiePermissions: Codable {
    var canAdminWorkspace: Bool?
    var canManageMembers: Bool?
    var canManageLibrary: Bool?
    var canViewTeamCalls: Bool?
    var canUseSalesAgent: Bool?
    var canSyncMeetings: Bool?
    var canRecordMeetings: Bool?
    var canUseAIAssist: Bool?
    var canUseComputerControl: Bool?
    var canManagePrivateNotes: Bool?

    init(
        canAdminWorkspace: Bool? = nil,
        canManageMembers: Bool? = nil,
        canManageLibrary: Bool? = nil,
        canViewTeamCalls: Bool? = nil,
        canUseSalesAgent: Bool? = nil,
        canSyncMeetings: Bool? = nil,
        canRecordMeetings: Bool? = nil,
        canUseAIAssist: Bool? = nil,
        canUseComputerControl: Bool? = nil,
        canManagePrivateNotes: Bool? = nil
    ) {
        self.canAdminWorkspace = canAdminWorkspace
        self.canManageMembers = canManageMembers
        self.canManageLibrary = canManageLibrary
        self.canViewTeamCalls = canViewTeamCalls
        self.canUseSalesAgent = canUseSalesAgent
        self.canSyncMeetings = canSyncMeetings
        self.canRecordMeetings = canRecordMeetings
        self.canUseAIAssist = canUseAIAssist
        self.canUseComputerControl = canUseComputerControl
        self.canManagePrivateNotes = canManagePrivateNotes
    }

    enum CodingKeys: String, CodingKey {
        case canAdminWorkspace = "can_admin_workspace"
        case canManageMembers = "can_manage_members"
        case canManageLibrary = "can_manage_library"
        case canViewTeamCalls = "can_view_team_calls"
        case canUseSalesAgent = "can_use_sales_agent"
        case canSyncMeetings = "can_sync_meetings"
        case canRecordMeetings = "can_record_meetings"
        case canUseAIAssist = "can_use_ai_assist"
        case canUseComputerControl = "can_use_computer_control"
        case canManagePrivateNotes = "can_manage_private_notes"
    }
}

struct SalesCaddieMemberUpsert: Encodable {
    var email: String
    var displayName: String
    var role: String
    var isActive: Bool
    var crmUserID: String
    var ghlUserID: String
    var calendarEmail: String
    var permissions: SalesCaddiePermissions

    enum CodingKeys: String, CodingKey {
        case email
        case displayName = "display_name"
        case role
        case isActive = "is_active"
        case crmUserID = "crm_user_id"
        case ghlUserID = "ghl_user_id"
        case calendarEmail = "calendar_email"
        case permissions
    }
}

private struct SalesLibraryResponse: Decodable {
    let ok: Bool
    let items: [SupabaseSalesLibraryItem]
}
