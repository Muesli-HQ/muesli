import AppKit
import CryptoKit
import Foundation
import MuesliCore

struct ComputerUsePlannerRuntimeResult: Equatable {
    enum Status: Equatable {
        case done
        case timedOut
        case needsConfirmation
        case failed
        case noProgress
        case cancelled
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
    typealias ObserveHandler = @MainActor (ComputerUseElementRegistry, Bool, ComputerUseObservationTarget?) -> ComputerUseObservation
    typealias PlanHandler = (ComputerUsePlannerRequest) async throws -> ComputerUsePlannerResponse
    typealias ExecuteHandler = @MainActor (ComputerUseToolCall, ComputerUseElementRegistry) async -> ComputerUseExecutionResult
    typealias ScreenshotTextRecognizer = (ComputerUseScreenshotObservation?) async -> String?

    private let config: AppConfig
    private let maxSteps: Int?
    private let timeoutSeconds: TimeInterval
    private let safetyLimitSeconds: Int
    private let registry = ComputerUseElementRegistry()
    private let onStatus: StatusHandler
    private let observe: ObserveHandler
    private let plan: PlanHandler
    private let execute: ExecuteHandler
    private let recognizeScreenshotText: ScreenshotTextRecognizer
    private let maxPlannerRetryCount = 1
    private let maxUnchangedObservationLoops = 4
    private let maxReadOnlyOrientationStepsBeforeRepair = 4
    private let maxReadOnlyOrientationRepairs = 2
    private static let actionRequiredTools: [ComputerUseToolName] = [
        .recognizeScreenshotText,
        .click,
        .pasteText,
        .pressKey,
        .scroll,
        .openNewBrowserTab,
        .navigateActiveBrowserTab,
        .launchApp,
        .finish,
        .fail,
    ]

    private struct PendingUnverifiedTextWrite {
        let sample: String
        let toolSummary: String
        let step: Int
        let textEvidenceCountBefore: Int
        let visibleEvidenceCountBefore: Int
        let preActionOCRSampleCount: Int?
    }

    private struct TextWriteEvidenceMatch {
        let source: String
        let availableCount: Int
    }

    private struct ReadOnlyOrientationStreak {
        var targetSignature = ""
        var count = 0
        var repairCount = 0

        mutating func reset() {
            targetSignature = ""
            count = 0
            repairCount = 0
        }
    }

    init(
        config: AppConfig,
        maxSteps: Int? = 100,
        timeoutSeconds: TimeInterval? = nil,
        onStatus: @escaping StatusHandler = { _ in },
        observe: @escaping ObserveHandler = { registry, includeScreenshot, target in
            ComputerUseObservationCapture.capture(
                registry: registry,
                includeScreenshot: includeScreenshot,
                target: target
            )
        },
        plan: PlanHandler? = nil,
        execute: ExecuteHandler? = nil,
        recognizeScreenshotText: @escaping ScreenshotTextRecognizer = { screenshot in
            await ComputerUseScreenshotTextRecognition.recognizedText(from: screenshot)
        }
    ) {
        self.config = config
        self.maxSteps = maxSteps
        if let timeoutSeconds {
            self.timeoutSeconds = timeoutSeconds
            self.safetyLimitSeconds = max(Int(timeoutSeconds.rounded()), 1)
        } else {
            self.safetyLimitSeconds = AppConfig.clampedComputerUseSafetyLimitSeconds(config.computerUseTimeoutSeconds)
            self.timeoutSeconds = TimeInterval(safetyLimitSeconds)
        }
        self.onStatus = onStatus
        self.observe = observe
        self.plan = plan ?? { request in
            try await ComputerUsePlannerClient.planNextTool(request: request, config: config)
        }
        self.execute = execute ?? { toolCall, registry in
            await ComputerUseToolExecutor.execute(
                toolCall,
                registry: registry,
                interactionMode: config.computerUseInteractionMode
            )
        }
        self.recognizeScreenshotText = recognizeScreenshotText
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
        var priorResults: [ComputerUseToolOutcome] = []
        var unchangedActionCounts: [String: Int] = [:]
        var unchangedObservationCounts: [String: Int] = [:]
        var invalidToolCallRepairCount = 0
        var readOnlyOrientationStreak = ReadOnlyOrientationStreak()
        var forceActionOnlyTools = false
        var screenshotOCRTextByID: [String: String] = [:]
        var pendingUnverifiedTextWrites: [PendingUnverifiedTextWrite] = []
        var consumedTextWriteEvidenceCounts: [String: Int] = [:]
        let maxInvalidToolCallRepairs = 2
        // The harness keeps target state scoped and marks each tool with its execution
        // contract. Deeper Codex/trycua-style work still needs pid-routed pointer
        // delivery and synthetic key-window focus, but foreground tools are no longer
        // presented as equivalent to background-capable primitives.
        var currentTarget: ComputerUseObservationTarget?

        onStatus("Observing screen")
        var observation = observe(registry, true, currentTarget)
        traceEvents.append(observationEvent(observation, step: nil, currentTarget: currentTarget))

        var step = 1
        while true {
            if Task.isCancelled {
                return cancelledResult(traceEvents: traceEvents, step: step)
            }
            if Date() >= deadline {
                let message = "Stopped after safety limit (\(formatDuration(safetyLimitSeconds)))."
                traceEvents.append(traceEvent(kind: "timed_out", title: "Safety limit", body: message, status: "timed_out", step: step))
                return .init(status: .timedOut, message: message, traceEvents: traceEvents)
            }
            if let maxSteps, step > maxSteps {
                traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: "CUA reached its step limit", status: "failed", step: maxSteps))
                return .init(status: .failed, message: "CUA reached its step limit", traceEvents: traceEvents)
            }
            defer { step += 1 }

            let latestWindowState = await windowState(
                for: observation,
                screenshotOCRTextByID: &screenshotOCRTextByID
            )
            pendingUnverifiedTextWrites = unresolvedPendingUnverifiedTextWrites(
                pendingUnverifiedTextWrites,
                observation: observation,
                screenshotOCRTextByID: screenshotOCRTextByID,
                consumedEvidenceCounts: &consumedTextWriteEvidenceCounts
            )
            let request = ComputerUsePlannerRequest(
                command: command,
                step: step,
                maxSteps: maxSteps,
                safetyLimitSeconds: safetyLimitSeconds,
                availableTools: forceActionOnlyTools ? Self.actionRequiredTools : nil,
                latestWindowState: latestWindowState,
                observationContext: observationContext(for: observation, currentTarget: currentTarget),
                priorOutcomes: priorResults
            )

            let response: ComputerUsePlannerResponse
            do {
                response = try await planWithRetry(request, traceEvents: &traceEvents)
            } catch is CancellationError {
                return cancelledResult(traceEvents: traceEvents, step: step)
            } catch ComputerUsePlannerError.invalidToolCall(let name, let arguments, let message) {
                let repairMessage = "Invalid tool call \(name): \(message). Raw arguments: \(String(arguments.prefix(800))). Choose exactly one valid tool from the current catalog and follow that tool's schema."
                traceEvents.append(traceEvent(
                    kind: "planner_repair",
                    title: "Planner schema repair",
                    body: repairMessage,
                    status: "repair",
                    step: step
                ))
                priorResults.append(ComputerUseToolOutcome(
                    step: step,
                    tool: .fail,
                    status: "invalid_schema",
                    message: repairMessage,
                    appName: observation.appName,
                    bundleID: observation.bundleID,
                    windowTitle: observation.windowTitle,
                    snapshotID: observation.screenshot?.screenshotID
                ))
                invalidToolCallRepairCount += 1
                if invalidToolCallRepairCount <= maxInvalidToolCallRepairs {
                    continue
                }
                traceEvents.append(traceEvent(kind: "failed", title: "Planner failed", body: repairMessage, status: "failed", step: step))
                return .init(status: .failed, message: repairMessage, traceEvents: traceEvents)
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

            if let availabilityFailure = response.toolAvailabilityFailure(availableTools: request.availableTools) {
                let rawOutput = response.rawModelOutput ?? formatToolCall(response.toolCall)
                let repairMessage = "Invalid tool call \(response.toolCall.tool.rawValue): \(availabilityFailure). Raw arguments: \(String(rawOutput.prefix(800))). Choose exactly one valid tool from the current catalog and follow that tool's schema."
                traceEvents.append(traceEvent(
                    kind: "planner_repair",
                    title: "Planner schema repair",
                    body: repairMessage,
                    status: "repair",
                    step: step
                ))
                priorResults.append(ComputerUseToolOutcome(
                    step: step,
                    tool: .fail,
                    status: "invalid_schema",
                    message: repairMessage,
                    appName: observation.appName,
                    bundleID: observation.bundleID,
                    windowTitle: observation.windowTitle,
                    snapshotID: observation.screenshot?.screenshotID
                ))
                invalidToolCallRepairCount += 1
                if invalidToolCallRepairCount <= maxInvalidToolCallRepairs {
                    continue
                }
                traceEvents.append(traceEvent(kind: "failed", title: "Planner failed", body: repairMessage, status: "failed", step: step))
                return .init(status: .failed, message: repairMessage, traceEvents: traceEvents)
            }

            let toolCall = response.toolCall
            invalidToolCallRepairCount = 0
            if let target = target(from: toolCall, fallback: currentTarget) {
                currentTarget = target
            }
            traceEvents.append(traceEvent(
                kind: "model_output",
                title: "Model output",
                body: response.rawModelOutput ?? formatToolCall(toolCall),
                status: "planned",
                step: step,
                debugPayload: encodedDebugPayload(toolCall)
            ))
            if let validationFailure = toolCall.validationFailure() {
                traceEvents.append(traceEvent(kind: "failed", title: "Schema rejected", body: validationFailure, status: "failed", step: step))
                return .init(status: .failed, message: validationFailure, traceEvents: traceEvents)
            }
            if let blockedMessage = targetMismatchMutationMessage(observation: observation, toolCall: toolCall) {
                priorResults.append(ComputerUseToolOutcome(
                    step: step,
                    tool: toolCall.tool,
                    status: "target_mismatch",
                    message: blockedMessage,
                    appName: observation.appName,
                    bundleID: observation.bundleID,
                    windowTitle: observation.windowTitle,
                    snapshotID: observation.screenshot?.screenshotID
                ))
                traceEvents.append(traceEvent(kind: "planner_repair", title: "Target mismatch", body: blockedMessage, status: "repair", step: step))
                continue
            }
            if toolCall.requiresConfirmation {
                onStatus("Confirm")
                let message = "Confirm: \(toolCall.summary)"
                traceEvents.append(traceEvent(kind: "confirm", title: "Confirmation required", body: message, status: "confirm", step: step))
                return .init(status: .needsConfirmation, message: message, traceEvents: traceEvents)
            }

            switch toolCall.tool {
            case .finish:
                let message = toolCall.reason?.isEmpty == false ? toolCall.reason! : "Done"
                let unverifiedTextWrites = unresolvedPendingUnverifiedTextWrites(
                    pendingUnverifiedTextWrites,
                    observation: observation,
                    screenshotOCRTextByID: screenshotOCRTextByID,
                    consumedEvidenceCounts: &consumedTextWriteEvidenceCounts
                )
                if !unverifiedTextWrites.isEmpty {
                    let details = unverifiedTextWrites
                        .map { "\($0.toolSummary) from step \($0.step)" }
                        .joined(separator: "; ")
                    let warning = "Finish blocked because text write evidence is unverified: \(details). Refresh state, use recognize_screenshot_text if visible text is needed, or fail with the reason if the write cannot be confirmed."
                    traceEvents.append(traceEvent(
                        kind: "failed",
                        title: "Text write unverified",
                        body: warning,
                        status: "failed",
                        step: step
                    ))
                    return .init(status: .failed, message: warning, traceEvents: traceEvents)
                }
                onStatus("Done")
                if finishIndicatesFailure(message) {
                    let blockedMessage = "Planner attempted to finish with an incomplete or blocked result: \(message)"
                    traceEvents.append(traceEvent(kind: "failed", title: "Final output blocked", body: blockedMessage, status: "failed", step: step))
                    return .init(status: .failed, message: blockedMessage, traceEvents: traceEvents)
                }
                traceEvents.append(traceEvent(kind: "finish", title: "Final output", body: message, status: "done", step: step))
                return .init(status: .done, message: message, traceEvents: traceEvents)
            case .fail:
                onStatus("Failed")
                let message = toolCall.reason?.isEmpty == false ? toolCall.reason! : "Failed"
                traceEvents.append(traceEvent(kind: "failed", title: "Final output", body: message, status: "failed", step: step))
                return .init(status: .failed, message: message, traceEvents: traceEvents)
            case .recognizeScreenshotText:
                readOnlyOrientationStreak.reset()
                onStatus("Reading")
                let result = await recognizeScreenshotTextTool(
                    toolCall,
                    observation: observation,
                    screenshotOCRTextByID: &screenshotOCRTextByID
                )
                if Task.isCancelled || result.status == .cancelled {
                    return cancelledResult(traceEvents: traceEvents, step: step)
                }
                priorResults.append(outcome(
                    step: step,
                    toolCall: toolCall,
                    result: result,
                    message: result.message,
                    observation: observation,
                    delta: nil
                ))
                traceEvents.append(traceEvent(
                    kind: "tool_result",
                    title: resultStatusTitle(for: toolCall, result: result) ?? "Tool result",
                    body: result.message,
                    status: "\(result.status)",
                    step: step,
                    debugPayload: encodedDebugPayload(TraceToolResultPayload(result))
                ))
                if result.status == .failed || result.status == .unsupported {
                    traceEvents.append(traceEvent(kind: "planner_repair", title: "OCR failed", body: "\(result.message). Refresh window state and retry OCR with the latest screenshot_id if visual text is needed.", status: "repair", step: step))
                }
                continue
            case .getAppState, .getWindowState:
                onStatus("Observing screen")
                let beforeObservation = observation
                let result = await execute(toolCall, registry)
                if Task.isCancelled || result.status == .cancelled {
                    return cancelledResult(traceEvents: traceEvents, step: step)
                }
                if result.status == .failed || result.status == .unsupported {
                    let outcomeMessage = recoverableFallbackMessage(for: toolCall, result: result) ?? result.message
                    priorResults.append(outcome(
                        step: step,
                        toolCall: toolCall,
                        result: result,
                        message: outcomeMessage,
                        observation: beforeObservation,
                        delta: nil
                    ))
                    traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: outcomeMessage, status: "failed", step: step))
                    return .init(status: .failed, message: outcomeMessage, traceEvents: traceEvents)
                }
                onStatus("Observing screen")
                observation = observe(registry, true, currentTarget)
                traceEvents.append(observationEvent(observation, step: step, currentTarget: currentTarget))
                let observationFeedback = observationToolFeedback(
                    before: beforeObservation,
                    after: observation,
                    toolCall: toolCall,
                    result: result,
                    counts: &unchangedObservationCounts
                )
                priorResults.append(outcome(
                    step: step,
                    toolCall: toolCall,
                    result: result,
                    message: observationFeedback.message,
                    observation: observation,
                    delta: nil
                ))
                if let orientationFeedback = readOnlyOrientationLoopFeedback(
                    toolCall: toolCall,
                    observation: observation,
                    streak: &readOnlyOrientationStreak
                ) {
                    if !orientationFeedback.shouldStop {
                        forceActionOnlyTools = true
                    }
                    priorResults.append(readOnlyOrientationOutcome(
                        step: step,
                        toolCall: toolCall,
                        message: orientationFeedback.message,
                        observation: observation
                    ))
                    traceEvents.append(traceEvent(
                        kind: orientationFeedback.shouldStop ? "no_progress" : "planner_repair",
                        title: orientationFeedback.shouldStop ? "No progress" : "Action required",
                        body: orientationFeedback.message,
                        status: orientationFeedback.shouldStop ? "no_progress" : "repair",
                        step: step
                    ))
                    if orientationFeedback.shouldStop {
                        return .init(status: .noProgress, message: orientationFeedback.message, traceEvents: traceEvents)
                    }
                }
                if let blocked = observationFeedback.blocked {
                    traceEvents.append(traceEvent(kind: "no_progress", title: "No progress", body: blocked, status: "no_progress", step: step))
                    return .init(status: .noProgress, message: blocked, traceEvents: traceEvents)
                }
                continue
            default:
                if isReadOnlyOrientationTool(toolCall.tool) {
                    unchangedActionCounts.removeAll()
                } else {
                    forceActionOnlyTools = false
                    readOnlyOrientationStreak.reset()
                    unchangedObservationCounts.removeAll()
                }
                onStatus(statusTitle(for: toolCall))
                traceEvents.append(traceEvent(
                    kind: "tool_call",
                    title: "Executing",
                    body: executionTraceBody(toolCall: toolCall, observation: observation),
                    status: "executing",
                    step: step,
                    debugPayload: encodedDebugPayload(toolCall)
                ))
                let beforeObservation = observation
                let result = await execute(toolCall, registry)
                traceEvents.append(traceEvent(
                    kind: "tool_result",
                    title: "Tool result",
                    body: toolResultDisplayMessage(result),
                    status: "\(result.status)",
                    step: step,
                    debugPayload: encodedDebugPayload(TraceToolResultPayload(result))
                ))

                if Task.isCancelled || result.status == .cancelled {
                    return cancelledResult(traceEvents: traceEvents, step: step)
                }

                switch result.status {
                case .executed:
                    if let resultTitle = resultStatusTitle(for: toolCall, result: result) {
                        onStatus(resultTitle)
                    }
                    var delta: ComputerUseStateDelta?
                    if toolCall.isMutating {
                        onStatus("Observing screen")
                        observation = observe(registry, true, currentTarget)
                        traceEvents.append(observationEvent(observation, step: step, currentTarget: currentTarget))
                        delta = stateDelta(
                            before: beforeObservation,
                            after: observation,
                            toolCall: toolCall,
                            result: result
                        )
                    }
                    let outcomeMessage = verifiedOutcomeMessage(
                        base: recoverableFallbackMessage(for: toolCall, result: result) ?? result.message,
                        delta: delta,
                        transaction: result.transaction
                    )
                    priorResults.append(outcome(
                        step: step,
                        toolCall: toolCall,
                        result: result,
                        message: outcomeMessage,
                        observation: observation,
                        delta: delta
                    ))
                    if let feedback = readOnlyOrientationLoopFeedback(
                        toolCall: toolCall,
                        observation: observation,
                        streak: &readOnlyOrientationStreak
                    ) {
                        if !feedback.shouldStop {
                            forceActionOnlyTools = true
                        }
                        priorResults.append(readOnlyOrientationOutcome(
                            step: step,
                            toolCall: toolCall,
                            message: feedback.message,
                            observation: observation
                        ))
                        traceEvents.append(traceEvent(
                            kind: feedback.shouldStop ? "no_progress" : "planner_repair",
                            title: feedback.shouldStop ? "No progress" : "Action required",
                            body: feedback.message,
                            status: feedback.shouldStop ? "no_progress" : "repair",
                            step: step
                        ))
                        if feedback.shouldStop {
                            return .init(status: .noProgress, message: feedback.message, traceEvents: traceEvents)
                        }
                    }
                    if let blocked = repeatedUnchangedMessage(
                        toolCall: toolCall,
                        delta: delta,
                        counts: &unchangedActionCounts
                    ) {
                        traceEvents.append(traceEvent(kind: "no_progress", title: "No progress", body: blocked, status: "no_progress", step: step))
                        return .init(status: .noProgress, message: blocked, traceEvents: traceEvents)
                    }
                    updatePendingUnverifiedTextWrites(
                        &pendingUnverifiedTextWrites,
                        toolCall: toolCall,
                        delta: delta,
                        before: beforeObservation,
                        screenshotOCRTextByID: screenshotOCRTextByID,
                        step: step
                    )
                case .needsConfirmation:
                    priorResults.append(outcome(
                        step: step,
                        toolCall: toolCall,
                        result: result,
                        message: result.message,
                        observation: beforeObservation,
                        delta: nil
                    ))
                    traceEvents.append(traceEvent(kind: "confirm", title: "Confirmation required", body: result.message, status: "confirm", step: step))
                    return .init(status: .needsConfirmation, message: result.message, traceEvents: traceEvents)
                case .unsupported, .failed:
                    if let fallbackMessage = recoverableFallbackMessage(for: toolCall, result: result) {
                    priorResults.append(outcome(
                        step: step,
                        toolCall: toolCall,
                        result: result,
                        message: fallbackMessage,
                        observation: beforeObservation,
                        delta: nil
                    ))
                    let fallbackTitle = recoverableFallbackTitle(for: toolCall, result: result)
                    onStatus(fallbackTitle)
                    traceEvents.append(traceEvent(
                        kind: "fallback",
                        title: fallbackTitle,
                        body: fallbackMessage,
                        status: "fallback",
                        step: step
                        ))
                        onStatus("Observing screen")
                        observation = observe(registry, true, currentTarget)
                        traceEvents.append(observationEvent(observation, step: step, currentTarget: currentTarget))
                        continue
                    }
                    priorResults.append(outcome(
                        step: step,
                        toolCall: toolCall,
                        result: result,
                        message: result.message,
                        observation: beforeObservation,
                        delta: nil
                    ))
                    traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: result.message, status: "failed", step: step))
                    return .init(status: .failed, message: result.message, traceEvents: traceEvents)
                case .cancelled:
                    return cancelledResult(traceEvents: traceEvents, step: step)
                }
            }
        }
    }

    private func cancelledResult(traceEvents: [ComputerUseTraceEvent], step: Int) -> ComputerUsePlannerRuntimeResult {
        var events = traceEvents
        events.append(traceEvent(kind: "cancelled", title: "Cancelled", body: "CUA cancelled", status: "cancelled", step: step))
        return .init(status: .cancelled, message: "CUA cancelled", traceEvents: events)
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        return "\(seconds) seconds"
    }

    private func windowState(
        for observation: ComputerUseObservation,
        screenshotOCRTextByID: inout [String: String]
    ) async -> ComputerUseWindowState {
        guard let screenshot = observation.screenshot else {
            return ComputerUseWindowState(observation: observation)
        }
        if let cached = screenshotOCRTextByID[screenshot.screenshotID] {
            return ComputerUseWindowState(observation: observation, screenshotOCRText: cached)
        }
        return ComputerUseWindowState(observation: observation)
    }

    private func recognizeScreenshotTextTool(
        _ toolCall: ComputerUseToolCall,
        observation: ComputerUseObservation,
        screenshotOCRTextByID: inout [String: String]
    ) async -> ComputerUseExecutionResult {
        guard let screenshot = observation.screenshot else {
            return .failed("No current screenshot for OCR. Call get_window_state with screenshot first.")
        }
        guard toolCall.screenshotID == screenshot.screenshotID else {
            let requested = toolCall.screenshotID ?? ""
            return .failed("Stale screenshot_id \(requested); latest screenshot is \(screenshot.screenshotID). Call recognize_screenshot_text with the latest screenshot_id.")
        }
        if let cached = screenshotOCRTextByID[screenshot.screenshotID] {
            return .executed(computerUseOCRTraceReceipt(text: cached, screenshotID: screenshot.screenshotID, cached: true).message)
        }
        guard let recognized = await recognizeScreenshotText(screenshot) else {
            return .executed(computerUseOCRTraceReceipt(text: "", screenshotID: screenshot.screenshotID, cached: false).message)
        }
        let bounded = Self.boundedScreenshotOCRText(recognized)
        screenshotOCRTextByID[screenshot.screenshotID] = bounded
        return .executed(computerUseOCRTraceReceipt(text: bounded, screenshotID: screenshot.screenshotID, cached: false).message)
    }

    private static func boundedScreenshotOCRText(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return String(collapsed.prefix(2_000))
    }

    private func outcome(
        step: Int,
        toolCall: ComputerUseToolCall,
        result: ComputerUseExecutionResult,
        message: String,
        observation: ComputerUseObservation,
        delta: ComputerUseStateDelta?
    ) -> ComputerUseToolOutcome {
        ComputerUseToolOutcome(
            step: step,
            tool: toolCall.tool,
            status: "\(result.status)",
            message: message,
            appName: observation.appName,
            bundleID: observation.bundleID,
            windowTitle: observation.windowTitle,
            snapshotID: observation.screenshot?.screenshotID,
            verificationStatus: delta?.status,
            beforeStateID: delta?.beforeStateID,
            afterStateID: delta?.afterStateID,
            stateDelta: delta,
            transaction: result.transaction
        )
    }

    private func observationEvent(
        _ observation: ComputerUseObservation,
        step: Int?,
        currentTarget: ComputerUseObservationTarget?
    ) -> ComputerUseTraceEvent {
        let app = observation.appName.isEmpty ? "Unknown app" : observation.appName
        let window = observationWindowLabel(observation)
        var details = ["state \(observation.stateID)", "\(app) - \(window) - \(observation.elements.count) AX candidates"]
        if let screenshot = observation.screenshot {
            details.append("screenshot \(screenshot.screenshotID) \(screenshot.width)x\(screenshot.height)")
        } else if observation.appInstructions?.contains("Visual screenshot unavailable") == true {
            details.append("screenshot unavailable")
        }
        if let focused = observation.focusedElement {
            let text = focused.normalizedText.isEmpty ? focused.role : "\(focused.role) \(focused.normalizedText)"
            details.append("focused \(String(text.prefix(80)))")
        }
        if let selectedText = observation.selectedText, !selectedText.isEmpty {
            details.append("selected \(selectedText.count) chars")
        }
        if let cursor = observation.cursorPosition {
            details.append("cursor \(Int(cursor.x.rounded())),\(Int(cursor.y.rounded()))")
        }
        return traceEvent(
            kind: "observation",
            title: "Observation",
            body: details.joined(separator: " - "),
            status: "observed",
            step: step,
            debugPayload: encodedDebugPayload(ObservationTracePayload(
                state: ComputerUseWindowState(observation: observation),
                context: observationContext(for: observation, currentTarget: currentTarget)
            ))
        )
    }

    private func observationContext(
        for observation: ComputerUseObservation,
        currentTarget: ComputerUseObservationTarget?
    ) -> ComputerUseObservationContext {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostProcessID = frontmost.map { Int($0.processIdentifier) }
        let targetProcessID = observation.processID
        let isFrontmostTarget = targetProcessID != nil && targetProcessID == frontmostProcessID
        let userFrontmostState = frontmost.map {
            ComputerUseAppContextState(
                appName: $0.localizedName ?? "",
                bundleID: $0.bundleIdentifier ?? "",
                processID: Int($0.processIdentifier),
                isTargetApp: isFrontmostTarget
            )
        }
        let targetMatch = targetMatchDescription(observation: observation, currentTarget: currentTarget)
        let hasTargetIdentity = !observation.bundleID.isEmpty || observation.processID != nil || observation.windowID != nil
        let hasVisualOrAXState = observation.screenshot != nil || !observation.elements.isEmpty
        let usableForActions = observation.targetMismatch == nil && hasTargetIdentity && hasVisualOrAXState
        let keyboardFocus = keyboardFocusContext(observation: observation, isFrontmostTarget: isFrontmostTarget)
        var notes: [String] = []
        if config.computerUseInteractionMode == .quiet && !isFrontmostTarget && usableForActions {
            notes.append("The target window is not frontmost because Work quietly preserves the user's active app. This is expected; do not repeat observation only to make it frontmost.")
        }
        if observation.windowTitle.isEmpty && observation.windowID != nil && usableForActions {
            notes.append("The target window title is unavailable, but process_id/window_id plus screenshot/AX state identify a usable target window.")
        }
        if observation.targetMismatch != nil {
            notes.append("The requested target was not matched; re-orient before mutating this window.")
        }

        return ComputerUseObservationContext(
            controlMode: config.computerUseInteractionMode,
            userFrontmostState: userFrontmostState,
            targetWindowState: ComputerUseTargetContextState(
                appName: observation.appName,
                bundleID: observation.bundleID,
                processID: observation.processID,
                windowID: observation.windowID,
                windowTitle: observation.windowTitle,
                targetMatch: targetMatch,
                isFrontmost: isFrontmostTarget,
                hasScreenshot: observation.screenshot != nil,
                hasAXCandidates: !observation.elements.isEmpty,
                usableForActions: usableForActions
            ),
            keyboardFocusState: keyboardFocus,
            notes: notes
        )
    }

    private func targetMatchDescription(
        observation: ComputerUseObservation,
        currentTarget: ComputerUseObservationTarget?
    ) -> String {
        if observation.targetMismatch != nil {
            return "mismatch"
        }
        if currentTarget?.windowID != nil {
            return "requested_window_matched"
        }
        if observation.windowID != nil {
            return "current_window_identified"
        }
        if observation.screenshot != nil || !observation.elements.isEmpty {
            return "app_state_identified"
        }
        return "unknown"
    }

    private func keyboardFocusContext(
        observation: ComputerUseObservation,
        isFrontmostTarget: Bool
    ) -> ComputerUseKeyboardFocusContext {
        if let focused = observation.focusedElement {
            return ComputerUseKeyboardFocusContext(
                relationToTarget: "target_app",
                focusedElementProcessID: focused.processID,
                note: "Keyboard focus is inside the target app."
            )
        }
        if config.computerUseInteractionMode == .quiet && !isFrontmostTarget {
            return ComputerUseKeyboardFocusContext(
                relationToTarget: "user_frontmost_or_unknown",
                focusedElementProcessID: nil,
                note: "No target-app focused element was captured. In Work quietly mode this can be expected when the user's active app remains frontmost; use pid/window-scoped tools when target_window_state.usable_for_actions is true."
            )
        }
        return ComputerUseKeyboardFocusContext(
            relationToTarget: "unknown",
            focusedElementProcessID: nil,
            note: "No focused element was captured for the target app."
        )
    }

    private func observationWindowLabel(_ observation: ComputerUseObservation) -> String {
        if !observation.windowTitle.isEmpty {
            return observation.windowTitle
        }
        if let windowID = observation.windowID {
            return "target window_id \(windowID) (title unavailable)"
        }
        if observation.screenshot != nil || !observation.elements.isEmpty {
            return "target app state (no focused window title)"
        }
        return "No focused window"
    }

    private func stepLimitSuffix(_ maxSteps: Int?) -> String {
        maxSteps.map { " of \($0)" } ?? ""
    }

    private func stateDelta(
        before: ComputerUseObservation,
        after: ComputerUseObservation,
        toolCall: ComputerUseToolCall,
        result: ComputerUseExecutionResult
    ) -> ComputerUseStateDelta {
        if result.status != .executed {
            return ComputerUseStateDelta(
                status: .blocked,
                summary: result.message,
                beforeStateID: before.stateID,
                afterStateID: after.stateID
            )
        }
        if toolCall.tool != .launchApp,
           !before.bundleID.isEmpty,
           !after.bundleID.isEmpty,
           before.bundleID != after.bundleID {
            return ComputerUseStateDelta(
                status: .targetLost,
                summary: "Target app changed from \(before.appName) (\(before.bundleID)) to \(after.appName) (\(after.bundleID)); re-query state before acting again.",
                beforeStateID: before.stateID,
                afterStateID: after.stateID
            )
        }

        if isTextEntryTool(toolCall.tool), let text = toolCall.text {
            if let source = requestedTextObservationSource(before: before, after: after, text: text) {
                return ComputerUseStateDelta(
                    status: .changed,
                    summary: "Observed requested text in \(source) after \(toolCall.summary).",
                    beforeStateID: before.stateID,
                    afterStateID: after.stateID
                )
            }
            let status: ComputerUseVerificationStatus = observationSignature(before) == observationSignature(after) ? .unchanged : .unknown
            let summary: String
            if status == .unchanged {
                summary = "\(toolCall.summary) executed but AX did not expose newly confirmed requested text and no AX state change was observed. Inspect the latest screenshot: finish if the text is visibly present, otherwise refocus the editable target or use a different insertion primitive."
            } else {
                summary = "\(toolCall.summary) changed UI state, but AX did not expose newly confirmed requested text. Inspect the latest screenshot: finish if the text is visibly present, otherwise refocus or use another insertion primitive."
            }
            return ComputerUseStateDelta(
                status: status,
                summary: summary,
                beforeStateID: before.stateID,
                afterStateID: after.stateID
            )
        }

        let beforeSignature = observationSignature(before)
        let afterSignature = observationSignature(after)
        let status: ComputerUseVerificationStatus = beforeSignature == afterSignature ? .unchanged : .changed
        let summary: String
        if status == .changed {
            summary = "Observed UI state changed after \(toolCall.summary)."
        } else if isClickTool(toolCall.tool) {
            let route = result.diagnostics?["click_route"].map { " via \($0)" } ?? ""
            summary = "\(toolCall.summary) delivered\(route), but no relevant UI state change was observed. Treat this click route as ineffective for the visible target: refresh target state if stale, then use click with a different visible target or addressing mode."
        } else if toolCall.tool == .typeText || toolCall.tool == .pasteText || toolCall.tool == .setValue {
            summary = "\(toolCall.summary) executed but no focused value, selected text, or visible AX text change was observed. Inspect the latest screenshot and choose whether to finish, refocus, or retry."
        } else {
            summary = "\(toolCall.summary) executed but no relevant UI change was observed; choose a different strategy."
        }
        return ComputerUseStateDelta(
            status: status,
            summary: summary,
            beforeStateID: before.stateID,
            afterStateID: after.stateID
        )
    }

    private func isTextEntryTool(_ tool: ComputerUseToolName) -> Bool {
        tool == .typeText || tool == .pasteText
    }

    private func isClickTool(_ tool: ComputerUseToolName) -> Bool {
        tool == .click || tool == .clickElement || tool == .clickPoint
    }

    private func requestedTextObservationSource(
        before: ComputerUseObservation,
        after: ComputerUseObservation,
        text: String
    ) -> String? {
        guard let sample = textVerificationSample(text) else { return nil }
        if !textWriteEvidenceCorpus(before).contains(sample),
           textWriteEvidenceCorpus(after).contains(sample) {
            return "focused text or selected text"
        }
        return nil
    }

    private func updatePendingUnverifiedTextWrites(
        _ pending: inout [PendingUnverifiedTextWrite],
        toolCall: ComputerUseToolCall,
        delta: ComputerUseStateDelta?,
        before: ComputerUseObservation,
        screenshotOCRTextByID: [String: String],
        step: Int
    ) {
        guard isTextEntryTool(toolCall.tool), let text = toolCall.text else { return }
        if delta?.status == .changed {
            return
        }
        guard let sample = textVerificationSample(text) else {
            return
        }
        let preActionOCRText = before.screenshot.flatMap { screenshotOCRTextByID[$0.screenshotID] }
        let textEvidenceBefore = textWriteEvidenceCorpus(before)
        let visibleEvidenceBefore = observationTextCorpus(before)
        let preActionOCRSampleCount = preActionOCRText.map {
            sampleOccurrenceCount(sample, in: ComputerUseElementCandidate.normalizedText($0))
        }
        pending.append(PendingUnverifiedTextWrite(
            sample: sample,
            toolSummary: toolCall.summary,
            step: step,
            textEvidenceCountBefore: sampleOccurrenceCount(sample, in: textEvidenceBefore),
            visibleEvidenceCountBefore: sampleOccurrenceCount(sample, in: visibleEvidenceBefore),
            preActionOCRSampleCount: preActionOCRSampleCount
        ))
    }

    private func unverifiedTextWriteEvidenceMatch(
        _ pending: PendingUnverifiedTextWrite,
        observation: ComputerUseObservation,
        screenshotOCRTextByID: [String: String]
    ) -> TextWriteEvidenceMatch? {
        let textEvidenceCount = sampleOccurrenceCount(
            pending.sample,
            in: textWriteEvidenceCorpus(observation)
        )
        let newTextEvidenceCount = textEvidenceCount - pending.textEvidenceCountBefore
        if newTextEvidenceCount > 0 {
            return TextWriteEvidenceMatch(
                source: "focused text or selected text",
                availableCount: newTextEvidenceCount
            )
        }
        guard let screenshotID = observation.screenshot?.screenshotID,
              let ocrText = screenshotOCRTextByID[screenshotID] else {
            return nil
        }
        let normalizedOCR = ComputerUseElementCandidate.normalizedText(ocrText)
        let ocrCount = sampleOccurrenceCount(pending.sample, in: normalizedOCR)
        guard ocrCount > 0 else {
            return nil
        }
        if let preActionOCRSampleCount = pending.preActionOCRSampleCount {
            let newOCRCount = ocrCount - preActionOCRSampleCount
            guard newOCRCount > 0 else {
                return nil
            }
            return TextWriteEvidenceMatch(
                source: "new screenshot OCR text",
                availableCount: newOCRCount
            )
        }
        let newVisibleEvidenceCount = ocrCount - pending.visibleEvidenceCountBefore
        guard newVisibleEvidenceCount > 0 else {
            return nil
        }
        return TextWriteEvidenceMatch(
            source: "screenshot OCR text not present in pre-action visible evidence",
            availableCount: newVisibleEvidenceCount
        )
    }

    private func unresolvedPendingUnverifiedTextWrites(
        _ pending: [PendingUnverifiedTextWrite],
        observation: ComputerUseObservation,
        screenshotOCRTextByID: [String: String],
        consumedEvidenceCounts: inout [String: Int]
    ) -> [PendingUnverifiedTextWrite] {
        var unresolved: [PendingUnverifiedTextWrite] = []
        for write in pending {
            guard let evidence = unverifiedTextWriteEvidenceMatch(
                write,
                observation: observation,
                screenshotOCRTextByID: screenshotOCRTextByID
            ) else {
                unresolved.append(write)
                continue
            }
            let evidenceKey = "\(evidence.source)|\(write.sample)"
            let consumedCount = consumedEvidenceCounts[evidenceKey, default: 0]
            if consumedCount >= evidence.availableCount {
                unresolved.append(write)
            } else {
                consumedEvidenceCounts[evidenceKey] = consumedCount + 1
            }
        }
        return unresolved
    }

    private func sampleOccurrenceCount(_ sample: String, in corpus: String) -> Int {
        guard !sample.isEmpty, !corpus.isEmpty else { return 0 }
        var count = 0
        var searchStart = corpus.startIndex
        while searchStart < corpus.endIndex,
              let range = corpus.range(
                of: sample,
                options: [],
                range: searchStart..<corpus.endIndex
              ) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    private func textVerificationSample(_ text: String) -> String? {
        let tokens = ComputerUseElementCandidate.normalizedText(text)
            .split(separator: " ")
        guard !tokens.isEmpty else { return nil }
        return tokens.prefix(16).joined(separator: " ")
    }

    private func observationTextCorpus(_ observation: ComputerUseObservation) -> String {
        let focusedParts: [String] = if let focused = observation.focusedElement {
            [focused.title, focused.label, focused.value]
        } else {
            []
        }
        let elementParts = observation.elements.flatMap { element in
            [element.title, element.label, element.value, element.help]
        }
        return ComputerUseElementCandidate.normalizedText((
            [observation.windowTitle, observation.selectedText ?? ""]
                + focusedParts
                + elementParts
        ).joined(separator: " "))
    }

    private func textWriteEvidenceCorpus(_ observation: ComputerUseObservation) -> String {
        let focusedParts: [String] = if let focused = observation.focusedElement {
            [focused.value]
        } else {
            []
        }
        return ComputerUseElementCandidate.normalizedText((
            [observation.selectedText ?? ""] + focusedParts
        ).joined(separator: " "))
    }

    private func verifiedOutcomeMessage(
        base: String,
        delta: ComputerUseStateDelta?,
        transaction: ComputerUseActionTransaction?
    ) -> String {
        var message = base
        if let transaction {
            message += ". Delivery: \(transaction.summary)"
            if let warning = transaction.warning {
                message += ". Warning: \(warning)"
            }
            if let escalationHint = transaction.escalationHint {
                message += ". Next hint: \(escalationHint)"
            }
        }
        if let delta {
            message += ". Verification: \(delta.summary)"
        }
        return message
    }

    private func toolResultDisplayMessage(_ result: ComputerUseExecutionResult) -> String {
        guard let transaction = result.transaction else { return result.message }
        var message = "\(result.message)\nDelivery: \(transaction.summary)"
        if let warning = transaction.warning {
            message += "\nWarning: \(warning)"
        }
        if let escalationHint = transaction.escalationHint {
            message += "\nNext hint: \(escalationHint)"
        }
        return message
    }

    private func observationToolFeedback(
        before: ComputerUseObservation,
        after: ComputerUseObservation,
        toolCall: ComputerUseToolCall,
        result: ComputerUseExecutionResult,
        counts: inout [String: Int]
    ) -> (message: String, blocked: String?) {
        let base = recoverableFallbackMessage(for: toolCall, result: result) ?? result.message
        let key = repeatedActionKey(toolCall)
        guard observationSignature(before) == observationSignature(after) else {
            counts.removeValue(forKey: key)
            return (
                "\(base). Captured fresh state; continue from the visible AX/screenshot context.",
                nil
            )
        }

        let count = (counts[key] ?? 0) + 1
        counts[key] = count
        let screenshotGuidance = screenshotUnavailableGuidance(after)
        let message = "\(base). State is unchanged after \(toolCall.summary); \(screenshotGuidance)choose a concrete action now and do not call get_app_state/get_window_state again unless the target app or window changes."
        guard count >= maxUnchangedObservationLoops else {
            return (message, nil)
        }
        return (
            message,
            "CUA stopped repeated \(toolCall.summary) after \(maxUnchangedObservationLoops) unchanged observations with no intervening action. Choose a concrete action instead of observing again."
        )
    }

    private func readOnlyOrientationLoopFeedback(
        toolCall: ComputerUseToolCall,
        observation: ComputerUseObservation,
        streak: inout ReadOnlyOrientationStreak
    ) -> (message: String, shouldStop: Bool)? {
        guard isReadOnlyOrientationTool(toolCall.tool) else {
            streak.reset()
            return nil
        }
        guard hasUsableOrientationTarget(observation) else {
            streak.reset()
            return nil
        }

        let signature = readOnlyOrientationTargetSignature(observation)
        if streak.targetSignature == signature {
            streak.count += 1
        } else {
            streak.targetSignature = signature
            streak.count = 1
            streak.repairCount = 0
        }

        guard streak.count >= maxReadOnlyOrientationStepsBeforeRepair else {
            return nil
        }

        streak.repairCount += 1
        let message = readOnlyOrientationLoopMessage(
            toolCall: toolCall,
            observation: observation,
            count: streak.count
        )
        return (message, streak.repairCount > maxReadOnlyOrientationRepairs)
    }

    private func readOnlyOrientationOutcome(
        step: Int,
        toolCall: ComputerUseToolCall,
        message: String,
        observation: ComputerUseObservation
    ) -> ComputerUseToolOutcome {
        ComputerUseToolOutcome(
            step: step,
            tool: toolCall.tool,
            status: "read_only_loop",
            message: message,
            appName: observation.appName,
            bundleID: observation.bundleID,
            windowTitle: observation.windowTitle,
            snapshotID: observation.screenshot?.screenshotID
        )
    }

    private func readOnlyOrientationLoopMessage(
        toolCall: ComputerUseToolCall,
        observation: ComputerUseObservation,
        count: Int
    ) -> String {
        let app = observation.appName.isEmpty ? "the current app" : observation.appName
        let window = observationWindowLabel(observation)
        var targetDetails: [String] = []
        if let processID = observation.processID {
            targetDetails.append("process_id \(processID)")
        }
        if let windowID = observation.windowID {
            targetDetails.append("window_id \(windowID)")
        }
        if let screenshotID = observation.screenshot?.screenshotID {
            targetDetails.append("screenshot_id \(screenshotID)")
        }
        let targetSuffix = targetDetails.isEmpty ? "" : " (\(targetDetails.joined(separator: ", ")))"
        let quietSuffix = config.computerUseInteractionMode == .quiet ? " If the target is not frontmost but has usable screenshot/AX state, that is expected in Work quietly mode and is not a reason to observe again." : ""
        return "No concrete action has been taken after \(count) read-only orientation steps on \(app) - \(window)\(targetSuffix). You already have current window state.\(quietSuffix) Choose one concrete action now, such as click, paste_text, press_key, or scroll; or use finish/fail. Do not call another read-only orientation tool unless the target app/window changed or a tool result explicitly says the state is stale. Last orientation tool: \(toolCall.tool.rawValue)."
    }

    private func hasUsableOrientationTarget(_ observation: ComputerUseObservation) -> Bool {
        let hasVisualOrAXState = observation.screenshot != nil || !observation.elements.isEmpty
        let hasTargetIdentity = !observation.bundleID.isEmpty || observation.processID != nil || observation.windowID != nil
        return hasVisualOrAXState && hasTargetIdentity
    }

    private func readOnlyOrientationTargetSignature(_ observation: ComputerUseObservation) -> String {
        [
            observation.bundleID,
            observation.processID.map(String.init) ?? "",
            observation.windowID.map(String.init) ?? "",
            observation.windowTitle,
            observation.screenshot.map { rectSignature($0.windowFrame) } ?? "",
        ].joined(separator: "|")
    }

    private func isReadOnlyOrientationTool(_ tool: ComputerUseToolName) -> Bool {
        switch tool {
        case .listWindows, .listBrowserTabs, .getAppState, .getWindowState:
            return true
        default:
            return false
        }
    }

    private func repeatedUnchangedMessage(
        toolCall: ComputerUseToolCall,
        delta: ComputerUseStateDelta?,
        counts: inout [String: Int]
    ) -> String? {
        guard shouldTrackForRepetition(toolCall.tool), let delta else { return nil }
        let key = repeatedActionKey(toolCall)
        guard delta.status == .unchanged else {
            if delta.status == .changed {
                counts.removeAll()
            } else {
                counts.removeValue(forKey: key)
            }
            return nil
        }
        let count = (counts[key] ?? 0) + 1
        counts[key] = count
        guard count >= 2 else { return nil }
        return "CUA stopped repeated \(toolCall.summary) after two unchanged attempts: no relevant UI change was observed. Choose a different strategy after running get_app_state."
    }

    private func screenshotUnavailableGuidance(_ observation: ComputerUseObservation) -> String {
        guard observation.screenshot == nil,
              let instructions = observation.appInstructions,
              instructions.contains("Visual screenshot unavailable") else {
            return ""
        }
        return "Visual screenshot is unavailable, so screenshot-coordinate click cannot be planned from this state. Use available AX/browser evidence if sufficient, or fail with the screenshot/Screen Recording reason; "
    }

    private func repeatedActionKey(_ toolCall: ComputerUseToolCall) -> String {
        let parts: [String] = [
            toolCall.tool.rawValue,
            toolCall.elementID ?? "",
            toolCall.elementIndex.map(String.init) ?? "",
            toolCall.appName ?? "",
            toolCall.canonicalBundleID,
            toolCall.label ?? "",
            toolCall.actionName ?? "",
            toolCall.key ?? "",
            toolCall.text ?? "",
            toolCall.value ?? "",
            toolCall.url ?? "",
            toolCall.direction?.rawValue ?? "",
            toolCall.screenshotID ?? "",
            toolCall.x.map { String($0) } ?? "",
            toolCall.y.map { String($0) } ?? "",
        ]
        return parts.joined(separator: "|")
    }

    private func finishIndicatesFailure(_ reason: String) -> Bool {
        let lowered = reason
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
        let failurePatterns = [
            #"^\s*(blocked|failed|unsupported|incomplete|not completed?)\s*[.!]?\s*$"#,
            #"\b(requires|needs)\s+confirmation\b"#,
            #"\b(task|request|command|workflow)\s+(is\s+)?(blocked|incomplete|not completed?|failed|unsupported)\b"#,
            #"\b(cannot|can't|could not|couldn't|unable to|was not able to)\s+(complete|finish|perform|do|continue|proceed|access|open|click|type|paste|navigate|find)\b"#,
            #"\b(did not|didn't)\s+(complete|finish|perform|send|post|open|click|type|paste|navigate|find)\b"#,
            #"\b(permission|permissions)\s+(required|needed|denied|missing|not granted)\b"#,
            #"\b(not authorized|not allowed|access denied)\b"#,
            #"\bfailed to\s+(complete|finish|perform|open|click|type|paste|navigate|send|post)\b"#,
        ]
        return failurePatterns.contains { pattern in
            lowered.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func shouldTrackForRepetition(_ tool: ComputerUseToolName) -> Bool {
        switch tool {
        case .moveCursor, .click, .clickElement, .clickPoint, .focusElement, .activateFocused, .performSecondaryAction, .drag, .pressKey, .hotkey, .typeText, .pasteText, .setValue, .scroll, .navigateURL, .navigateActiveBrowserTab, .openNewBrowserTab, .activateBrowserTab:
            return true
        case .listApps, .launchApp, .listWindows, .getAppState, .getWindowState, .recognizeScreenshotText, .listBrowserTabs, .pageGetText, .pageQueryDOM, .finish, .fail:
            return false
        }
    }

    private func targetMismatchMutationMessage(
        observation: ComputerUseObservation,
        toolCall: ComputerUseToolCall
    ) -> String? {
        guard let mismatch = observation.targetMismatch,
              requiresMatchedWindow(for: toolCall.tool) else {
            return nil
        }
        let actual = mismatch.actualWindowID.map { "focused window_id \($0)" } ?? "the focused window without a stable window_id"
        return "Cannot run \(toolCall.tool.rawValue): latest_window_state.target_mismatch says requested window_id \(mismatch.requestedWindowID.map(String.init) ?? "unknown") was not matched and state fell back to \(actual). Re-orient with list_windows/get_window_state for the intended or actual visible window before acting or finishing."
    }

    private func requiresMatchedWindow(for tool: ComputerUseToolName) -> Bool {
        if tool == .fail {
            return false
        }
        if tool == .finish {
            return true
        }
        if ComputerUseToolInvocation(tool: tool).isMutating {
            return true
        }
        return ComputerUseToolRegistry.executionContract(for: tool).requiresMatchedVisualTarget
    }

    private func target(from toolCall: ComputerUseToolCall, fallback: ComputerUseObservationTarget?) -> ComputerUseObservationTarget? {
        if !toolCall.canonicalBundleID.isEmpty {
            return ComputerUseObservationTarget(
                appName: toolCall.appName,
                bundleID: toolCall.canonicalBundleID,
                processID: toolCall.processID,
                windowID: toolCall.windowID
            )
        }
        if let appName = toolCall.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
            return ComputerUseObservationTarget(
                appName: appName,
                bundleID: nil,
                processID: toolCall.processID,
                windowID: toolCall.windowID
            )
        }
        if toolCall.processID != nil || toolCall.windowID != nil {
            return ComputerUseObservationTarget(
                appName: fallback?.appName,
                bundleID: fallback?.bundleID,
                processID: toolCall.processID ?? fallback?.processID,
                windowID: toolCall.windowID ?? fallback?.windowID
            )
        }
        switch toolCall.tool {
        case .moveCursor, .click, .clickElement, .clickPoint, .focusElement, .activateFocused, .performSecondaryAction, .setValue, .typeText, .pasteText, .pressKey, .hotkey, .scroll, .drag:
            return fallback
        default:
            return nil
        }
    }

    private func observationSignature(_ observation: ComputerUseObservation) -> String {
        let screenshot = observation.screenshot.map { screenshot in
            [
                "\(screenshot.width)x\(screenshot.height)",
                rectSignature(screenshot.windowFrame),
            ].joined(separator: "@")
        } ?? ""
        let elementSignature = observation.elements.prefix(16).map { element in
            [
                "\(element.elementIndex)",
                element.role,
                element.normalizedText,
                element.frame.map(rectSignature) ?? "",
            ].joined(separator: ":")
        }.joined(separator: ";")
        return [
            observation.bundleID,
            observation.appName,
            observation.windowTitle,
            "\(observation.elements.count)",
            observation.focusedElement?.normalizedText ?? "",
            observation.selectedText ?? "",
            screenshot,
            elementSignature,
        ].joined(separator: "|")
    }

    private func rectSignature(_ rect: ComputerUseRect) -> String {
        [
            Int(rect.x.rounded()),
            Int(rect.y.rounded()),
            Int(rect.width.rounded()),
            Int(rect.height.rounded()),
        ].map(String.init).joined(separator: ",")
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

    private func resultStatusTitle(
        for toolCall: ComputerUseToolCall,
        result: ComputerUseExecutionResult
    ) -> String? {
        guard result.status == .executed else { return nil }
        switch toolCall.tool {
        case .launchApp:
            return result.message.hasPrefix("Opened") ? result.message : "Opened app"
        case .click, .clickElement, .clickPoint:
            return result.message.hasPrefix("Clicked") ? result.message : "Clicked"
        case .focusElement:
            return result.message.hasPrefix("Focused") ? result.message : "Focused"
        case .activateFocused:
            return result.message.hasPrefix("Activated") ? result.message : "Activated focus"
        case .performSecondaryAction:
            return "Performed action"
        case .moveCursor:
            return "Moving cursor"
        case .typeText:
            return "Typed text"
        case .pasteText:
            return "Pasted text"
        case .openNewBrowserTab:
            return "Opened new tab"
        case .navigateURL, .navigateActiveBrowserTab:
            return "Navigated"
        case .pressKey, .hotkey:
            return "Pressed key"
        case .scroll:
            return "Scrolled"
        case .setValue:
            return "Set value"
        case .drag:
            return "Dragged"
        case .activateBrowserTab:
            return "Switched tab"
        default:
            return nil
        }
    }

    private func statusTitle(for toolCall: ComputerUseToolCall) -> String {
        switch toolCall.tool {
        case .launchApp:
            let target = toolCall.appName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Opening \(target?.isEmpty == false ? target! : "app")"
        case .click, .clickElement, .clickPoint:
            return "Clicking"
        case .focusElement:
            return "Focusing"
        case .activateFocused:
            return "Activating focus"
        case .performSecondaryAction:
            return "Performing action"
        case .moveCursor:
            return toolCall.label?.isEmpty == false ? "Moving to \(toolCall.label!)" : "Moving cursor"
        case .setValue:
            return "Setting value"
        case .typeText:
            return "Typing"
        case .pasteText:
            return "Pasting"
        case .pressKey, .hotkey:
            return "Pressing key"
        case .scroll:
            return "Scrolling"
        case .drag:
            return "Dragging"
        case .openNewBrowserTab:
            return "Opening new tab"
        case .navigateURL, .navigateActiveBrowserTab:
            return "Navigating"
        case .activateBrowserTab:
            return "Switching tab"
        case .listApps, .listWindows, .listBrowserTabs, .pageGetText, .pageQueryDOM, .recognizeScreenshotText:
            return "Reading"
        case .getAppState, .getWindowState:
            return "Observing"
        case .finish:
            return "Done"
        case .fail:
            return "Failed"
        }
    }

    private func planWithRetry(
        _ request: ComputerUsePlannerRequest,
        traceEvents: inout [ComputerUseTraceEvent]
    ) async throws -> ComputerUsePlannerResponse {
        var attempt = 0
        while true {
            onStatus("Planning step \(request.step)")
            traceEvents.append(traceEvent(
                kind: "planning",
                title: "Planning",
                body: "Step \(request.step)\(stepLimitSuffix(request.maxSteps)). Prior tool results: \(request.priorOutcomes.count).",
                status: "planning",
                step: request.step,
                debugPayload: encodedDebugPayload(TracePlannerRequestPayload(request))
            ))
            do {
                return try await plan(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < maxPlannerRetryCount, isRecoverablePlannerError(error) else {
                    throw error
                }
                attempt += 1
                let message = "Planner request failed transiently: \(error.localizedDescription). Retrying once."
                onStatus("Retrying planner")
                traceEvents.append(traceEvent(
                    kind: "planner_retry",
                    title: "Planner retry",
                    body: message,
                    status: "retrying",
                    step: request.step
                ))
                try await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    private func isRecoverablePlannerError(_ error: Error) -> Bool {
        if let plannerError = error as? ComputerUsePlannerError {
            switch plannerError {
            case .requestFailed:
                return true
            case .backendFailed(let statusCode, _):
                return statusCode == 408 || statusCode == 429 || statusCode >= 500
            case .notAuthenticated, .invalidResponse, .invalidToolCall:
                return false
            }
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("network connection was lost")
            || message.contains("timed out")
            || message.contains("connection reset")
            || message.contains("could not be reached")
    }

    private func recoverableFallbackMessage(
        for toolCall: ComputerUseToolCall,
        result: ComputerUseExecutionResult
    ) -> String? {
        guard result.status == .failed || result.status == .unsupported else { return nil }
        let message = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if browserToolCanFallBackToScreen(toolCall.tool), isBrowserAutomationPermissionFailure(message) {
            return "\(message). Continue with get_window_state and visual screenshot actions. For browser pages, use click on reliable AX candidates or visible screenshot targets, plus press_key, paste_text, and scroll. Treat generic AX candidates as optional hints; avoid repeated focus cycles on generic web areas, action menus, or search results. Do not retry browser helpers unless the user grants Chrome Apple Events JavaScript permission."
        }
        if (toolCall.tool == .typeText || toolCall.tool == .pasteText), isTextFocusFailure(message) {
            return "\(message). Continue from the fresh screenshot/state. If the visible editor is a rich web or canvas-backed surface, use click to place the caret, then use paste_text guarded by process_id/window_id or current focus. Use AX element_index/element_id only when the editable target is clearly exposed and stable. Do not repeat the same text entry call against the same failed target."
        }
        if (toolCall.tool == .typeText || toolCall.tool == .pasteText), isUnconfirmedAXSelectedTextWrite(message) {
            return "\(message). Capture fresh state and inspect the visible editor before choosing the next step. If the requested text is visible, finish. If it is absent, use a different insertion route or refocus before retrying. Do not immediately repeat the same text entry call against the same target."
        }
        if isStaleScopedTargetFailure(message) {
            return "\(message). Treat the element/process/window identity as stale, not as task failure. Refresh with get_window_state for the intended app/window or list_windows if the intended window is ambiguous, then choose a target from the fresh state. Do not reuse the stale element_index, element_id, or window_id."
        }
        return nil
    }

    private func recoverableFallbackTitle(
        for toolCall: ComputerUseToolCall,
        result: ComputerUseExecutionResult
    ) -> String {
        let message = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if (toolCall.tool == .typeText || toolCall.tool == .pasteText),
           isUnconfirmedAXSelectedTextWrite(message) {
            return "Text write unverified"
        }
        return "Screen fallback"
    }

    private func browserToolCanFallBackToScreen(_ tool: ComputerUseToolName) -> Bool {
        switch tool {
        case .listBrowserTabs, .activateBrowserTab, .openNewBrowserTab, .navigateURL, .navigateActiveBrowserTab, .pageGetText, .pageQueryDOM:
            return true
        default:
            return false
        }
    }

    private func isBrowserAutomationPermissionFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("apple events")
            || lowered.contains("javascript permission")
            || lowered.contains("not allowed")
            || lowered.contains("not authorized")
            || lowered.contains("automation")
    }

    private func isTextFocusFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("no focused editable text target")
            || lowered.contains("not an editable text target")
            || lowered.contains("focused element no longer matches requested text target")
            || lowered.contains("focus moved within the target process")
            || lowered.contains("focus moved to process")
    }

    private func isUnconfirmedAXSelectedTextWrite(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("axselectedtext accepted the write")
            && lowered.contains("readback did not confirm")
    }

    private func isStaleScopedTargetFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("refresh state before using this element")
            || lowered.contains("stale or unknown element_index")
            || lowered.contains("stale or unknown element_id")
            || lowered.contains("stale window_id")
            || lowered.contains("stale process_id")
    }

    private func executionTraceBody(toolCall: ComputerUseToolCall, observation: ComputerUseObservation) -> String {
        let target = [
            observation.appName,
            observation.bundleID,
            observation.windowTitle,
            observation.screenshot?.screenshotID ?? "",
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " - ")
        return "\(toolCall.summary)\nTarget: \(target.isEmpty ? "unknown" : target)\nArguments:\n\(formatToolCall(toolCall))"
    }

    private func traceEvent(
        kind: String,
        title: String,
        body: String,
        status: String?,
        step: Int?,
        debugPayload: String? = nil
    ) -> ComputerUseTraceEvent {
        ComputerUseTraceEvent(kind: kind, title: title, body: body, status: status, step: step, debugPayload: debugPayload)
    }

    private func encodedDebugPayload<T: Encodable>(_ value: T, limit: Int = 60_000) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        guard text.count > limit else {
            return text
        }
        return String(text.prefix(limit)) + "\n... truncated"
    }
}

private struct TracePlannerRequestPayload: Codable {
    let command: String
    let step: Int
    let maxSteps: Int?
    let toolCatalogVersion: String
    let latestWindowState: ComputerUseWindowState
    let ocrMetadataByScreenshotID: [String: OCRTraceReceipt]
    let observationContext: ComputerUseObservationContext
    let priorOutcomes: [ComputerUseToolOutcome]

    enum CodingKeys: String, CodingKey {
        case command
        case step
        case maxSteps = "max_steps"
        case toolCatalogVersion = "tool_catalog_version"
        case latestWindowState = "latest_window_state"
        case ocrMetadataByScreenshotID = "screenshot_ocr_metadata_by_id"
        case observationContext = "observation_context"
        case priorOutcomes = "prior_tool_outcomes"
    }

    init(_ request: ComputerUsePlannerRequest) {
        command = request.command
        step = request.step
        maxSteps = request.maxSteps
        toolCatalogVersion = request.toolCatalogVersion
        let redactedOCR = Self.redactedOCRWindowState(request.latestWindowState)
        latestWindowState = redactedOCR.state
        ocrMetadataByScreenshotID = redactedOCR.metadataByScreenshotID
        observationContext = request.observationContext
        priorOutcomes = request.priorOutcomes
    }

    private static func redactedOCRWindowState(
        _ state: ComputerUseWindowState
    ) -> (state: ComputerUseWindowState, metadataByScreenshotID: [String: OCRTraceReceipt]) {
        guard let ocrText = state.screenshotOCRText else {
            return (state, [:])
        }
        let screenshotID = state.screenshot?.screenshotID ?? ""
        let receipt = computerUseOCRTraceReceipt(
            text: ocrText,
            screenshotID: screenshotID,
            cached: true
        )
        let redactedState = ComputerUseWindowState(
            stateID: state.stateID,
            appName: state.appName,
            bundleID: state.bundleID,
            processID: state.processID,
            windowID: state.windowID,
            windowTitle: state.windowTitle,
            windowFrame: state.windowFrame,
            screenshot: state.screenshot,
            screenshotOCRText: nil,
            cursorPosition: state.cursorPosition,
            focusedElement: state.focusedElement,
            selectedText: state.selectedText,
            appInstructions: state.appInstructions,
            targetMismatch: state.targetMismatch,
            elements: state.elements,
            capturedAt: state.capturedAt
        )
        return (redactedState, screenshotID.isEmpty ? [:] : [screenshotID: receipt])
    }
}

private struct ObservationTracePayload: Codable {
    let state: ComputerUseWindowState
    let context: ComputerUseObservationContext
}

private struct OCRTraceReceipt: Codable, Equatable {
    let screenshotID: String
    let textPresent: Bool
    let characterCount: Int
    let lineCount: Int
    let normalizedSHA256: String
    let cached: Bool

    enum CodingKeys: String, CodingKey {
        case screenshotID = "screenshot_id"
        case textPresent = "text_present"
        case characterCount = "character_count"
        case lineCount = "line_count"
        case normalizedSHA256 = "normalized_sha256"
        case cached
    }

    var message: String {
        if !textPresent {
            return "OCR completed for screenshot \(screenshotID): no text recognized. Text withheld from trace history."
        }
        let source = cached ? "cached " : ""
        return "OCR completed for \(source)screenshot \(screenshotID): \(characterCount) chars, \(lineCount) lines, sha256 \(normalizedSHA256). Text withheld from trace history."
    }
}

private func computerUseOCRTraceReceipt(
    text: String,
    screenshotID: String,
    cached: Bool
) -> OCRTraceReceipt {
    let lines = text
        .split(whereSeparator: \.isNewline)
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .count
    let digest = SHA256.hash(data: Data(ComputerUseElementCandidate.normalizedText(text).utf8))
    let hash = digest.map { String(format: "%02x", $0) }.joined()
    return OCRTraceReceipt(
        screenshotID: screenshotID,
        textPresent: !text.isEmpty,
        characterCount: text.count,
        lineCount: lines,
        normalizedSHA256: hash,
        cached: cached
    )
}

private struct TraceToolResultPayload: Codable {
    let status: String
    let message: String
    let diagnostics: [String: String]?
    let transaction: ComputerUseActionTransaction?

    init(_ result: ComputerUseExecutionResult) {
        status = "\(result.status)"
        message = result.message
        diagnostics = result.diagnostics
        transaction = result.transaction
    }
}
