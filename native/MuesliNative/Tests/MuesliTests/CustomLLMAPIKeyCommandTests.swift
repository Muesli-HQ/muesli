import Darwin
import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("CustomLLMAPIKeyResolution")
struct CustomLLMAPIKeyResolutionTests {
    @Test("empty command returns the trimmed static key")
    func emptyCommandReturnsStaticKey() async throws {
        let result = try await CredentialCommandRunner.resolve(
            command: "",
            fallback: "  sk-static-key  "
        )
        #expect(result == "sk-static-key")
    }

    @Test("command output is trimmed and takes precedence")
    func commandOutputTakesPrecedence() async throws {
        let result = try await CredentialCommandRunner.resolve(
            command: "printf '  sk-dynamic-token  '",
            fallback: "sk-static-key"
        )
        #expect(result == "sk-dynamic-token")
    }

    @Test("failed or empty commands fall back to the static key", arguments: ["exit 1", "printf ''"])
    func unusableCommandFallsBack(command: String) async throws {
        let result = try await CredentialCommandRunner.resolve(
            command: command,
            fallback: "sk-static-key"
        )
        #expect(result == "sk-static-key")
    }

    @Test("oversized output falls back instead of returning a truncated credential")
    func oversizedOutputFallsBack() async throws {
        let result = try await CredentialCommandRunner.resolve(
            command: "yes x | head -c 9000",
            fallback: "sk-static-key"
        )
        #expect(result == "sk-static-key")
    }

    @Test("final stdout written immediately before exit is drained")
    func finalOutputIsDrained() async throws {
        let result = try await CredentialCommandRunner.resolve(
            command: "printf sk-final-token",
            fallback: "sk-static-key"
        )
        #expect(result == "sk-final-token")
    }

    @Test("timeout falls back promptly and terminates shell descendants")
    func timeoutTerminatesShellDescendants() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-credential-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let startedAt = Date()
        let result = try await CredentialCommandRunner.resolve(
            command: "sleep 30 & child=$!; printf \"$child\" > '\(pidFile.path)'; wait",
            fallback: "sk-static-key",
            timeout: 0.2
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let childPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))

        #expect(result == "sk-static-key")
        #expect(elapsed < 2)
        #expect(await processDisappears(childPID, within: 2))
    }

    @Test("task cancellation terminates the command tree")
    func cancellationTerminatesCommandTree() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-credential-cancel-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let task = Task {
            try await CredentialCommandRunner.resolve(
                command: "sleep 30 & child=$!; printf \"$child\" > '\(pidFile.path)'; wait",
                fallback: "sk-static-key",
                timeout: 30
            )
        }

        let childPID = try await waitForPID(in: pidFile)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await processDisappears(childPID, within: 2))
    }

    @Test("app resolver uses the configured command")
    func appResolverUsesConfiguredCommand() async throws {
        var config = AppConfig()
        config.customLLMAPIKey = "sk-static-key"
        config.customLLMAPIKeyCommand = "printf sk-app-token"

        let result = try await MeetingSummaryClient.resolveCustomLLMAPIKey(config: config)
        #expect(result == "sk-app-token")
    }

    @Test("Anthropic readiness accepts a command as credential")
    func anthropicReadinessAcceptsCommand() {
        var config = AppConfig()
        config.customLLMFormat = CustomLLMFormat.anthropic.rawValue
        config.customLLMModel = "claude-3-5-sonnet-20241022"
        config.customLLMAPIKeyCommand = "printf sk-token"

        #expect(MeetingSummaryClient.customLLMHasRequiredSettings(config: config))
    }

    @Test("Anthropic readiness rejects empty credentials")
    func anthropicReadinessRejectsEmptyCredentials() {
        var config = AppConfig()
        config.customLLMFormat = CustomLLMFormat.anthropic.rawValue
        config.customLLMModel = "claude-3-5-sonnet-20241022"

        #expect(!MeetingSummaryClient.customLLMHasRequiredSettings(config: config))
    }

    private func waitForPID(in file: URL) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let processIdentifier = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return processIdentifier
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func processDisappears(_ processIdentifier: pid_t, within timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(processIdentifier, 0) == -1, errno == ESRCH {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return kill(processIdentifier, 0) == -1 && errno == ESRCH
    }
}
