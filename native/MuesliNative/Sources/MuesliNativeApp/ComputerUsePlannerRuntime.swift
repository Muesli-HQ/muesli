import Foundation
import MuesliCore

struct ComputerUsePlannerRuntimeResult: Equatable {
    enum Status: Equatable {
        case done
        case needsConfirmation
        case failed
    }

    let status: Status
    let message: String
    let traceEvents: [ComputerUseTraceEvent]

    init(status: Status, message: String, traceEvents: [ComputerUseTraceEvent] = []) {
        self.status = status
        self.message = message
        self.traceEvents = traceEvents
    }
}

@MainActor
final class ComputerUsePlannerRuntime {
    typealias StatusHandler = @MainActor (String) -> Void
    typealias ObserveHandler = @MainActor (ComputerUseElementRegistry, Bool) -> ComputerUseObservation
    typealias PlanHandler = (ComputerUsePlannerRequest) async throws -> ComputerUsePlannerResponse
    typealias ExecuteHandler = @MainActor (ComputerUseToolCall, ComputerUseElementRegistry) async -> ComputerUseExecutionResult
    typealias ParsedExecuteHandler = @MainActor (ParsedComputerUseIntent) async -> ComputerUseExecutionResult

    private let config: AppConfig
    private let maxSteps: Int
    private let timeoutSeconds: TimeInterval
    private let registry = ComputerUseElementRegistry()
    private let onStatus: StatusHandler
    private let observe: ObserveHandler
    private let plan: PlanHandler
    private let execute: ExecuteHandler
    private let executeParsed: ParsedExecuteHandler

    init(
        config: AppConfig,
        maxSteps: Int = 8,
        timeoutSeconds: TimeInterval = 20,
        onStatus: @escaping StatusHandler = { _ in },
        observe: @escaping ObserveHandler = { registry, includeScreenshot in
            ComputerUseObservationCapture.capture(registry: registry, includeScreenshot: includeScreenshot)
        },
        plan: PlanHandler? = nil,
        execute: @escaping ExecuteHandler = { toolCall, registry in
            await ComputerUseToolExecutor.execute(toolCall, registry: registry)
        },
        executeParsed: @escaping ParsedExecuteHandler = { parsed in
            await ComputerUseToolExecutor.execute(parsed)
        }
    ) {
        self.config = config
        self.maxSteps = maxSteps
        self.timeoutSeconds = timeoutSeconds
        self.onStatus = onStatus
        self.observe = observe
        self.plan = plan ?? { request in
            try await ComputerUsePlannerClient.planNextTool(request: request, config: config)
        }
        self.execute = execute
        self.executeParsed = executeParsed
    }

    func run(command: String) async -> ComputerUsePlannerRuntimeResult {
        var traceEvents = [
            traceEvent(
                kind: "transcript",
                title: "Command",
                body: command.isEmpty ? "(empty)" : command,
                status: nil,
                step: nil
            ),
        ]

        guard config.enableComputerUsePlanner else {
            return await runParserFallback(command: command, fallbackReason: nil, traceEvents: traceEvents)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var priorResults: [ComputerUseToolResult] = []

        onStatus("Observing")
        var observation = observe(registry, false)
        traceEvents.append(observationEvent(observation, step: nil))

        for step in 1...maxSteps {
            if Date() >= deadline {
                traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: "CUA timed out", status: "failed", step: step))
                return .init(status: .failed, message: "CUA timed out", traceEvents: traceEvents)
            }

            let request = ComputerUsePlannerRequest(
                command: command,
                step: step,
                maxSteps: maxSteps,
                observation: observation,
                priorResults: priorResults
            )

            let response: ComputerUsePlannerResponse
            do {
                onStatus("Planning")
                traceEvents.append(traceEvent(
                    kind: "planning",
                    title: "Planning",
                    body: "Step \(step) of \(maxSteps). Prior tool results: \(priorResults.count).",
                    status: "planning",
                    step: step
                ))
                response = try await plan(request)
            } catch {
                traceEvents.append(traceEvent(
                    kind: "fallback",
                    title: "Planner fallback",
                    body: error.localizedDescription,
                    status: "fallback",
                    step: step
                ))
                return await runParserFallback(command: command, fallbackReason: error, traceEvents: traceEvents)
            }

            let toolCall = response.toolCall
            traceEvents.append(traceEvent(
                kind: "model_output",
                title: "Model output",
                body: response.rawModelOutput ?? formatToolCall(toolCall),
                status: "planned",
                step: step
            ))
            if let validationFailure = toolCall.validationFailure() {
                traceEvents.append(traceEvent(kind: "failed", title: "Schema rejected", body: validationFailure, status: "failed", step: step))
                return .init(status: .failed, message: validationFailure, traceEvents: traceEvents)
            }
            if let mismatch = appNavigationMismatch(command: command, toolCall: toolCall) {
                traceEvents.append(traceEvent(
                    kind: "fallback",
                    title: "Planner app mismatch",
                    body: mismatch,
                    status: "fallback",
                    step: step
                ))
                return await runParserFallback(command: command, fallbackReason: PlannerMismatchError(message: mismatch), traceEvents: traceEvents)
            }
            if toolCall.requiresConfirmation {
                let message = "Confirm: \(toolCall.summary)"
                traceEvents.append(traceEvent(kind: "confirm", title: "Confirmation required", body: message, status: "confirm", step: step))
                return .init(status: .needsConfirmation, message: message, traceEvents: traceEvents)
            }

            switch toolCall.tool {
            case .finish:
                let message = toolCall.reason?.isEmpty == false ? toolCall.reason! : "Done"
                traceEvents.append(traceEvent(kind: "finish", title: "Final output", body: message, status: "done", step: step))
                return .init(status: .done, message: message, traceEvents: traceEvents)
            case .observe, .observeScreen:
                let includeScreenshot = toolCall.tool == .observeScreen || observation.screenshot != nil
                priorResults.append(ComputerUseToolResult(
                    step: step,
                    tool: toolCall.tool,
                    status: "executed",
                    message: includeScreenshot ? "Observed screen" : "Observed"
                ))
                onStatus("Observing")
                observation = observe(registry, includeScreenshot)
                traceEvents.append(observationEvent(observation, step: step))
                continue
            default:
                let shouldRefreshScreenshot = observation.screenshot != nil
                onStatus("Executing")
                traceEvents.append(traceEvent(
                    kind: "tool_call",
                    title: "Executing",
                    body: toolCall.summary,
                    status: "executing",
                    step: step
                ))
                let result = await execute(toolCall, registry)
                priorResults.append(ComputerUseToolResult(
                    step: step,
                    tool: toolCall.tool,
                    status: "\(result.status)",
                    message: result.message
                ))
                traceEvents.append(traceEvent(
                    kind: "tool_result",
                    title: "Tool result",
                    body: result.message,
                    status: "\(result.status)",
                    step: step
                ))

                switch result.status {
                case .executed:
                    onStatus("Observing")
                    observation = observe(registry, shouldRefreshScreenshot)
                    traceEvents.append(observationEvent(observation, step: step))
                case .needsConfirmation:
                    traceEvents.append(traceEvent(kind: "confirm", title: "Confirmation required", body: result.message, status: "confirm", step: step))
                    return .init(status: .needsConfirmation, message: result.message, traceEvents: traceEvents)
                case .unsupported, .failed:
                    traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: result.message, status: "failed", step: step))
                    return .init(status: .failed, message: result.message, traceEvents: traceEvents)
                }
            }
        }

        traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: "CUA reached its step limit", status: "failed", step: maxSteps))
        return .init(status: .failed, message: "CUA reached its step limit", traceEvents: traceEvents)
    }

    private func runParserFallback(
        command: String,
        fallbackReason: Error?,
        traceEvents: [ComputerUseTraceEvent]
    ) async -> ComputerUsePlannerRuntimeResult {
        var traceEvents = traceEvents
        guard let parsed = ComputerUseIntentParser.parse(command) else {
            if let plannerError = fallbackReason as? ComputerUsePlannerError,
               plannerError == .notAuthenticated {
                traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: plannerError.localizedDescription, status: "failed", step: nil))
                return .init(status: .failed, message: plannerError.localizedDescription, traceEvents: traceEvents)
            }
            if let fallbackReason {
                traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: fallbackReason.localizedDescription, status: "failed", step: nil))
                return .init(status: .failed, message: fallbackReason.localizedDescription, traceEvents: traceEvents)
            }
            traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: "Unsupported CUA command", status: "failed", step: nil))
            return .init(status: .failed, message: "Unsupported CUA command", traceEvents: traceEvents)
        }

        traceEvents.append(traceEvent(kind: "fallback", title: "Rule parser", body: parsed.intent.summary, status: "parsed", step: nil))
        if parsed.requiresConfirmation {
            let message = "Confirm: \(parsed.intent.summary)"
            traceEvents.append(traceEvent(kind: "confirm", title: "Confirmation required", body: message, status: "confirm", step: nil))
            return .init(status: .needsConfirmation, message: message, traceEvents: traceEvents)
        }

        onStatus("Executing")
        let result = await executeParsed(parsed)
        traceEvents.append(traceEvent(kind: "tool_result", title: "Tool result", body: result.message, status: "\(result.status)", step: nil))
        switch result.status {
        case .executed:
            let message = "Done: \(parsed.intent.summary)"
            traceEvents.append(traceEvent(kind: "finish", title: "Final output", body: message, status: "done", step: nil))
            return .init(status: .done, message: message, traceEvents: traceEvents)
        case .needsConfirmation:
            let message = "Confirm: \(parsed.intent.summary)"
            traceEvents.append(traceEvent(kind: "confirm", title: "Confirmation required", body: message, status: "confirm", step: nil))
            return .init(status: .needsConfirmation, message: message, traceEvents: traceEvents)
        case .unsupported, .failed:
            if let plannerError = fallbackReason as? ComputerUsePlannerError,
               plannerError == .notAuthenticated {
                traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: plannerError.localizedDescription, status: "failed", step: nil))
                return .init(status: .failed, message: plannerError.localizedDescription, traceEvents: traceEvents)
            }
            traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: result.message, status: "failed", step: nil))
            return .init(status: .failed, message: result.message, traceEvents: traceEvents)
        }
    }

    private func observationEvent(_ observation: ComputerUseObservation, step: Int?) -> ComputerUseTraceEvent {
        let app = observation.appName.isEmpty ? "Unknown app" : observation.appName
        let window = observation.windowTitle.isEmpty ? "No focused window" : observation.windowTitle
        var details = ["\(app) - \(window) - \(observation.elements.count) AX candidates"]
        if let screenshot = observation.screenshot {
            details.append("screenshot \(screenshot.screenshotID) \(screenshot.width)x\(screenshot.height)")
        }
        if let cursor = observation.cursorPosition {
            details.append("cursor \(Int(cursor.x.rounded())),\(Int(cursor.y.rounded()))")
        }
        return traceEvent(
            kind: "observation",
            title: "Observation",
            body: details.joined(separator: " - "),
            status: "observed",
            step: step
        )
    }

    private func formatToolCall(_ toolCall: ComputerUseToolCall) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(toolCall),
              let text = String(data: data, encoding: .utf8) else {
            return toolCall.summary
        }
        return text
    }

    private func appNavigationMismatch(command: String, toolCall: ComputerUseToolCall) -> String? {
        guard let parsed = ComputerUseIntentParser.parse(command) else { return nil }

        let requestedApp: String
        switch parsed.intent {
        case .openApp(let name), .focusApp(let name):
            requestedApp = name
        default:
            return nil
        }

        let plannedApp: String
        switch toolCall.tool {
        case .openApp, .focusApp:
            plannedApp = toolCall.appName ?? ""
        default:
            return nil
        }

        guard !appNamesMatch(requestedApp, plannedApp) else { return nil }
        return "Planner selected \(plannedApp.isEmpty ? "an empty app name" : plannedApp) for a command that requested \(requestedApp)."
    }

    private func appNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = canonicalAppName(lhs)
        let right = canonicalAppName(rhs)
        if left == right { return true }
        if left.replacingOccurrences(of: " ", with: "") == right.replacingOccurrences(of: " ", with: "") {
            return true
        }
        guard let leftBundle = ComputerUseToolExecutor.bundleIdentifierAlias(for: left),
              let rightBundle = ComputerUseToolExecutor.bundleIdentifierAlias(for: right) else {
            return false
        }
        return leftBundle == rightBundle
    }

    private func canonicalAppName(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar)
                ? Character(scalar)
                : " "
        }
        return String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .replacingOccurrences(of: #" app$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func traceEvent(
        kind: String,
        title: String,
        body: String,
        status: String?,
        step: Int?
    ) -> ComputerUseTraceEvent {
        ComputerUseTraceEvent(kind: kind, title: title, body: body, status: status, step: step)
    }
}

private struct PlannerMismatchError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private extension ComputerUseIntent {
    var summary: String {
        switch self {
        case .openApp(let name):
            return "open \(name)"
        case .focusApp(let name):
            return "focus \(name)"
        case .click(let label):
            return "click \(label)"
        case .pressKey(let command):
            let parts = command.modifiers.map(\.rawValue) + [command.key]
            return "press \(parts.joined(separator: "+"))"
        case .typeText(let text):
            return "type \(text.count > 32 ? String(text.prefix(29)) + "..." : text)"
        case .pasteText(let text):
            return "paste \(text.count > 32 ? String(text.prefix(29)) + "..." : text)"
        case .scroll(let direction, _):
            return "scroll \(direction.rawValue)"
        }
    }
}
