import Foundation

struct SalesAgentCommandSpeaker: Codable, Equatable {
    let userID: String
    let name: String
    let role: String
    let repKey: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case name
        case role
        case repKey = "rep_key"
    }
}

struct SalesAgentCommandHistoryMessage: Codable, Equatable {
    let role: String
    let content: String
}

struct SalesAgentCommandRequest: Codable {
    let type: String
    let transcript: String
    let appName: String
    let generatedAt: String
    let speaker: SalesAgentCommandSpeaker?
    let conversationHistory: [SalesAgentCommandHistoryMessage]
    let allowComputerActions: Bool
    let sendScreenContext: Bool
    let knowledgeBase: String?
    let objections: [SalesAssistObjection]?
    let liveCues: [SalesAssistLiveCue]?

    enum CodingKeys: String, CodingKey {
        case type
        case transcript
        case appName = "app_name"
        case generatedAt = "generated_at"
        case speaker
        case conversationHistory = "conversation_history"
        case allowComputerActions = "allow_computer_actions"
        case sendScreenContext = "send_screen_context"
        case knowledgeBase = "knowledge_base"
        case objections
        case liveCues = "live_cues"
    }
}

struct SalesAgentCommandResponse: Codable, Equatable {
    let displayMessage: String?
    let plannerCommand: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case displayMessage = "display_message"
        case plannerCommand = "planner_command"
        case error
    }
}

enum SalesAgentProviderResult: Equatable {
    case runLocalPlanner(command: String)
    case display(message: String)
}

enum SalesAgentProviderError: LocalizedError, Equatable {
    case missingEndpoint
    case missingAPIKey(String)
    case invalidEndpoint(String)
    case requestFailed(String)
    case backendFailed(statusCode: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "Sales agent endpoint is not configured."
        case .missingAPIKey(let provider):
            return "\(provider) API key is not configured."
        case .invalidEndpoint(let value):
            return "Invalid sales agent endpoint: \(value)"
        case .requestFailed(let message):
            return "Sales agent request failed. \(message)"
        case .backendFailed(let statusCode, let message):
            return "Sales agent failed with status \(statusCode). \(message)"
        case .emptyResponse:
            return "Sales agent returned an empty response."
        }
    }
}

enum SalesAgentProvider {
    static func handleVoiceCommand(transcript: String, config: AppConfig) async throws -> SalesAgentProviderResult {
        let backend = SalesAgentBackendOption.resolved(config.salesAgentBackend)
        switch backend.backend {
        case SalesAgentBackendOption.hostedJessica.backend:
            return try await callWebhook(
                endpointOverride: config.salesAgentEndpointURL,
                defaultEndpoint: "https://loving-charisma-production.up.railway.app/api/v1/agent/command",
                transcript: transcript,
                config: config
            )
        case SalesAgentBackendOption.customWebhook.backend:
            return try await callWebhook(
                endpointOverride: config.salesAgentEndpointURL,
                defaultEndpoint: nil,
                transcript: transcript,
                config: config
            )
        case SalesAgentBackendOption.openAI.backend:
            let message = try await callOpenAICompatible(
                url: URL(string: "https://api.openai.com/v1/chat/completions")!,
                apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? config.openAIAPIKey,
                missingKeyProvider: "OpenAI",
                model: config.salesAgentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (config.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-5.4-mini" : config.openAIModel)
                    : config.salesAgentModel,
                transcript: transcript,
                config: config,
                extraHeaders: [:]
            )
            return .display(message: message)
        case SalesAgentBackendOption.openRouter.backend:
            let model = config.salesAgentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (config.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "stepfun/step-3.5-flash:free" : config.openRouterModel)
                : config.salesAgentModel
            let message = try await callOpenAICompatible(
                url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                apiKey: ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? config.openRouterAPIKey,
                missingKeyProvider: "OpenRouter",
                model: model,
                transcript: transcript,
                config: config,
                extraHeaders: ["X-OpenRouter-Title": AppIdentity.displayName]
            )
            return .display(message: message)
        case SalesAgentBackendOption.ollama.backend:
            let message = try await callOllama(transcript: transcript, config: config)
            return .display(message: message)
        default:
            return try await callWebhook(
                endpointOverride: "",
                defaultEndpoint: "https://loving-charisma-production.up.railway.app/api/v1/agent/command",
                transcript: transcript,
                config: config
            )
        }
    }

    static func jessicaPlannerCommand(from transcript: String) -> String {
        """
        You are Jessica inside Sales Caddie, Mike's sales operations assistant for Skriber. Interpret this spoken request using Sales Caddie, Skriber sales context, call coaching, objection handling, rep dashboards, meetings, and local app/computer tools when useful. Complete the request directly when it is safe. If the request needs missing information or permission, stop and explain what is needed.

        Spoken request: \(transcript)
        """
    }

    private static func callWebhook(
        endpointOverride: String,
        defaultEndpoint: String?,
        transcript: String,
        config: AppConfig
    ) async throws -> SalesAgentProviderResult {
        let endpoint = endpointOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointString = endpoint.isEmpty ? (defaultEndpoint ?? "") : endpoint
        guard !endpointString.isEmpty else { throw SalesAgentProviderError.missingEndpoint }
        guard let url = URL(string: endpointString) else {
            throw SalesAgentProviderError.invalidEndpoint(endpointString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = config.salesAgentAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(commandRequest(transcript: transcript, config: config))

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw SalesAgentProviderError.backendFailed(
                statusCode: statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }

        let decoded = try JSONDecoder().decode(SalesAgentCommandResponse.self, from: data)
        if let error = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            throw SalesAgentProviderError.requestFailed(error)
        }
        if let message = decoded.displayMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return .display(message: message)
        }
        if let plannerCommand = decoded.plannerCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plannerCommand.isEmpty {
            return .display(message: "Jessica returned a computer-control action, but the Jessica shortcut is answer-only. Use the Computer Use shortcut for desktop actions.")
        }
        throw SalesAgentProviderError.emptyResponse
    }

    private static func callOpenAICompatible(
        url: URL,
        apiKey: String,
        missingKeyProvider: String,
        model: String,
        transcript: String,
        config: AppConfig,
        extraHeaders: [String: String]
    ) async throws -> String {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw SalesAgentProviderError.missingAPIKey(missingKeyProvider)
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": textAgentInstructions(config: config)],
                ["role": "user", "content": transcript],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw SalesAgentProviderError.backendFailed(
                statusCode: statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = extractText(from: json)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            throw SalesAgentProviderError.emptyResponse
        }
        return message
    }

    private static func callOllama(transcript: String, config: AppConfig) async throws -> String {
        let base = config.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: base), let url = URL(string: "/api/chat", relativeTo: baseURL) else {
            throw SalesAgentProviderError.invalidEndpoint(base)
        }
        let model = config.salesAgentModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? config.ollamaModel
            : config.salesAgentModel
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": textAgentInstructions(config: config)],
                ["role": "user", "content": transcript],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw SalesAgentProviderError.backendFailed(
                statusCode: statusCode,
                message: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageObject = json["message"] as? [String: Any],
              let content = messageObject["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SalesAgentProviderError.emptyResponse
        }
        return content
    }

    static func commandRequest(transcript: String, config: AppConfig) -> SalesAgentCommandRequest {
        SalesAgentCommandRequest(
            type: "voice_command",
            transcript: transcript,
            appName: AppIdentity.displayName,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            speaker: speaker(from: config),
            conversationHistory: conversationHistory(from: config),
            allowComputerActions: false,
            sendScreenContext: false,
            knowledgeBase: config.salesAgentSendKnowledgeBase ? config.salesAssistKnowledgeBase : nil,
            objections: config.salesAgentSendKnowledgeBase ? config.salesAssistObjections : nil,
            liveCues: config.salesAgentSendKnowledgeBase ? config.salesAssistLiveCues : nil
        )
    }

    private static func conversationHistory(from config: AppConfig) -> [SalesAgentCommandHistoryMessage] {
        config.salesAgentHistory
            .prefix(6)
            .reversed()
            .flatMap { item -> [SalesAgentCommandHistoryMessage] in
                let transcript = item.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                let response = item.response.trimmingCharacters(in: .whitespacesAndNewlines)
                var messages: [SalesAgentCommandHistoryMessage] = []
                if !transcript.isEmpty {
                    messages.append(SalesAgentCommandHistoryMessage(
                        role: "user",
                        content: String(transcript.prefix(2000))
                    ))
                }
                if !response.isEmpty {
                    messages.append(SalesAgentCommandHistoryMessage(
                        role: "assistant",
                        content: String(response.prefix(3000))
                    ))
                }
                return messages
            }
    }

    private static func speaker(from config: AppConfig) -> SalesAgentCommandSpeaker? {
        let option = SalesAgentUserOption.resolved(
            userID: config.salesAgentUserID,
            repKey: config.salesAgentRepKey
        )
        let userID = (option?.id ?? config.salesAgentUserID).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (option?.name ?? config.salesAgentUserName).trimmingCharacters(in: .whitespacesAndNewlines)
        let role = (option?.role ?? config.salesAgentUserRole).trimmingCharacters(in: .whitespacesAndNewlines)
        let repKey = (option?.repKey ?? config.salesAgentRepKey).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty || !name.isEmpty || !role.isEmpty || !repKey.isEmpty else { return nil }
        return SalesAgentCommandSpeaker(
            userID: userID,
            name: name,
            role: role,
            repKey: repKey
        )
    }

    private static func textAgentInstructions(config: AppConfig) -> String {
        var parts = [
            "You are Jessica inside Sales Caddie, a concise sales assistant for reps. Answer the spoken request directly. Do not claim you completed local computer actions unless you actually can through a tool.",
        ]
        if let speaker = speaker(from: config) {
            parts.append("""
            Speaker:
            - name: \(speaker.name)
            - role: \(speaker.role)
            - rep key: \(speaker.repKey)
            Interpret "my" or "me" as this speaker when the request is about rep-specific sales activity.
            """)
        }
        if config.salesAgentSendKnowledgeBase {
            let kb = config.salesAssistKnowledgeBase.trimmingCharacters(in: .whitespacesAndNewlines)
            if !kb.isEmpty {
                parts.append("Knowledge base:\n\(kb)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func extractText(from payload: [String: Any]) -> String? {
        if let choices = payload["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        if let output = payload["output"] as? [[String: Any]] {
            var parts: [String] = []
            for item in output {
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    if let text = part["text"] as? String {
                        parts.append(text)
                    }
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }
}
