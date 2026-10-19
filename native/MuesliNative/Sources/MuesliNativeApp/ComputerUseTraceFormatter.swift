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

    struct ReadableRow: Identifiable {
        let id: UUID
        var title: String
        var detail: String
        var outcome: String
        var events: [ComputerUseTraceEvent]
        var readTarget: String? = nil
        var readCount = 1
    }

    /// A presentation-only projection. Saved events and copied diagnostics remain unchanged.
    static func readableRows(_ events: [ComputerUseTraceEvent]) -> [ReadableRow] {
        var rows: [ReadableRow] = []
        var consumed = Set<UUID>()
        var refs: [String: String] = [:]
        var snapshotTarget = ""
        var targetDescriptions: [String: String] = [:]
        let diagnostics: Set<String> = ["transcript", "backend", "context_budget"]
        for (index, event) in events.enumerated() {
            guard !consumed.contains(event.id), !diagnostics.contains(event.kind) else { continue }
            guard event.kind == "tool_call", event.body.hasPrefix("[trycua] ") else {
                // Native/older events also stay concise, with the original record available below.
                rows.append(.init(id: event.id,
                    title: event.kind == "finish" ? "Planner reported completion" : event.title,
                    detail: short(event.compactSummary ?? event.body, limit: 160),
                    outcome: event.status ?? "", events: [event]))
                continue
            }
            let name = event.body.components(separatedBy: "\n")[0].replacingOccurrences(of: "[trycua] ", with: "")
            let args = object(in: event.body) ?? [:]
            // Reference runtime is sequential; step is its stable per-run call key.
            // Never attach a result across another invocation (including malformed legacy traces).
            let following = events.dropFirst(index + 1).prefix { $0.kind != "tool_call" }
            let result = event.step.flatMap { step in following.first { $0.kind == "tool_result" && $0.step == step } }
            if let result { consumed.insert(result.id) }
            let data = result.flatMap { object(in: $0.body) } ?? [:]
            let target = [args["target_id"] as? String, args["tab_id"] as? String].compactMap { $0 }.joined(separator: "/")
            let label = target == snapshotTarget ? (args["ref"] as? String).flatMap { refs[$0] } : nil
            let failed = result?.status == "failed" || data["isError"] as? Bool == true
                || data["error"] != nil || ["error", "failed", "blocked"].contains(data["status"] as? String ?? "")
            let read = ["get_browser_state", "get_window_state", "get_accessibility_tree", "verify_state", "list_windows", "list_apps", "check_permissions", "get_cursor_position", "get_screen_size", "get_agent_cursor_state"].contains(name)
            var title: String
            switch name {
            case "get_browser_state": title = args["tab_id"] == nil ? "Inspect browser tabs" : "Inspect page"
            case "browser_navigate": title = args["new_tab"] as? Bool == true ? "Open background tab" : "Navigate to page"
            case "browser_type", "type_text", "set_value": title = "Enter text: “\(short(args["text"] as? String ?? args["value"] as? String ?? "", limit: 72))”"
            case "browser_click", "click", "double_click", "right_click":
                if let label, !label.isEmpty { title = "Click “\(short(label, limit: 80))”" }
                else if let x = args["x"], let y = args["y"] { title = "Click at (\(x), \(y))" }
                else { title = "Click target \(args["ref"] as? String ?? "")" }
            case "browser_pointer": title = "Pointer: \(args["action"] as? String ?? "action")"
            case "list_windows": title = "Inspect windows"
            case "list_apps": title = "Inspect apps"
            case "finish": title = "Planner reported completion"
            case "fail": title = "Planner reported a blocker"
            default: title = name.replacingOccurrences(of: "_", with: " ").capitalized
            }
            let page = data["page"] as? [String: Any]
            var details = [name]
            if let url = args["url"] as? String ?? page?["url"] as? String, let parsed = URL(string: url) {
                let description = short((parsed.host ?? "") + parsed.path, limit: 100)
                details.append(description)
                if !target.isEmpty, page?["url"] != nil { targetDescriptions[target] = description }
            } else if args["tab_id"] != nil { details.append(targetDescriptions[target] ?? "Browser tab") }
            else if let window = args["window_id"] { details.append("window \(window)") }
            if let count = (data["refs"] as? [Any])?.count { details.append("\(count) actionable elements") }
            if let result, let start = date(event.timestamp), let end = date(result.timestamp) {
                let elapsed = max(0, end.timeIntervalSince(start))
                details.append(elapsed < 1 ? "<1s" : String(format: "%.1fs", elapsed))
            }
            let delivery = data["delivery"] as? [String: Any]
            if let mode = delivery?["mode"] as? String { details.append(mode) }
            let outcome: String
            if name == "finish" || name == "fail" { outcome = "Planner assessment" }
            else if failed { outcome = "Error — inspect details" }
            else if result == nil { outcome = "No result recorded" }
            else if read { outcome = data.isEmpty ? "Result recorded" : "Observed" }
            else { outcome = "Tool returned — outcome unverified" }
            var raw = [event]
            if let result { raw.append(result) }
            // Keep the terminal message with its invocation rather than duplicating a row.
            if name == "finish" || name == "fail",
               let terminal = following.first(where: { ["finish", "failed", "incomplete"].contains($0.kind) }) {
                raw.append(terminal); consumed.insert(terminal.id)
            }
            let readKey = name == "get_browser_state" && !failed && result != nil && data["status"] as? String == "ok" ? target : nil
            let row = ReadableRow(id: event.id, title: title, detail: details.joined(separator: " · "), outcome: outcome, events: raw, readTarget: readKey)
            if let readKey, !readKey.isEmpty, let last = rows.indices.last, rows[last].readTarget == readKey {
                rows[last].readCount += 1
                rows[last].title = "Inspected page ×\(rows[last].readCount)"
                rows[last].detail = "\(name) · \(targetDescriptions[target] ?? "Browser tab") · Expand for individual reads"
                rows[last].events += raw
            } else { rows.append(row) }
            if name == "get_browser_state" {
                // Invalidate even on failure; never borrow labels from stale or another tab's refs.
                refs = [:]; snapshotTarget = ""
                if !failed, let targetID = data["target_id"] as? String, let tabID = data["tab_id"] as? String {
                    snapshotTarget = targetID + "/" + tabID
                    for ref in (data["refs"] as? [[String: Any]] ?? []) {
                        if let id = ref["ref"] as? String, let label = ref["name"] as? String ?? ref["label"] as? String { refs[id] = label }
                    }
                }
            } else if !read { refs = [:]; snapshotTarget = "" }
        }
        return rows
    }

    static func budgetSummary(_ events: [ComputerUseTraceEvent]) -> String? {
        let pattern = #"estimated history=(\d+); allowance=(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let counts = events.filter { $0.kind == "context_budget" }.compactMap { event -> (Int, Int)? in
            let ns = event.body as NSString
            guard let match = regex.firstMatch(in: event.body, range: NSRange(location: 0, length: ns.length)),
                  let used = Int(ns.substring(with: match.range(at: 1))), let limit = Int(ns.substring(with: match.range(at: 2))) else { return nil }
            return (used, limit)
        }
        guard let peak = counts.max(by: { $0.0 < $1.0 }) else { return nil }
        return "History peak: \(peak.0.formatted()) / \(peak.1.formatted()) estimated tokens"
    }

    private static func object(in body: String) -> [String: Any]? {
        // Upstream text summaries precede JSON. Match a whole JSON object line,
        // not an incidental brace inside a page label or error message.
        for line in body.components(separatedBy: "\n") where line.hasPrefix("{") {
            if let data = line.data(using: .utf8), let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return value }
        }
        return nil
    }

    private static func short(_ text: String, limit: Int) -> String {
        let clean = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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
