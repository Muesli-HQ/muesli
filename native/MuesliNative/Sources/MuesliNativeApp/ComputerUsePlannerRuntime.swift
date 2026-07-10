import Foundation
import MuesliCore

struct ComputerUsePlannerRuntimeResult: Equatable {
    enum Status: Equatable {
        case done
        case timedOut
        case needsConfirmation
        case failed
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

    private let config: AppConfig
    private let maxSteps: Int?
    private let timeoutSeconds: TimeInterval
    private let registry = ComputerUseElementRegistry()
    private let onStatus: StatusHandler
    private let observe: ObserveHandler
    private let plan: PlanHandler
    private let execute: ExecuteHandler
    private let maxPlannerRetries = 1

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
        execute: @escaping ExecuteHandler = { toolCall, registry in
            await ComputerUseToolExecutor.execute(toolCall, registry: registry)
        }
    ) {
        self.config = config
        self.maxSteps = maxSteps
        self.timeoutSeconds = timeoutSeconds ?? TimeInterval(max(config.computerUseTimeoutSeconds, 1))
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
        var priorResults: [ComputerUseToolOutcome] = []
        var invalidToolCallRepairCount = 0
        let maxInvalidToolCallRepairs = 2
        // V1 keeps foreground activation, but state is scoped to a target app.
        // Later Codex-style work should replace this with background key-window tracking,
        // synthetic focus enforcement, and user-frontmost-app preservation.
        var currentTarget: ComputerUseObservationTarget?

        onStatus("Observing screen")
        var observation = observe(registry, true, currentTarget)
        traceEvents.append(observationEvent(observation, step: nil))
        var plannerHistory = [
            ComputerUsePlannerHistoryItem(kind: .userCommand, summary: command),
            observationHistoryItem(observation, step: nil),
        ]

        var step = 1
        while true {
            if Task.isCancelled {
                return cancelledResult(traceEvents: traceEvents, step: step)
            }
            if Date() >= deadline {
                traceEvents.append(traceEvent(kind: "timed_out", title: "Timed out", body: "CUA timed out", status: "timed_out", step: step))
                return .init(status: .timedOut, message: "CUA timed out", traceEvents: traceEvents)
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
                latestWindowState: ComputerUseWindowState(observation: observation),
                plannerHistory: plannerHistory,
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
                plannerHistory.append(ComputerUsePlannerHistoryItem(
                    kind: .plannerRepair,
                    step: step,
                    status: "invalid_schema",
                    summary: "Invalid tool \(name): \(message)"
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

            let toolCall = response.toolCall
            invalidToolCallRepairCount = 0
            plannerHistory.append(ComputerUsePlannerHistoryItem(
                kind: .modelToolCall,
                step: step,
                tool: toolCall.tool,
                status: "planned",
                summary: historyToolSummary(toolCall)
            ))
            if let target = target(from: toolCall, fallback: currentTarget) {
                currentTarget = target
            }
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
            if toolCall.requiresConfirmation {
                onStatus("Confirm")
                let message = "Confirm: \(toolCall.summary)"
                traceEvents.append(traceEvent(kind: "confirm", title: "Confirmation required", body: message, status: "confirm", step: step))
                return .init(status: .needsConfirmation, message: message, traceEvents: traceEvents)
            }

            switch toolCall.tool {
            case .finish:
                onStatus("Done")
                let message = toolCall.reason?.isEmpty == false ? toolCall.reason! : "Done"
                traceEvents.append(traceEvent(kind: "finish", title: "Final output", body: message, status: "done", step: step))
                return .init(status: .done, message: message, traceEvents: traceEvents)
            case .fail:
                onStatus("Failed")
                let message = toolCall.reason?.isEmpty == false ? toolCall.reason! : "Failed"
                traceEvents.append(traceEvent(kind: "failed", title: "Final output", body: message, status: "failed", step: step))
                return .init(status: .failed, message: message, traceEvents: traceEvents)
            case .getAppState, .getWindowState:
                onStatus("Observing screen")
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
                        observation: observation,
                        delta: nil
                    ))
                    traceEvents.append(traceEvent(kind: "failed", title: "Failed", body: result.message, status: "failed", step: step))
                    return .init(status: .failed, message: result.message, traceEvents: traceEvents)
                }
                onStatus("Observing screen")
                observation = observe(registry, true, currentTarget)
                traceEvents.append(observationEvent(observation, step: step))
                let recordedOutcome = outcome(
                    step: step,
                    toolCall: toolCall,
                    result: result,
                    message: result.message,
                    observation: observation,
                    delta: nil
                )
                priorResults.append(recordedOutcome)
                plannerHistory.append(outcomeHistoryItem(recordedOutcome))
                plannerHistory.append(observationHistoryItem(observation, step: step))
                continue
            default:
                onStatus(statusTitle(for: toolCall))
                traceEvents.append(traceEvent(
                    kind: "tool_call",
                    title: "Executing",
                    body: executionTraceBody(toolCall: toolCall, observation: observation),
                    status: "executing",
                    step: step
                ))
                let beforeObservation = observation
                let result = await execute(toolCall, registry)
                traceEvents.append(traceEvent(
                    kind: "tool_result",
                    title: "Tool result",
                    body: result.message,
                    status: "\(result.status)",
                    step: step
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
                        traceEvents.append(observationEvent(observation, step: step))
                        delta = stateDelta(
                            before: beforeObservation,
                            after: observation,
                            toolCall: toolCall,
                            result: result
                        )
                    }
                    let outcomeMessage = verifiedOutcomeMessage(
                        base: recoverableFallbackMessage(for: toolCall, result: result) ?? result.message,
                        delta: delta
                    )
                    let recordedOutcome = outcome(
                        step: step,
                        toolCall: toolCall,
                        result: result,
                        message: outcomeMessage,
                        observation: observation,
                        delta: delta
                    )
                    priorResults.append(recordedOutcome)
                    plannerHistory.append(outcomeHistoryItem(recordedOutcome))
                    if toolCall.isMutating {
                        plannerHistory.append(observationHistoryItem(observation, step: step))
                    }
                case .needsConfirmation:
                    let recordedOutcome = outcome(
                        step: step,
                        toolCall: toolCall,
                        result: result,
                        message: result.message,
                        observation: beforeObservation,
                        delta: nil
                    )
                    priorResults.append(recordedOutcome)
                    plannerHistory.append(outcomeHistoryItem(recordedOutcome))
                    traceEvents.append(traceEvent(kind: "confirm", title: "Confirmation required", body: result.message, status: "confirm", step: step))
                    return .init(status: .needsConfirmation, message: result.message, traceEvents: traceEvents)
                case .unsupported, .failed:
                    if let fallbackMessage = recoverableFallbackMessage(for: toolCall, result: result) {
                        let recordedOutcome = outcome(
                            step: step,
                            toolCall: toolCall,
                            result: result,
                            message: fallbackMessage,
                            observation: beforeObservation,
                            delta: nil
                        )
                        priorResults.append(recordedOutcome)
                        plannerHistory.append(outcomeHistoryItem(recordedOutcome))
                        onStatus("Screen fallback")
                        traceEvents.append(traceEvent(
                            kind: "fallback",
                            title: "Screen fallback",
                            body: fallbackMessage,
                            status: "fallback",
                            step: step
                        ))
                        onStatus("Observing screen")
                        observation = observe(registry, true, currentTarget)
                        traceEvents.append(observationEvent(observation, step: step))
                        plannerHistory.append(observationHistoryItem(observation, step: step))
                        continue
                    }
                    let recordedOutcome = outcome(
                        step: step,
                        toolCall: toolCall,
                        result: result,
                        message: result.message,
                        observation: beforeObservation,
                        delta: nil
                    )
                    priorResults.append(recordedOutcome)
                    plannerHistory.append(outcomeHistoryItem(recordedOutcome))
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
            transaction: result.transaction ?? inferredTransaction(result: result, delta: delta)
        )
    }

    private func inferredTransaction(
        result: ComputerUseExecutionResult,
        delta: ComputerUseStateDelta?
    ) -> ComputerUseActionTransaction {
        let effect: ComputerUseActionEffect
        switch delta?.status {
        case .changed: effect = .changed
        case .unchanged: effect = .unchanged
        case .blocked, .targetLost: effect = .blocked
        case .unknown, nil: effect = .unknown
        }
        return ComputerUseActionTransaction(
            posted: result.status == .executed ? nil : false,
            effect: effect,
            targetStable: delta?.status == .targetLost ? false : nil
        )
    }

    private func historyToolSummary(_ toolCall: ComputerUseToolCall) -> String {
        if toolCall.tool == .pasteText || toolCall.tool == .typeText || toolCall.tool == .setValue {
            let count = (toolCall.text ?? toolCall.value ?? "").count
            return "\(toolCall.tool.rawValue) (\(count) characters)"
        }
        return String(toolCall.summary.prefix(240))
    }

    private func outcomeHistoryItem(_ outcome: ComputerUseToolOutcome) -> ComputerUsePlannerHistoryItem {
        ComputerUsePlannerHistoryItem(
            kind: .toolResult,
            step: outcome.step,
            tool: outcome.tool,
            status: outcome.status,
            summary: String(outcome.message.prefix(320)),
            stateID: outcome.afterStateID,
            screenshotID: outcome.snapshotID,
            transaction: outcome.transaction
        )
    }

    private func observationHistoryItem(
        _ observation: ComputerUseObservation,
        step: Int?
    ) -> ComputerUsePlannerHistoryItem {
        ComputerUsePlannerHistoryItem(
            kind: .observationReceipt,
            step: step,
            status: "observed",
            summary: "\(observation.appName) - \(observation.windowTitle) - \(observation.elements.count) AX candidates",
            stateID: observation.stateID,
            screenshotID: observation.screenshot?.screenshotID
        )
    }

    private func observationEvent(_ observation: ComputerUseObservation, step: Int?) -> ComputerUseTraceEvent {
        let app = observation.appName.isEmpty ? "Unknown app" : observation.appName
        let window = observation.windowTitle.isEmpty ? "No focused window" : observation.windowTitle
        var details = ["state \(observation.stateID)", "\(app) - \(window) - \(observation.elements.count) AX candidates"]
        if let screenshot = observation.screenshot {
            details.append("screenshot \(screenshot.screenshotID) \(screenshot.width)x\(screenshot.height)")
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
            step: step
        )
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

        let beforeSignature = observationSignature(before)
        let afterSignature = observationSignature(after)
        let status: ComputerUseVerificationStatus = beforeSignature == afterSignature ? .unchanged : .changed
        let summary: String
        if status == .changed {
            summary = "Observed UI state changed after \(toolCall.summary)."
        } else if toolCall.tool == .typeText || toolCall.tool == .pasteText || toolCall.tool == .setValue {
            summary = "\(toolCall.summary) executed; no focused value, selected text, or visible AX text change was observed."
        } else {
            summary = "\(toolCall.summary) executed; no relevant UI change was observed."
        }
        return ComputerUseStateDelta(
            status: status,
            summary: summary,
            beforeStateID: before.stateID,
            afterStateID: after.stateID
        )
    }

    private func verifiedOutcomeMessage(base: String, delta: ComputerUseStateDelta?) -> String {
        guard let delta else { return base }
        return "\(base). Verification: \(delta.summary)"
    }

    private func target(from toolCall: ComputerUseToolCall, fallback: ComputerUseObservationTarget?) -> ComputerUseObservationTarget? {
        if !toolCall.canonicalBundleID.isEmpty {
            return ComputerUseObservationTarget(appName: toolCall.appName, bundleID: toolCall.canonicalBundleID)
        }
        if let appName = toolCall.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty {
            return ComputerUseObservationTarget(appName: appName, bundleID: nil)
        }
        switch toolCall.tool {
        case .moveCursor, .click, .clickElement, .clickPoint, .performSecondaryAction, .setValue, .typeText, .pasteText, .pressKey, .hotkey, .scroll, .drag:
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
        case .listApps, .listWindows, .listBrowserTabs, .pageGetText, .pageQueryDOM:
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
                step: request.step
            ))
            do {
                return try await plan(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < maxPlannerRetries, isRecoverablePlannerError(error) else {
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
            return "\(message). Continue with get_app_state plus AX/screenshot tools: click_element/click_point, paste_text/type_text, press_key/hotkey, and scroll. Do not retry browser page tools unless the user grants Chrome Apple Events JavaScript permission."
        }
        if (toolCall.tool == .typeText || toolCall.tool == .pasteText), isTextFocusFailure(message) {
            return "\(message). Continue with get_app_state and focus an editable target using click_element or set_value before retrying text entry. Prefer paste_text for Apple Notes and native rich-text editors. Do not repeat text entry until the focused target changes."
        }
        return nil
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
        message.lowercased().contains("no focused editable text target")
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
        step: Int?
    ) -> ComputerUseTraceEvent {
        ComputerUseTraceEvent(kind: kind, title: title, body: body, status: status, step: step)
    }
}
