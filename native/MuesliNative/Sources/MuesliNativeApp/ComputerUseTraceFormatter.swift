import Foundation
import MuesliCore

enum ComputerUseTraceFormatter {
    /// Describe the operation without copying page contents, typed text, JSON, or error dumps.
    static func compactSummary(for tool: ComputerUseToolName, status: ComputerUseExecutionResult.Status) -> String {
        let action: String
        let completed: String
        switch tool {
        case .listApps: (action, completed) = ("List apps", "Listed apps")
        case .launchApp: (action, completed) = ("Open app", "Opened app")
        case .listWindows: (action, completed) = ("List windows", "Listed windows")
        case .getAppState, .getWindowState: (action, completed) = ("Read window", "Read window")
        case .moveCursor: (action, completed) = ("Move cursor", "Moved cursor")
        case .click, .clickElement, .clickPoint: (action, completed) = ("Click target", "Clicked target")
        case .performSecondaryAction: (action, completed) = ("Perform action", "Performed action")
        case .setValue: (action, completed) = ("Set value", "Set value")
        case .editText: (action, completed) = ("Edit text", "Edited text")
        case .typeText: (action, completed) = ("Type text", "Typed text")
        case .pasteText: (action, completed) = ("Paste text", "Pasted text")
        case .pressKey, .hotkey: (action, completed) = ("Press key", "Pressed key")
        case .scroll: (action, completed) = ("Scroll", "Scrolled")
        case .drag: (action, completed) = ("Drag", "Dragged")
        case .listBrowserTabs: (action, completed) = ("List browser tabs", "Listed browser tabs")
        case .activateBrowserTab: (action, completed) = ("Switch browser tab", "Switched browser tab")
        case .openNewBrowserTab: (action, completed) = ("Open new tab", "Opened a new tab")
        case .navigateURL, .navigateActiveBrowserTab: (action, completed) = ("Navigate to page", "Navigated to page")
        case .pageGetText: (action, completed) = ("Read page text", "Read page text")
        case .pageQueryDOM: (action, completed) = ("Inspect page elements", "Inspected page elements")
        case .finish: (action, completed) = ("Complete task", "Completed task")
        case .fail: (action, completed) = ("Stop task", "Stopped task")
        }
        switch status {
        case .executed: return completed
        case .failed: return "\(action) — failed"
        case .unsupported: return "\(action) — unavailable"
        case .cancelled: return "\(action) — cancelled"
        case .needsConfirmation: return "\(action) — needs approval"
        }
    }

    static func debugText(for record: DictationRecord) -> String {
        guard let trace = record.computerUseTrace else {
            return record.rawText
        }

        var lines: [String] = [
            "CUA Command",
            record.rawText,
            "",
            "Final Status",
            displayFinalStatus(trace.finalStatus),
            "",
            "Final Message",
            trace.finalMessage,
            "",
            "Step Trail",
        ]

        for event in trace.events {
            let step = event.step.map { "Step \($0)" } ?? "Run"
            let status = displayStatus(for: event).map { " [\($0)]" } ?? ""
            lines.append("\(step) - \(event.title)\(status)")
            lines.append(event.body)
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayStatus(for event: ComputerUseTraceEvent) -> String? {
        guard let status = event.status?.trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else { return nil }
        let normalizedStatus = status.lowercased()
        let normalizedTitle = event.title.lowercased()
        if normalizedStatus == normalizedTitle {
            return nil
        }
        switch (event.kind, normalizedStatus) {
        case ("observation", "observed"),
             ("planning", "planning"),
             ("tool_call", "executing"),
             ("model_output", "planned"):
            return nil
        default:
            return status
        }
    }

    static func displayFinalStatus(_ status: String) -> String {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "done":
            return "done"
        case "timed_out", "timedout":
            return "timed_out"
        case "failed", "fail":
            return "failed"
        case "confirm", "needsconfirmation", "needs_confirmation":
            return "confirm"
        case "cancelled", "canceled":
            return "cancelled"
        default:
            return status
        }
    }
}
