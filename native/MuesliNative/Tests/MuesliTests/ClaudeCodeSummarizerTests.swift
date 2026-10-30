import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp
@testable import MuesliCLI

@Suite("Claude Code summarizer")
struct ClaudeCodeSummarizerTests {
    @Test("Claude Code sign-in quotes unusual executable paths for Terminal")
    func signInCommandQuoting() throws {
        let path = "/tmp/Claude Code's `test` $HOME; echo unsafe"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' \(ClaudeCodeSignInLauncher.shellQuoted(path))"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == path)
    }

    @Test("runs a configured executable with the prompt on stdin and parses normal or verbose JSON", arguments: [false, true])
    func configuredExecutable(verbose: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-claude-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake claude")
        let result = ###"{"type":"result","is_error":false,"result":"## Summary\n- Ship"}"###
        let response = verbose ? #"[{"type":"system"},{"type":"assistant","message":{"content":"partial response"}},"# + result + "]" : result
        let script = """
        #!/bin/sh
        input=$(cat)
        case "$input" in
          *"Decision: ship"*) ;;
          *) exit 3 ;;
        esac
        printf '%s' '\(response)'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let summary = try await ClaudeCodeSummarizer.run(
            instructions: "Summarize this meeting.",
            input: "Decision: ship",
            model: "sonnet",
            executablePath: executable.path,
            timeout: 5
        )
        #expect(summary == "## Summary\n- Ship")
    }

    @Test("missing explicitly configured executable gives a useful error")
    func missingExecutable() async {
        do {
            _ = try await ClaudeCodeSummarizer.run(
                instructions: "Summarize",
                input: "Transcript",
                executablePath: "/missing/muesli-test-claude"
            )
            Issue.record("Expected missing executable failure")
        } catch {
            #expect(error.localizedDescription.contains("Claude Code could not be found"))
        }
    }

    @Test("an executable that cannot launch reports a process startup error")
    func failedLaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-claude-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        try "#!/missing/muesli-test-interpreter\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do {
            _ = try await ClaudeCodeSummarizer.run(instructions: "Summarize", input: "Transcript", executablePath: executable.path)
            Issue.record("Expected launch failure")
        } catch let error as ClaudeCodeSummaryError {
            #expect(error.diagnosticCode == "CLAUDE_CODE_9")
            #expect(error.localizedDescription.contains("could not start Claude Code"))
        }
    }

    @Test("sign-in checks use the installed CLI without a model request")
    func authenticationStatus() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-claude-auth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        try "#!/bin/sh\n[ \"$1 $2\" = \"auth status\" ] || exit 7\nexit 0\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(await ClaudeCodeSummarizer.authenticationStatus(executablePath: executable.path) == .signedIn)

        try "#!/bin/sh\n[ \"$1 $2\" = \"auth status\" ] || exit 7\nexit 1\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        #expect(await ClaudeCodeSummarizer.authenticationStatus(executablePath: executable.path) == .signedOut)
        #expect(await ClaudeCodeSummarizer.authenticationStatus(executablePath: "/missing/muesli-test-claude") == .unavailable)
    }

    @Test("the app and audio CLI route the named provider through Claude Code")
    func providerDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-claude-dispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        input=$(cat)
        case "$input" in
          *"Decision: ship"*) ;;
          *) exit 3 ;;
        esac
        printf '%s' '{"type":"result","is_error":false,"result":"## Summary\\n- Ship"}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        var appConfig = AppConfig()
        appConfig.meetingSummaryBackend = MeetingSummaryBackendOption.claudeCode.backend
        appConfig.claudeCodeExecutablePath = executable.path
        let appSummary = try await MeetingSummaryClient.summarize(
            transcript: "Decision: ship",
            meetingTitle: "Launch",
            config: appConfig
        )
        #expect(appSummary.contains("## Summary\n- Ship"))

        var cliConfig = CLISummaryConfig()
        cliConfig.meetingSummaryBackend = "claude_code"
        cliConfig.claudeCodeExecutablePath = executable.path
        let cliSummary = try await CLISummaryClient.summarize(
            transcript: "Decision: ship",
            title: "Launch",
            config: cliConfig
        )
        #expect(cliSummary == "## Summary\n- Ship")
    }

    @Test("the audio CLI decodes the app's Claude Code configuration keys")
    func cliConfiguration() throws {
        var appConfig = AppConfig()
        appConfig.meetingSummaryBackend = "claude_code"
        appConfig.claudeCodeModel = "opus"
        appConfig.claudeCodeExecutablePath = "/custom/claude"
        let cliConfig = try JSONDecoder().decode(CLISummaryConfig.self, from: JSONEncoder().encode(appConfig))
        #expect(cliConfig.meetingSummaryBackend == "claude_code")
        #expect(cliConfig.claudeCodeModel == "opus")
        #expect(cliConfig.claudeCodeExecutablePath == "/custom/claude")
    }

    @Test("a CLI error payload is not saved as meeting notes")
    func errorPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-claude-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s' '{\"type\":\"result\",\"is_error\":true,\"result\":\"Not logged in\"}'\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        do {
            _ = try await ClaudeCodeSummarizer.run(
                instructions: "Summarize",
                input: "Transcript",
                executablePath: executable.path,
                timeout: 5
            )
            Issue.record("Expected CLI error payload to fail")
        } catch {
            #expect(error.localizedDescription.contains("Not logged in"))
        }
    }

    @Test("structured errors without a result explain the failure, including in verbose output", arguments: [false, true])
    func structuredErrors(verbose: Bool) throws {
        let failure = #"{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["Authentication expired","Please sign in again"]}"#
        let response = verbose ? "[{\"type\":\"assistant\",\"message\":\"private partial notes\"},\(failure)]" : failure
        do {
            _ = try ClaudeCodeSummarizer.result(from: Data(response.utf8), diagnostic: "", exitCode: 1)
            Issue.record("Expected structured CLI error")
        } catch ClaudeCodeSummaryError.failed(let message) {
            #expect(message.contains("error_during_execution"))
            #expect(message.contains("Authentication expired; Please sign in again"))
            #expect(message.contains("exit 1"))
            #expect(!message.contains("private partial notes"))
        }
    }

    @Test("the final result wins over earlier successful turns")
    func finalResultWins() throws {
        let response = #"[{"type":"result","subtype":"success","result":"Earlier notes"},{"type":"result","subtype":"error_max_budget_usd","is_error":false,"errors":["Budget exceeded"]}]"#
        do {
            _ = try ClaudeCodeSummarizer.result(from: Data(response.utf8), diagnostic: "", exitCode: 0)
            Issue.record("Expected final error result to fail even with exit 0")
        } catch ClaudeCodeSummaryError.failed(let message) {
            #expect(message.contains("Budget exceeded"))
            #expect(message.contains("error_max_budget_usd"))
            #expect(!message.contains("Earlier notes"))
        }
    }

    @Test("unexpected output has a support code and shape without exposing raw meeting content", arguments: [
        "private transcript text that is not JSON",
        #"[{"type":"assistant","message":"private transcript text"}]"#,
        #"{"type":"assistant","result":"private transcript text"}"#,
        #"{"type":"result","subtype":"unknown","result":"private transcript text"}"#,
        #"{"type":"result","subtype":"success","result":42}"#,
    ])
    func unexpectedOutput(response: String) throws {
        do {
            _ = try ClaudeCodeSummarizer.result(from: Data(response.utf8), diagnostic: "", exitCode: 0)
            Issue.record("Expected unexpected response failure")
        } catch let error as ClaudeCodeSummaryError {
            #expect(error.diagnosticCode == "CLAUDE_CODE_7")
            #expect(error.localizedDescription.contains("exit 0"))
            #expect(error.localizedDescription.contains("stdout \(response.utf8.count) bytes"))
            #expect(error.localizedDescription.contains("claude doctor"))
            #expect(!error.localizedDescription.contains("private transcript text"))
        }
    }

    @Test("nonzero exits preserve stderr and never accept a successful-looking result", arguments: [
        "private transcript text",
        #"{"type":"result","is_error":false,"result":"private transcript text"}"#,
    ])
    func unsuccessfulExit(response: String) throws {
        do {
            _ = try ClaudeCodeSummarizer.result(from: Data(response.utf8), diagnostic: "Unknown option --example", exitCode: 2)
            Issue.record("Expected process failure")
        } catch let error as ClaudeCodeSummaryError {
            #expect(error.diagnosticCode == "CLAUDE_CODE_8")
            #expect(error.localizedDescription.contains("code 2"))
            #expect(error.localizedDescription.contains("Unknown option --example"))
            #expect(!error.localizedDescription.contains("private transcript text"))
        }
    }

    @Test("no stdout is an empty response, not invalid JSON")
    func emptyOutput() throws {
        do {
            _ = try ClaudeCodeSummarizer.result(from: Data(), diagnostic: "", exitCode: 0)
            Issue.record("Expected empty response")
        } catch ClaudeCodeSummaryError.emptyResponse {
            // Empty responses retain the app's existing automatic retry policy.
        }
    }

    @Test("CLI diagnostics are retained when stdout cannot be decoded")
    func malformedOutputWithDiagnostics() throws {
        do {
            _ = try ClaudeCodeSummarizer.result(from: Data("not JSON".utf8), diagnostic: "CLI startup warning", exitCode: 0)
            Issue.record("Expected invalid response")
        } catch let error as ClaudeCodeSummaryError {
            #expect(error.localizedDescription.contains("CLI startup warning"))
            #expect(error.diagnosticCode == "CLAUDE_CODE_7")
        }
    }

    @Test("CLI error details are bounded")
    func boundedErrorDetails() throws {
        let payload: [String: Any] = ["type": "result", "is_error": true, "errors": [String(repeating: "x", count: 10_000)]]
        do {
            _ = try ClaudeCodeSummarizer.result(from: JSONSerialization.data(withJSONObject: payload), diagnostic: "", exitCode: 1)
            Issue.record("Expected structured CLI error")
        } catch let error as ClaudeCodeSummaryError {
            #expect(error.localizedDescription.count < 1600)
        }
    }

    @Test("large template instructions fail before launching Claude Code")
    func oversizedInstructions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-claude-instructions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let executable = directory.appendingPathComponent("claude")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        do {
            _ = try await ClaudeCodeSummarizer.run(
                instructions: String(repeating: "x", count: 200_000),
                input: "Short transcript",
                executablePath: executable.path
            )
            Issue.record("Expected oversized instructions to fail")
        } catch ClaudeCodeSummaryError.instructionsTooLarge {
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        } catch {
            Issue.record("Expected instructionsTooLarge, got \(error)")
        }
    }

    @Test("large CLI output is rejected")
    func oversizedOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-claude-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        try "#!/bin/sh\nhead -c 5000001 /dev/zero\nexec sleep 10\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let startedAt = Date()
        do {
            _ = try await ClaudeCodeSummarizer.run(
                instructions: "Summarize",
                input: "Transcript",
                executablePath: executable.path,
                timeout: 10
            )
            Issue.record("Expected oversized output to fail")
        } catch ClaudeCodeSummaryError.failed(let message) {
            #expect(message == "The response was too large.")
            #expect(Date().timeIntervalSince(startedAt) < 6)
        } catch {
            Issue.record("Expected an oversized response error, got \(error)")
        }
    }

    @Test("cancellation kills a Claude Code process that ignores termination")
    func cancellationKillsUnresponsiveProcess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-claude-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let executable = directory.appendingPathComponent("claude")
        let script = "#!/bin/sh\ntrap '' TERM\ntouch '\(marker.path)'\nwhile :; do sleep 1; done\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let operation = Task {
            try await ClaudeCodeSummarizer.run(
                instructions: "Summarize",
                input: "Transcript",
                executablePath: executable.path,
                timeout: 12
            )
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard FileManager.default.fileExists(atPath: marker.path) else {
            operation.cancel()
            Issue.record("Fake Claude Code did not start")
            return
        }

        let cancelledAt = Date()
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(Date().timeIntervalSince(cancelledAt) < 6)
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }
}
