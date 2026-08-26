import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("ChatGPT Responses transport")
struct ChatGPTResponsesTransportTests {
    @Test("builds Codex Responses requests with honest Muesli identity")
    func buildsCodexRequest() throws {
        let sessionID = UUID(uuidString: "8AF070D8-956D-4706-9FF8-8140CE7F6B2D")!
        let request = try ChatGPTResponsesTransport.makeRequest(
            body: ["model": "gpt-5.6-sol", "stream": true],
            token: "access-token",
            accountId: "account-123",
            appVersion: "1.2.3",
            sessionID: sessionID,
            environment: [:]
        )

        #expect(request.url == URL(string: "https://chatgpt.com/backend-api/codex/responses"))
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 120)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
        #expect(request.value(forHTTPHeaderField: "originator") == "muesli")
        #expect(request.value(forHTTPHeaderField: "version") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Muesli/1.2.3")
        #expect(request.value(forHTTPHeaderField: "session_id") == sessionID.uuidString.lowercased())
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)

        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-5.6-sol")
        #expect(json["stream"] as? Bool == true)
    }

    @Test("omits empty account IDs without dropping Codex identity headers")
    func omitsEmptyAccountID() throws {
        let request = try ChatGPTResponsesTransport.makeRequest(
            body: ["stream": true],
            token: "access-token",
            accountId: "",
            appVersion: "2.0.0",
            sessionID: UUID(uuidString: "194AC4DC-E234-4153-BA13-A1D48323303F")!,
            environment: [:]
        )

        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
        #expect(request.value(forHTTPHeaderField: "originator") == "muesli")
        #expect(request.value(forHTTPHeaderField: "version") == nil)
    }

    @Test("creates a fresh session ID for every request")
    func createsFreshSessionIDs() throws {
        let first = try ChatGPTResponsesTransport.makeRequest(
            body: ["stream": true],
            token: "access-token",
            accountId: "account-123",
            appVersion: "1.0.0",
            environment: [:]
        )
        let second = try ChatGPTResponsesTransport.makeRequest(
            body: ["stream": true],
            token: "access-token",
            accountId: "account-123",
            appVersion: "1.0.0",
            environment: [:]
        )

        let firstSessionID = try #require(first.value(forHTTPHeaderField: "session_id"))
        let secondSessionID = try #require(second.value(forHTTPHeaderField: "session_id"))
        #expect(UUID(uuidString: firstSessionID) != nil)
        #expect(UUID(uuidString: secondSessionID) != nil)
        #expect(firstSessionID != secondSessionID)
    }

    @Test("uses Codex by default and only selects WHAM for the explicit override")
    func selectsBackendFromEnvironment() {
        #expect(ChatGPTResponsesTransport.selectedBackend(environment: [:]) == .codex)
        #expect(ChatGPTResponsesTransport.selectedBackend(environment: [
            ChatGPTResponsesTransport.environmentKey: "codex",
        ]) == .codex)
        #expect(ChatGPTResponsesTransport.selectedBackend(environment: [
            ChatGPTResponsesTransport.environmentKey: "unknown",
        ]) == .codex)
        #expect(ChatGPTResponsesTransport.selectedBackend(environment: [
            ChatGPTResponsesTransport.environmentKey: " WHAM ",
        ]) == .wham)
    }

    @Test("builds the legacy WHAM request only for the emergency override")
    func buildsWhamOverrideRequest() throws {
        let request = try ChatGPTResponsesTransport.makeRequest(
            body: ["model": "gpt-5.4", "stream": true],
            token: "access-token",
            accountId: "account-123",
            appVersion: "1.2.3",
            sessionID: UUID(uuidString: "6482D44E-BE26-4B98-B0B7-B5D5281C713B")!,
            environment: [ChatGPTResponsesTransport.environmentKey: "wham"]
        )

        #expect(request.url == URL(string: "https://chatgpt.com/backend-api/wham/responses"))
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-123")
        #expect(request.value(forHTTPHeaderField: "originator") == nil)
        #expect(request.value(forHTTPHeaderField: "version") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == nil)
        #expect(request.value(forHTTPHeaderField: "session_id") == nil)
    }
}
