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

    private let config: AppConfig
    private let maxSteps: Int?
    private let timeoutSeconds: TimeInterval
    private let registry = ComputerUseElementRegistry()
    private let onStatus: StatusHandler
    private let observe: ObserveHandler
    private let plan: PlanHandler
    private let execute: ExecuteHandler

    init(
        config: AppConfig,
        maxSteps: Int? = 100,
        timeoutSeconds: TimeInterval = 60,
        onStatus: @escaping StatusHandler = { _ in },
        observe: @escaping ObserveHandler = { registry, includeScreenshot in
            ComputerUseObservationCapture.capture(registry: registry, includeScreenshot: includeScreenshot)
        },
        plan: PlanHandler? = nil,
        execute: @escaping ExecuteHandler = { toolCall, registry in
            await ComputerUseToolExecutor.execute(toolCall, registry: registry)
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
            let message = "CUA planner is disabled."
            traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: message, status: "failed", step: nil))
            return .init(status: .failed, message: message, traceEvents: traceEvents)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var priorResults: [ComputerUseToolResult] = []
        var repeatedToolCounts: [String: Int] = [:]

        onStatus("Observing")
        var observation = observe(registry, false)
        traceEvents.append(observationEvent(observation, step: nil))

        var step = 1
        while true {
            if Date() >= deadline {
                traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: "CUA timed out", status: "failed", step: step))
                return .init(status: .failed, message: "CUA timed out", traceEvents: traceEvents)
            }
            if let maxSteps, step > maxSteps {
                traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: "CUA reached its step limit", status: "failed", step: maxSteps))
                return .init(status: .failed, message: "CUA reached its step limit", traceEvents: traceEvents)
            }
            defer { step += 1 }

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
                    body: "Step \(step)\(stepLimitSuffix(maxSteps)). Prior tool results: \(priorResults.count).",
                    status: "planning",
                    step: step
                ))
                response = try await plan(request)
            } catch {
                traceEvents.append(traceEvent(
                    kind: "failed",
                    title: "Planner failed",
                    body: error.localizedDescription,
                    status: "failed",
                    step: step
                ))
                return .init(status: .failed, message: error.localizedDescription, traceEvents: traceEvents)
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
            if let repeatedActionMessage = repeatedActionMessage(
                toolCall: toolCall,
                observation: observation,
                repeatedToolCounts: &repeatedToolCounts
            ) {
                traceEvents.append(traceEvent(kind: "failed", title: "Repeated action stopped", body: repeatedActionMessage, status: "failed", step: step))
                return .init(status: .failed, message: repeatedActionMessage, traceEvents: traceEvents)
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

    private func stepLimitSuffix(_ maxSteps: Int?) -> String {
        maxSteps.map { " of \($0)" } ?? ""
    }

    private func repeatedActionMessage(
        toolCall: ComputerUseToolCall,
        observation: ComputerUseObservation,
        repeatedToolCounts: inout [String: Int]
    ) -> String? {
        guard shouldTrackForRepetition(toolCall.tool) else { return nil }
        let key = [
            toolCall.tool.rawValue,
            toolCall.elementID ?? "",
            toolCall.appName ?? "",
            toolCall.label ?? "",
            toolCall.key ?? "",
            toolCall.text ?? "",
            toolCall.direction?.rawValue ?? "",
            observationSignature(observation),
        ].joined(separator: "|")
        let count = (repeatedToolCounts[key] ?? 0) + 1
        repeatedToolCounts[key] = count
        guard count > 2 else { return nil }
        return "CUA stopped after one retry of \(toolCall.summary) without an observed change."
    }

    private func shouldTrackForRepetition(_ tool: ComputerUseToolName) -> Bool {
        switch tool {
        case .clickElement, .clickPoint, .moveCursor, .drag, .pressKey, .typeText, .pasteText, .scroll:
            return true
        case .observe, .observeScreen, .openApp, .focusApp, .getCursorPosition, .finish:
            return false
        }
    }

    private func observationSignature(_ observation: ComputerUseObservation) -> String {
        [
            observation.bundleID,
            observation.appName,
            observation.windowTitle,
            "\(observation.elements.count)",
            observation.screenshot?.screenshotID ?? "",
        ].joined(separator: "|")
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
