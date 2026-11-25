import Testing
import Foundation
import Network
@testable import MuesliNativeApp

/// A loopback listener that counts connections and drops them. A test asserts on
/// the count to prove that no bytes were ever sent toward a backend.
private final class ConnectionCounter: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    var connections: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            self?.lock.lock()
            self?.count += 1
            self?.lock.unlock()
            connection.start(queue: .global())
            connection.cancel()
        }
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed, let self else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: self.listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    func stop() { listener.cancel() }
}

@Suite("Private meeting policy", .serialized)
struct PrivateMeetingPolicyTests {

    private func config(backend: String, trusted: [String] = [], port: UInt16 = 1) -> AppConfig {
        var config = AppConfig()
        config.meetingSummaryBackend = backend
        config.privateTrustedBackends = trusted
        config.customLLMURL = "http://127.0.0.1:\(port)/v1"
        config.customLLMModel = "test-model"
        config.customLLMFormat = "openai"
        config.meetingSummaryRetryCount = 0
        return config
    }

    // MARK: - Resolution (F10)

    @Test("backend resolution matches the summary client")
    func effectiveBackend() {
        #expect(PrivateMeetingPolicy.effectiveBackend(of: config(backend: "")) == "chatgpt")
        #expect(PrivateMeetingPolicy.effectiveBackend(of: config(backend: "OLLAMA")) == "ollama")
        #expect(PrivateMeetingPolicy.effectiveBackend(of: config(backend: "custom_llm")) == "custom_llm")
        // Unknown strings fall through to OpenAI in MeetingSummaryClient, so the policy must too.
        #expect(PrivateMeetingPolicy.effectiveBackend(of: config(backend: "bogus")) == "openai")
    }

    @Test("a private meeting is blocked unless the effective backend is trusted")
    func trustDecision() {
        #expect(PrivateMeetingPolicy.allowsBackend(config(backend: "custom_llm")) == false)
        #expect(PrivateMeetingPolicy.allowsBackend(config(backend: "custom_llm", trusted: ["custom_llm"])))
        #expect(PrivateMeetingPolicy.allowsBackend(config(backend: "custom_llm", trusted: ["ollama"])) == false)
        #expect(PrivateMeetingPolicy.allowsBackend(config(backend: "custom_llm", trusted: [" Custom_LLM "])))
    }

    @Test("an unknown backend string is trusted only if OpenAI is trusted")
    func unknownBackendUsesOpenAITrust() {
        #expect(PrivateMeetingPolicy.allowsBackend(config(backend: "bogus", trusted: ["bogus"])) == false)
        #expect(PrivateMeetingPolicy.allowsBackend(config(backend: "bogus", trusted: ["openai"])))
    }

    @Test("an empty backend is trusted only if ChatGPT is trusted")
    func emptyBackendUsesChatGPTTrust() {
        #expect(PrivateMeetingPolicy.allowsBackend(config(backend: "")) == false)
        #expect(PrivateMeetingPolicy.allowsBackend(config(backend: "", trusted: ["chatgpt"])))
    }

    // MARK: - Trust list editing

    @Test("trusting a backend adds its normalized id once")
    func trustAddsOnce() {
        var list: [String] = []
        list = PrivateMeetingPolicy.updatedTrust(list, backend: "Custom_LLM", trusted: true)
        list = PrivateMeetingPolicy.updatedTrust(list, backend: "custom_llm", trusted: true)
        #expect(list == ["custom_llm"])
        #expect(PrivateMeetingPolicy.isTrusted("custom_llm", in: list))
    }

    @Test("untrusting removes every spelling of the backend and keeps the others")
    func untrustRemoves() {
        let list = PrivateMeetingPolicy.updatedTrust([" Custom_LLM ", "ollama", "custom_llm"], backend: "custom_llm", trusted: false)
        #expect(list == ["ollama"])
        #expect(PrivateMeetingPolicy.isTrusted("custom_llm", in: list) == false)
    }

    @Test("trust in one backend never implies trust in another")
    func trustIsPerBackend() {
        let list = PrivateMeetingPolicy.updatedTrust([], backend: "ollama", trusted: true)
        #expect(PrivateMeetingPolicy.isTrusted("lmstudio", in: list) == false)
        #expect(PrivateMeetingPolicy.isTrusted("custom_llm", in: list) == false)
    }

    // MARK: - Config (F3)

    @Test("config without the trusted-backend key decodes to an empty list")
    func configDefaultsToNoTrust() throws {
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(decoded.privateTrustedBackends.isEmpty)
    }

    @Test("trusted backends round-trip through config JSON with a snake_case key")
    func configRoundTrip() throws {
        var original = AppConfig()
        original.privateTrustedBackends = ["custom_llm", "ollama"]
        let data = try JSONEncoder().encode(original)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["private_trusted_backends"] as? [String] == ["custom_llm", "ollama"])
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.privateTrustedBackends == ["custom_llm", "ollama"])
    }

    @Test("a malformed trusted-backend value falls back to no trust")
    func malformedTrustFailsClosed() throws {
        let decoded = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"private_trusted_backends": "custom_llm"}"#.utf8)
        )
        #expect(decoded.privateTrustedBackends.isEmpty)
    }

    // MARK: - Summary gate (F4, F5)

    @Test("summarize refuses a private meeting on an untrusted backend and sends nothing")
    func summarizeBlocksUntrusted() async throws {
        let server = try ConnectionCounter()
        let port = try await server.start()
        defer { server.stop() }

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Privileged discussion",
                meetingTitle: "Counsel call",
                config: config(backend: "custom_llm", port: port),
                isPrivateMeeting: true
            )
            #expect(Bool(false), "Expected the private meeting to be blocked")
        } catch let error as MeetingSummaryError {
            guard case .privateMeetingBlocked = error else {
                #expect(Bool(false), "Expected privateMeetingBlocked, got \(error)")
                return
            }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(server.connections == 0)
    }

    @Test("summarize lets a private meeting reach a trusted backend")
    func summarizeAllowsTrusted() async throws {
        let server = try ConnectionCounter()
        let port = try await server.start()
        defer { server.stop() }

        _ = try? await MeetingSummaryClient.summarize(
            transcript: "Privileged discussion",
            meetingTitle: "Counsel call",
            config: config(backend: "custom_llm", trusted: ["custom_llm"], port: port),
            isPrivateMeeting: true
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(server.connections >= 1)
    }

    @Test("summarize is unchanged for a normal meeting on an untrusted backend")
    func summarizeNormalMeetingUnaffected() async throws {
        let server = try ConnectionCounter()
        let port = try await server.start()
        defer { server.stop() }

        _ = try? await MeetingSummaryClient.summarize(
            transcript: "Standup",
            meetingTitle: "Standup",
            config: config(backend: "custom_llm", port: port),
            isPrivateMeeting: false
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(server.connections >= 1)
    }

    @Test("an unknown backend string cannot be used to reach OpenAI with a private meeting")
    func unknownBackendBlockedBeforeNetwork() async {
        var cfg = config(backend: "bogus")
        cfg.openAIAPIKey = "sk-test"
        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Privileged discussion",
                meetingTitle: "Counsel call",
                config: cfg,
                isPrivateMeeting: true
            )
            #expect(Bool(false), "Expected the private meeting to be blocked")
        } catch let error as MeetingSummaryError {
            if case .privateMeetingBlocked = error { return }
            #expect(Bool(false), "Expected privateMeetingBlocked, got \(error)")
        } catch {
            #expect(Bool(false), "Expected MeetingSummaryError, got \(error)")
        }
    }

    // MARK: - Title gate (F11)

    @Test("title generation sends nothing for a private meeting on an untrusted backend")
    func titleBlocksUntrusted() async throws {
        let server = try ConnectionCounter()
        let port = try await server.start()
        defer { server.stop() }

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Privileged discussion",
            manualNotes: nil,
            config: config(backend: "custom_llm", port: port),
            isPrivateMeeting: true
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(title == nil)
        #expect(server.connections == 0)
    }

    @Test("title generation reaches a trusted backend for a private meeting")
    func titleAllowsTrusted() async throws {
        let server = try ConnectionCounter()
        let port = try await server.start()
        defer { server.stop() }

        _ = await MeetingSummaryClient.generateTitle(
            transcript: "Privileged discussion",
            manualNotes: nil,
            config: config(backend: "custom_llm", trusted: ["custom_llm"], port: port),
            isPrivateMeeting: true
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(server.connections >= 1)
    }

    @Test("title generation is unchanged for a normal meeting")
    func titleNormalMeetingUnaffected() async throws {
        let server = try ConnectionCounter()
        let port = try await server.start()
        defer { server.stop() }

        _ = await MeetingSummaryClient.generateTitle(
            transcript: "Standup",
            manualNotes: nil,
            config: config(backend: "custom_llm", port: port),
            isPrivateMeeting: false
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(server.connections >= 1)
    }
}
