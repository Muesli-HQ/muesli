import Foundation

public enum ClaudeCodeAuthenticationStatus: Equatable {
    case unavailable
    case signedIn
    case signedOut
    case unknown
}

public enum ClaudeCodeSummaryError: LocalizedError, CustomNSError {
    case unavailable
    case inputTooLarge
    case instructionsTooLarge
    case timedOut
    case failed(String)
    case emptyResponse
    case invalidResponse(exitCode: Int32, details: String)
    case processFailed(exitCode: Int32, details: String)
    case launchFailed(String)

    public static var errorDomain: String { "MuesliClaudeCode" }

    /// Explicit values stay stable across releases and can be included in diagnostic reports.
    public var errorCode: Int {
        switch self {
        case .unavailable: return 1
        case .inputTooLarge: return 2
        case .instructionsTooLarge: return 3
        case .timedOut: return 4
        case .failed: return 5
        case .emptyResponse: return 6
        case .invalidResponse: return 7
        case .processFailed: return 8
        case .launchFailed: return 9
        }
    }

    public var diagnosticCode: String { "CLAUDE_CODE_\(errorCode)" }

    public var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? diagnosticCode]
    }

    public var errorDescription: String? {
        let description: String
        switch self {
        case .unavailable:
            description = "Claude Code could not be found at the configured executable path. Locate your existing installation in Settings and try again."
        case .inputTooLarge:
            description = "The meeting prompt exceeds Claude Code's 10 MB stdin limit. Use a shorter transcript or another summary backend."
        case .instructionsTooLarge:
            description = "The meeting instructions exceed muesli's 100 KB safe process argument limit. Shorten the meeting template and try again."
        case .timedOut:
            description = "Claude Code took too long to generate meeting notes. Check your connection and try again. You can also select a faster model in Settings."
        case .failed(let message):
            description = "Claude Code could not generate meeting notes. \(message) Open Claude Code in Terminal to check its sign-in, model availability, and connection, then try again."
        case .emptyResponse:
            description = "Claude Code returned an empty response. Try again. If this continues, run claude doctor in Terminal."
        case let .invalidResponse(exitCode, details):
            description = "Claude Code returned an unexpected response (exit \(exitCode)). \(details) Run claude --version and claude doctor in Terminal, and include this error code when reporting the problem."
        case let .processFailed(exitCode, details):
            description = "Claude Code exited with code \(exitCode) before returning meeting notes. \(details) Open Claude Code in Terminal to check its sign-in, model availability, and connection, then try again."
        case .launchFailed(let message):
            description = "muesli could not start Claude Code. \(message) Check the executable selected in Settings."
        }
        return "\(description) [\(diagnosticCode)]"
    }
}

/// Runs the user's locally installed Claude Code without a shell or access to meeting files.
public enum ClaudeCodeSummarizer {
    private static let maximumInputBytes = 10_000_000
    private static let maximumInstructionBytes = 100_000
    private static let maximumOutputBytes = 5_000_000
    private static let maximumErrorBytes = 1_000_000

    public static func executableURL(configuredPath: String = "") -> URL? {
        let path = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty {
            let expanded = NSString(string: path).expandingTildeInPath
            guard expanded.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: expanded) else { return nil }
            return URL(fileURLWithPath: expanded)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
            + ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in searchPaths where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Checks the CLI's own login state without starting a model request.
    public static func authenticationStatus(executablePath: String = "") async -> ClaudeCodeAuthenticationStatus {
        guard let executable = executableURL(configuredPath: executablePath) else { return .unavailable }
        return await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["auth", "status"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let deadline = Date().addingTimeInterval(5)
            let timeoutWork = DispatchWorkItem {
                if process.isRunning { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            do {
                try process.run()
            } catch {
                return .unknown
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeoutWork)
            process.waitUntilExit()
            timeoutWork.cancel()
            if Date() >= deadline { return .unknown }
            switch process.terminationStatus {
            case 0: return .signedIn
            case 1: return .signedOut
            default: return .unknown
            }
        }.value
    }

    public static func run(
        instructions: String,
        input: String,
        model: String = "",
        executablePath: String = "",
        timeout: TimeInterval = 300
    ) async throws -> String {
        guard let executable = executableURL(configuredPath: executablePath) else {
            throw ClaudeCodeSummaryError.unavailable
        }
        guard input.utf8.count <= maximumInputBytes else { throw ClaudeCodeSummaryError.inputTooLarge }
        guard instructions.utf8.count <= maximumInstructionBytes else { throw ClaudeCodeSummaryError.instructionsTooLarge }
        try Task.checkCancellation()

        let process = Process()
        let task = Task.detached(priority: .utility) {
            try runProcess(
                process,
                executable: executable,
                instructions: instructions,
                input: input,
                model: model,
                timeout: timeout
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            stopProcess(process)
        }
    }

    private static func stopProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private static func fileSize(at url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private static func runProcess(
        _ process: Process,
        executable: URL,
        instructions: String,
        input: String,
        model: String,
        timeout: TimeInterval
    ) throws -> String {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.txt")
        let outputURL = directory.appendingPathComponent("output.json")
        let errorURL = directory.appendingPathComponent("error.txt")
        try Data(input.utf8).write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
            try? errorHandle.close()
        }

        process.executableURL = executable
        process.currentDirectoryURL = directory
        process.standardInput = inputHandle
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        var arguments = ["-p", instructions, "--output-format", "json", "--no-session-persistence",
                         "--disable-slash-commands", "--strict-mcp-config", "--setting-sources", "user"]
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedModel.isEmpty { arguments += ["--model", selectedModel] }
        arguments += ["--tools", ""]
        process.arguments = arguments
        let deadline = Date().addingTimeInterval(timeout)
        let timeoutWork = DispatchWorkItem {
            stopProcess(process)
        }
        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            throw ClaudeCodeSummaryError.launchFailed(error.localizedDescription)
        }
        if Task.isCancelled { stopProcess(process) }
        let outputMonitor = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        outputMonitor.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        outputMonitor.setEventHandler {
            if (fileSize(at: outputURL) ?? 0) > maximumOutputBytes ||
                (fileSize(at: errorURL) ?? 0) > maximumErrorBytes {
                outputMonitor.cancel()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        outputMonitor.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        process.waitUntilExit()
        outputMonitor.cancel()
        timeoutWork.cancel()
        try Task.checkCancellation()
        if Date() >= deadline { throw ClaudeCodeSummaryError.timedOut }

        guard let outputSize = fileSize(at: outputURL), outputSize <= maximumOutputBytes else {
            throw ClaudeCodeSummaryError.failed("The response was too large.")
        }
        guard let errorSize = fileSize(at: errorURL), errorSize <= maximumErrorBytes else {
            throw ClaudeCodeSummaryError.failed("The CLI diagnostics were too large.")
        }
        let output = try Data(contentsOf: outputURL)
        let errorReader = try FileHandle(forReadingFrom: errorURL)
        defer { try? errorReader.close() }
        let errorData = (try? errorReader.read(upToCount: 4_096)) ?? Data()
        let diagnostic = String(decoding: errorData, as: UTF8.self)
            .prefix(1200).trimmingCharacters(in: .whitespacesAndNewlines)
        return try result(from: output, diagnostic: diagnostic, exitCode: process.terminationStatus)
    }

    /// `json` returns one result object, or a message array when the user's viewMode is verbose.
    /// Only a final result is usable: assistant messages may be partial output or error text.
    static func result(from output: Data, diagnostic: String, exitCode: Int32) throws -> String {
        let json = try? JSONSerialization.jsonObject(with: output, options: [.fragmentsAllowed])
        let payload: [String: Any]?
        let shape: String
        if let object = json as? [String: Any] {
            payload = object["type"] as? String == "result" ? object : nil
            shape = "JSON object without a result message"
        } else if let messages = json as? [Any] {
            payload = messages.compactMap { $0 as? [String: Any] }.last { $0["type"] as? String == "result" }
            shape = "JSON array without a result message (\(messages.count) messages)"
        } else {
            payload = nil
            shape = json == nil ? "Malformed or missing JSON" : "Unexpected JSON value"
        }
        let stderrDetail = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never include raw stdout in an error: verbose output contains the prompt and meeting text.
        let responseDetail = "\(shape); stdout \(output.count) bytes."
            + (stderrDetail.isEmpty ? " No stderr diagnostics." : " CLI diagnostics: \(String(stderrDetail.prefix(1200)))")

        if let payload {
            let subtype = payload["subtype"] as? String ?? ""
            if payload["is_error"] as? Bool == true || subtype.hasPrefix("error_") {
                // Error results commonly omit `result` and carry their explanation in `errors` instead.
                let errors = (payload["errors"] as? [String] ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                let legacyResult = (payload["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let explanation = !errors.isEmpty ? errors.joined(separator: "; ")
                    : (!legacyResult.isEmpty ? legacyResult : stderrDetail)
                let reason = subtype.isEmpty ? "error" : String(subtype.prefix(80))
                throw ClaudeCodeSummaryError.failed("CLI result: \(reason) (exit \(exitCode)). "
                    + (explanation.isEmpty ? "The CLI provided no error details." : String(explanation.prefix(1200))))
            }
            if exitCode != 0 {
                throw ClaudeCodeSummaryError.processFailed(exitCode: exitCode, details:
                    stderrDetail.isEmpty ? "The CLI returned a result but did not exit successfully." : String(stderrDetail.prefix(1200)))
            }
            guard subtype.isEmpty || subtype == "success" else {
                throw ClaudeCodeSummaryError.invalidResponse(exitCode: exitCode, details: "Unrecognized result subtype. stdout \(output.count) bytes.")
            }
            guard let text = payload["result"] as? String else {
                throw ClaudeCodeSummaryError.invalidResponse(exitCode: exitCode, details: "The result message has no text result. stdout \(output.count) bytes.")
            }
            let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !result.isEmpty else { throw ClaudeCodeSummaryError.emptyResponse }
            return result
        }
        if exitCode != 0 {
            throw ClaudeCodeSummaryError.processFailed(exitCode: exitCode, details: responseDetail)
        }
        if output.isEmpty, stderrDetail.isEmpty { throw ClaudeCodeSummaryError.emptyResponse }
        throw ClaudeCodeSummaryError.invalidResponse(exitCode: exitCode, details: responseDetail)
    }
}
