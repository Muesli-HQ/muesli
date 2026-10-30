import Foundation

public enum AnthropicAPIRequest {
    public static func make(
        url: URL,
        apiKey: String,
        workspaceID: String = "",
        body: [String: Any],
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
        }
        let trimmedWorkspaceID = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWorkspaceID.isEmpty {
            request.setValue(trimmedWorkspaceID, forHTTPHeaderField: "anthropic-workspace-id")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
