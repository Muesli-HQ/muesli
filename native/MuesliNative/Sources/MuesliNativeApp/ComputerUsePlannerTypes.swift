import Foundation

enum ComputerUseToolName: String, Codable, Equatable, CaseIterable {
    case observe
    case observeScreen = "observe_screen"
    case openApp = "open_app"
    case focusApp = "focus_app"
    case clickElement = "click_element"
    case clickPoint = "click_point"
    case moveCursor = "move_cursor"
    case drag
    case getCursorPosition = "get_cursor_position"
    case pressKey = "press_key"
    case typeText = "type_text"
    case pasteText = "paste_text"
    case scroll
    case finish
}

enum ComputerUseScrollDirection: String, Codable, Equatable {
    case up
    case down
    case left
    case right
}

struct ComputerUseKeyCommand: Equatable {
    let modifiers: [ComputerUseKeyModifier]
    let key: String
}

enum ComputerUseKeyModifier: String, Codable, CaseIterable, Equatable {
    case command
    case option
    case control
    case shift
    case function
}

struct ComputerUseToolCall: Codable, Equatable {
    let tool: ComputerUseToolName
    let appName: String?
    let elementID: String?
    let screenshotID: String?
    let label: String?
    let x: Double?
    let y: Double?
    let toX: Double?
    let toY: Double?
    let clicks: Int?
    let button: String?
    let key: String?
    let modifiers: [ComputerUseKeyModifier]?
    let text: String?
    let direction: ComputerUseScrollDirection?
    let pages: Double?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case tool
        case appName = "app_name"
        case elementID = "element_id"
        case screenshotID = "screenshot_id"
        case label
        case x
        case y
        case toX = "to_x"
        case toY = "to_y"
        case clicks
        case button
        case key
        case modifiers
        case text
        case direction
        case pages
        case reason
    }

    init(
        tool: ComputerUseToolName,
        appName: String? = nil,
        elementID: String? = nil,
        screenshotID: String? = nil,
        label: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        toX: Double? = nil,
        toY: Double? = nil,
        clicks: Int? = nil,
        button: String? = nil,
        key: String? = nil,
        modifiers: [ComputerUseKeyModifier]? = nil,
        text: String? = nil,
        direction: ComputerUseScrollDirection? = nil,
        pages: Double? = nil,
        reason: String? = nil
    ) {
        self.tool = tool
        self.appName = appName
        self.elementID = elementID
        self.screenshotID = screenshotID
        self.label = label
        self.x = x
        self.y = y
        self.toX = toX
        self.toY = toY
        self.clicks = clicks
        self.button = button
        self.key = key
        self.modifiers = modifiers
        self.text = text
        self.direction = direction
        self.pages = pages
        self.reason = reason
    }

    func validationFailure() -> String? {
        switch tool {
        case .observe, .observeScreen, .getCursorPosition, .finish:
            return nil
        case .openApp, .focusApp:
            return trimmed(appName).isEmpty ? "\(tool.rawValue) requires app_name" : nil
        case .clickElement:
            return trimmed(elementID).isEmpty ? "click_element requires element_id" : nil
        case .clickPoint, .moveCursor:
            return x == nil || y == nil ? "\(tool.rawValue) requires x and y" : nil
        case .drag:
            return x == nil || y == nil || toX == nil || toY == nil ? "drag requires x, y, to_x, and to_y" : nil
        case .pressKey:
            return trimmed(key).isEmpty ? "press_key requires key" : nil
        case .typeText, .pasteText:
            return trimmed(text).isEmpty ? "\(tool.rawValue) requires text" : nil
        case .scroll:
            return direction == nil ? "scroll requires direction" : nil
        }
    }

    var requiresConfirmation: Bool {
        switch tool {
        case .clickElement:
            return containsRiskyWord(label ?? "")
        case .clickPoint, .drag:
            return containsRiskyWord([label, reason].compactMap { $0 }.joined(separator: " "))
        case .pressKey:
            let mods = modifiers ?? []
            return mods.contains(.command) && ["q", "w"].contains(canonical(key ?? ""))
        default:
            return false
        }
    }

    var summary: String {
        switch tool {
        case .observe:
            return "observe"
        case .observeScreen:
            return "observe screen"
        case .openApp:
            return "open \(trimmed(appName))"
        case .focusApp:
            return "focus \(trimmed(appName))"
        case .clickElement:
            let visibleLabel = trimmed(label).isEmpty ? trimmed(elementID) : trimmed(label)
            return "click \(visibleLabel)"
        case .clickPoint:
            let visibleLabel = trimmed(label).isEmpty ? "point" : trimmed(label)
            return "click \(visibleLabel) at \(coordinateSummary(x, y))"
        case .moveCursor:
            return "move cursor to \(coordinateSummary(x, y))"
        case .drag:
            return "drag \(coordinateSummary(x, y)) to \(coordinateSummary(toX, toY))"
        case .getCursorPosition:
            return "get cursor position"
        case .pressKey:
            let parts = (modifiers ?? []).map(\.rawValue) + [trimmed(key)]
            return "press \(parts.filter { !$0.isEmpty }.joined(separator: "+"))"
        case .typeText:
            return "type \(truncateForSummary(trimmed(text)))"
        case .pasteText:
            return "paste \(truncateForSummary(trimmed(text)))"
        case .scroll:
            return "scroll \(direction?.rawValue ?? "")"
        case .finish:
            return trimmed(reason).isEmpty ? "finish" : "finish: \(trimmed(reason))"
        }
    }

    private func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func truncateForSummary(_ value: String) -> String {
        value.count > 32 ? String(value.prefix(29)) + "..." : value
    }

    private func coordinateSummary(_ x: Double?, _ y: Double?) -> String {
        guard let x, let y else { return "unknown" }
        return "\(Int(x.rounded())),\(Int(y.rounded()))"
    }

    private func containsRiskyWord(_ text: String) -> Bool {
        let riskyWords = [
            "archive",
            "buy",
            "cancel",
            "checkout",
            "confirm",
            "delete",
            "discard",
            "pay",
            "purchase",
            "remove",
            "send",
            "submit",
            "unsubscribe",
        ]
        let words = Set(canonical(text).split(separator: " ").map(String.init))
        return riskyWords.contains { words.contains($0) }
    }

    private func canonical(_ value: String) -> String {
        value.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}

struct ComputerUsePlannerResponse: Codable, Equatable {
    let toolCall: ComputerUseToolCall
    let rawModelOutput: String?

    enum CodingKeys: String, CodingKey {
        case toolCall = "tool_call"
    }

    init(toolCall: ComputerUseToolCall, rawModelOutput: String? = nil) {
        self.toolCall = toolCall
        self.rawModelOutput = rawModelOutput
    }

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if keyed.contains(.toolCall) {
            toolCall = try keyed.decode(ComputerUseToolCall.self, forKey: .toolCall)
        } else {
            toolCall = try ComputerUseToolCall(from: decoder)
        }
        if let failure = toolCall.validationFailure() {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: failure)
            )
        }
        rawModelOutput = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(toolCall, forKey: .toolCall)
    }

    static func decodeJSON(from text: String) throws -> ComputerUsePlannerResponse {
        let json = try extractJSONObject(from: text)
        let decoded = try JSONDecoder().decode(ComputerUsePlannerResponse.self, from: Data(json.utf8))
        return ComputerUsePlannerResponse(toolCall: decoded.toolCall, rawModelOutput: json)
    }

    private static func extractJSONObject(from text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }
        let withoutFence = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if withoutFence.hasPrefix("{"), withoutFence.hasSuffix("}") {
            return withoutFence
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Planner response was not a single JSON object")
        )
    }
}

struct ComputerUseToolResult: Codable, Equatable {
    let step: Int
    let tool: ComputerUseToolName
    let status: String
    let message: String
}

struct ComputerUsePlannerRequest: Codable, Equatable {
    let command: String
    let step: Int
    let maxSteps: Int?
    let observation: ComputerUseObservation
    let priorResults: [ComputerUseToolResult]

    enum CodingKeys: String, CodingKey {
        case command
        case step
        case maxSteps = "max_steps"
        case observation
        case priorResults = "prior_results"
    }
}
