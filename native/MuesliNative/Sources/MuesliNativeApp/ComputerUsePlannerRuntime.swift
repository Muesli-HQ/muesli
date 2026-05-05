import Foundation

struct ComputerUsePlannerRuntimeResult: Equatable {
    enum Status: Equatable {
        case done
        case needsConfirmation
        case failed
    }

    let status: Status
    let message: String
}

@MainActor
final class ComputerUsePlannerRuntime {
    typealias StatusHandler = @MainActor (String) -> Void
    typealias ObserveHandler = @MainActor (ComputerUseElementRegistry) -> ComputerUseObservation
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
        observe: @escaping ObserveHandler = { registry in
            ComputerUseObservationCapture.capture(registry: registry)
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
        guard config.enableComputerUsePlanner else {
            return await runParserFallback(command: command, fallbackReason: nil)
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var priorResults: [ComputerUseToolResult] = []

        onStatus("Observing")
        var observation = observe(registry)

        for step in 1...maxSteps {
            if Date() >= deadline {
                return .init(status: .failed, message: "CUA timed out")
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
                response = try await plan(request)
            } catch {
                return await runParserFallback(command: command, fallbackReason: error)
            }

            let toolCall = response.toolCall
            if let validationFailure = toolCall.validationFailure() {
                return .init(status: .failed, message: validationFailure)
            }
            if toolCall.requiresConfirmation {
                return .init(status: .needsConfirmation, message: "Confirm: \(toolCall.summary)")
            }

            switch toolCall.tool {
            case .finish:
                return .init(status: .done, message: toolCall.reason?.isEmpty == false ? toolCall.reason! : "Done")
            case .observe:
                priorResults.append(ComputerUseToolResult(
                    step: step,
                    tool: .observe,
                    status: "executed",
                    message: "Observed"
                ))
                onStatus("Observing")
                observation = observe(registry)
                continue
            default:
                onStatus("Executing")
                let result = await execute(toolCall, registry)
                priorResults.append(ComputerUseToolResult(
                    step: step,
                    tool: toolCall.tool,
                    status: "\(result.status)",
                    message: result.message
                ))

                switch result.status {
                case .executed:
                    onStatus("Observing")
                    observation = observe(registry)
                case .needsConfirmation:
                    return .init(status: .needsConfirmation, message: result.message)
                case .unsupported, .failed:
                    return .init(status: .failed, message: result.message)
                }
            }
        }

        return .init(status: .failed, message: "CUA reached its step limit")
    }

    private func runParserFallback(command: String, fallbackReason: Error?) async -> ComputerUsePlannerRuntimeResult {
        guard let parsed = ComputerUseIntentParser.parse(command) else {
            if let plannerError = fallbackReason as? ComputerUsePlannerError,
               plannerError == .notAuthenticated {
                return .init(status: .failed, message: plannerError.localizedDescription)
            }
            if let fallbackReason {
                return .init(status: .failed, message: fallbackReason.localizedDescription)
            }
            return .init(status: .failed, message: "Unsupported CUA command")
        }

        if parsed.requiresConfirmation {
            return .init(status: .needsConfirmation, message: "Confirm: \(parsed.intent.summary)")
        }

        onStatus("Executing")
        let result = await executeParsed(parsed)
        switch result.status {
        case .executed:
            return .init(status: .done, message: "Done: \(parsed.intent.summary)")
        case .needsConfirmation:
            return .init(status: .needsConfirmation, message: "Confirm: \(parsed.intent.summary)")
        case .unsupported, .failed:
            if let plannerError = fallbackReason as? ComputerUsePlannerError,
               plannerError == .notAuthenticated {
                return .init(status: .failed, message: plannerError.localizedDescription)
            }
            return .init(status: .failed, message: result.message)
        }
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
