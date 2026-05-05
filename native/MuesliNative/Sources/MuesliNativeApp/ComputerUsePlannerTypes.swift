import Foundation

enum ComputerUseToolName: String, Codable, Equatable, CaseIterable {
    case listApps = "list_apps"
    case launchApp = "launch_app"
    case listWindows = "list_windows"
    case getWindowState = "get_window_state"
    case click
    case setValue = "set_value"
    case typeText = "type_text"
    case pressKey = "press_key"
    case hotkey
    case scroll
    case drag
    case listBrowserTabs = "list_browser_tabs"
    case activateBrowserTab = "activate_browser_tab"
    case navigateURL = "navigate_url"
    case pageGetText = "page_get_text"
    case pageQueryDOM = "page_query_dom"
    case finish
    case fail
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

struct ComputerUseAppInfo: Codable, Equatable {
    let name: String
    let bundleID: String
    let processID: Int?
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
        case processID = "process_id"
        case isActive = "is_active"
    }
}

struct ComputerUseWindowInfo: Codable, Equatable {
    let windowID: Int?
    let appName: String
    let bundleID: String
    let processID: Int?
    let title: String
    let frame: ComputerUseRect?
    let isOnScreen: Bool

    enum CodingKeys: String, CodingKey {
        case windowID = "window_id"
        case appName = "app_name"
        case bundleID = "bundle_id"
        case processID = "process_id"
        case title
        case frame
        case isOnScreen = "is_on_screen"
    }
}

struct ComputerUseBrowserTabInfo: Codable, Equatable {
    let appBundleID: String
    let windowIndex: Int
    let tabIndex: Int
    let title: String
    let url: String
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case appBundleID = "app_bundle_id"
        case windowIndex = "window_index"
        case tabIndex = "tab_index"
        case title
        case url
        case isActive = "is_active"
    }
}

struct ComputerUseWindowState: Codable, Equatable {
    let appName: String
    let bundleID: String
    let windowTitle: String
    let windowFrame: ComputerUseRect?
    let screenshot: ComputerUseScreenshotObservation?
    let cursorPosition: ComputerUseRect?
    let elements: [ComputerUseElementCandidate]
    let capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case appName = "app_name"
        case bundleID = "bundle_id"
        case windowTitle = "window_title"
        case windowFrame = "window_frame"
        case screenshot
        case cursorPosition = "cursor_position"
        case elements
        case capturedAt = "captured_at"
    }

    init(observation: ComputerUseObservation) {
        appName = observation.appName
        bundleID = observation.bundleID
        windowTitle = observation.windowTitle
        windowFrame = observation.windowFrame
        screenshot = observation.screenshot
        cursorPosition = observation.cursorPosition
        elements = observation.elements
        capturedAt = observation.capturedAt
    }

    init(
        appName: String,
        bundleID: String,
        windowTitle: String,
        windowFrame: ComputerUseRect?,
        screenshot: ComputerUseScreenshotObservation?,
        cursorPosition: ComputerUseRect?,
        elements: [ComputerUseElementCandidate],
        capturedAt: Date
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
        self.screenshot = screenshot
        self.cursorPosition = cursorPosition
        self.elements = elements
        self.capturedAt = capturedAt
    }

    var observation: ComputerUseObservation {
        ComputerUseObservation(
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            windowFrame: windowFrame,
            screenshot: screenshot,
            cursorPosition: cursorPosition,
            elements: elements,
            capturedAt: capturedAt
        )
    }
}

struct ComputerUseToolInvocation: Codable, Equatable {
    let tool: ComputerUseToolName
    let appName: String?
    let appBundleID: String?
    let bundleID: String?
    let processID: Int?
    let windowID: Int?
    let windowIndex: Int?
    let tabIndex: Int?
    let elementID: String?
    let elementIndex: Int?
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
    let value: String?
    let direction: ComputerUseScrollDirection?
    let pages: Double?
    let url: String?
    let selector: String?
    let attributes: [String]?
    let reason: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case tool
        case appName = "app_name"
        case appBundleID = "app_bundle_id"
        case bundleID = "bundle_id"
        case processID = "process_id"
        case windowID = "window_id"
        case windowIndex = "window_index"
        case tabIndex = "tab_index"
        case elementID = "element_id"
        case elementIndex = "element_index"
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
        case value
        case direction
        case pages
        case url
        case selector
        case attributes
        case reason
    }

    init(
        tool: ComputerUseToolName,
        appName: String? = nil,
        appBundleID: String? = nil,
        bundleID: String? = nil,
        processID: Int? = nil,
        windowID: Int? = nil,
        windowIndex: Int? = nil,
        tabIndex: Int? = nil,
        elementID: String? = nil,
        elementIndex: Int? = nil,
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
        value: String? = nil,
        direction: ComputerUseScrollDirection? = nil,
        pages: Double? = nil,
        url: String? = nil,
        selector: String? = nil,
        attributes: [String]? = nil,
        reason: String? = nil
    ) {
        self.tool = tool
        self.appName = appName
        self.appBundleID = appBundleID
        self.bundleID = bundleID
        self.processID = processID
        self.windowID = windowID
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.elementID = elementID
        self.elementIndex = elementIndex
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
        self.value = value
        self.direction = direction
        self.pages = pages
        self.url = url
        self.selector = selector
        self.attributes = attributes
        self.reason = reason
    }

    var canonicalBundleID: String {
        trimmed(appBundleID).isEmpty ? trimmed(bundleID) : trimmed(appBundleID)
    }

    func validationFailure() -> String? {
        switch tool {
        case .listApps, .listWindows, .getWindowState, .finish:
            return nil
        case .launchApp:
            return trimmed(appName).isEmpty && canonicalBundleID.isEmpty ? "launch_app requires app_name or app_bundle_id" : nil
        case .click:
            if elementIndex != nil || !trimmed(elementID).isEmpty {
                return nil
            }
            return x == nil || y == nil ? "click requires element_index, element_id, or x and y" : nil
        case .setValue:
            if trimmed(value).isEmpty {
                return "set_value requires value"
            }
            return elementIndex == nil && trimmed(elementID).isEmpty ? "set_value requires element_index or element_id" : nil
        case .typeText:
            return trimmed(text).isEmpty ? "type_text requires text" : nil
        case .pressKey, .hotkey:
            return trimmed(key).isEmpty ? "\(tool.rawValue) requires key" : nil
        case .scroll:
            return direction == nil ? "scroll requires direction" : nil
        case .drag:
            return x == nil || y == nil || toX == nil || toY == nil ? "drag requires x, y, to_x, and to_y" : nil
        case .listBrowserTabs:
            return canonicalBundleID.isEmpty ? "list_browser_tabs requires app_bundle_id" : nil
        case .activateBrowserTab:
            if canonicalBundleID.isEmpty { return "activate_browser_tab requires app_bundle_id" }
            if windowIndex == nil { return "activate_browser_tab requires window_index" }
            if tabIndex == nil { return "activate_browser_tab requires tab_index" }
            return nil
        case .navigateURL:
            if canonicalBundleID.isEmpty { return "navigate_url requires app_bundle_id" }
            return safeHTTPURL(trimmed(url)) == nil ? "navigate_url requires a safe http or https url" : nil
        case .pageGetText:
            if canonicalBundleID.isEmpty { return "page_get_text requires app_bundle_id" }
            return nil
        case .pageQueryDOM:
            if canonicalBundleID.isEmpty { return "page_query_dom requires app_bundle_id" }
            return trimmed(selector).isEmpty ? "page_query_dom requires selector" : nil
        case .fail:
            return trimmed(reason).isEmpty ? "fail requires reason" : nil
        }
    }

    var requiresConfirmation: Bool {
        switch tool {
        case .click:
            if elementIndex == nil && trimmed(elementID).isEmpty {
                return true
            }
            return containsRiskyWord([label, reason].compactMap { $0 }.joined(separator: " "))
        case .drag:
            return containsRiskyWord([label, reason].compactMap { $0 }.joined(separator: " "))
        case .pressKey, .hotkey:
            let mods = modifiers ?? []
            return mods.contains(.command) && ["q", "w"].contains(canonical(key ?? ""))
        case .navigateURL:
            return safeHTTPURL(trimmed(url)) == nil
        default:
            return false
        }
    }

    var isMutating: Bool {
        switch tool {
        case .launchApp, .click, .setValue, .typeText, .pressKey, .hotkey, .scroll, .drag, .activateBrowserTab, .navigateURL:
            return true
        case .listApps, .listWindows, .getWindowState, .listBrowserTabs, .pageGetText, .pageQueryDOM, .finish, .fail:
            return false
        }
    }

    var summary: String {
        switch tool {
        case .listApps:
            return "list apps"
        case .launchApp:
            return "launch \(trimmed(appName).isEmpty ? canonicalBundleID : trimmed(appName))"
        case .listWindows:
            return "list windows"
        case .getWindowState:
            return "get window state"
        case .click:
            if let elementIndex {
                return "click element \(elementIndexLabel(elementIndex))"
            }
            if !trimmed(elementID).isEmpty {
                return "click \(trimmed(label).isEmpty ? trimmed(elementID) : trimmed(label))"
            }
            return "click \(trimmed(label).isEmpty ? "point" : trimmed(label)) at \(coordinateSummary(x, y))"
        case .setValue:
            let target = elementIndex.map(elementIndexLabel) ?? trimmed(elementID)
            return "set \(target) to \(truncateForSummary(trimmed(value)))"
        case .typeText:
            return "type \(truncateForSummary(trimmed(text)))"
        case .pressKey, .hotkey:
            let parts = (modifiers ?? []).map(\.rawValue) + [trimmed(key)]
            return "press \(parts.filter { !$0.isEmpty }.joined(separator: "+"))"
        case .scroll:
            return "scroll \(direction?.rawValue ?? "")"
        case .drag:
            return "drag \(coordinateSummary(x, y)) to \(coordinateSummary(toX, toY))"
        case .listBrowserTabs:
            return "list browser tabs"
        case .activateBrowserTab:
            return "activate browser tab \(windowIndex ?? 0):\(tabIndex ?? 0)"
        case .navigateURL:
            return "navigate to \(truncateForSummary(trimmed(url)))"
        case .pageGetText:
            return "get page text"
        case .pageQueryDOM:
            return "query DOM \(trimmed(selector))"
        case .finish:
            return trimmed(reason).isEmpty ? "finish" : "finish: \(trimmed(reason))"
        case .fail:
            return "fail: \(trimmed(reason))"
        }
    }

    static func safeHTTPURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\n"),
              !trimmed.contains("\r"),
              !trimmed.contains(";"),
              !trimmed.contains("|"),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private func safeHTTPURL(_ value: String) -> URL? {
        Self.safeHTTPURL(value)
    }

    private func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func truncateForSummary(_ value: String) -> String {
        value.count > 48 ? String(value.prefix(45)) + "..." : value
    }

    private func coordinateSummary(_ x: Double?, _ y: Double?) -> String {
        guard let x, let y else { return "unknown" }
        return "\(Int(x.rounded())),\(Int(y.rounded()))"
    }

    private func elementIndexLabel(_ index: Int) -> String {
        "e\(index)"
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

typealias ComputerUseToolCall = ComputerUseToolInvocation

struct ComputerUsePlannerResponse: Codable, Equatable {
    let toolCall: ComputerUseToolInvocation
    let rawModelOutput: String?

    enum CodingKeys: String, CodingKey {
        case toolCall = "tool_call"
    }

    init(toolCall: ComputerUseToolInvocation, rawModelOutput: String? = nil) {
        self.toolCall = toolCall
        self.rawModelOutput = rawModelOutput
    }

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if keyed.contains(.toolCall) {
            toolCall = try keyed.decode(ComputerUseToolInvocation.self, forKey: .toolCall)
        } else {
            toolCall = try ComputerUseToolInvocation(from: decoder)
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
        try rejectUnknownKeys(in: json)
        let decoded = try JSONDecoder().decode(ComputerUsePlannerResponse.self, from: Data(json.utf8))
        return ComputerUsePlannerResponse(toolCall: decoded.toolCall, rawModelOutput: json)
    }

    private static func rejectUnknownKeys(in json: String) throws {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Planner response was not a JSON object")
            )
        }

        let allowed = Set(ComputerUseToolInvocation.CodingKeys.allCases.map(\.stringValue))
        if let wrapped = object["tool_call"] as? [String: Any] {
            let extraTopLevel = Set(object.keys).subtracting(["tool_call"])
            if let key = extraTopLevel.sorted().first {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "Unsupported top-level field \(key)")
                )
            }
            try rejectUnknownInvocationKeys(wrapped, allowed: allowed)
        } else {
            try rejectUnknownInvocationKeys(object, allowed: allowed)
        }
    }

    private static func rejectUnknownInvocationKeys(_ object: [String: Any], allowed: Set<String>) throws {
        let keys = Set(object.keys)
        let extra = keys.subtracting(allowed)
        if let key = extra.sorted().first {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "Unsupported tool field \(key)")
            )
        }
        if let toolName = object["tool"] as? String,
           let tool = ComputerUseToolName(rawValue: toolName),
           let definition = ComputerUseToolRegistry.definition(for: tool) {
            let schemaKeys = Set(definition.schema.properties.keys)
            let extraForTool = keys.subtracting(schemaKeys)
            if let key = extraForTool.sorted().first {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "\(tool.rawValue) does not support field \(key)")
                )
            }
        }
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

struct ComputerUseToolOutcome: Codable, Equatable {
    let step: Int
    let tool: ComputerUseToolName
    let status: String
    let message: String
    let appName: String?
    let bundleID: String?
    let windowTitle: String?
    let snapshotID: String?

    enum CodingKeys: String, CodingKey {
        case step
        case tool
        case status
        case message
        case appName = "app_name"
        case bundleID = "bundle_id"
        case windowTitle = "window_title"
        case snapshotID = "snapshot_id"
    }

    init(
        step: Int,
        tool: ComputerUseToolName,
        status: String,
        message: String,
        appName: String? = nil,
        bundleID: String? = nil,
        windowTitle: String? = nil,
        snapshotID: String? = nil
    ) {
        self.step = step
        self.tool = tool
        self.status = status
        self.message = message
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.snapshotID = snapshotID
    }
}

typealias ComputerUseToolResult = ComputerUseToolOutcome

struct ComputerUsePlannerRequest: Codable, Equatable {
    let command: String
    let step: Int
    let maxSteps: Int?
    let toolCatalogVersion: String
    let toolCatalog: String
    let latestWindowState: ComputerUseWindowState
    let priorOutcomes: [ComputerUseToolOutcome]

    enum CodingKeys: String, CodingKey {
        case command
        case step
        case maxSteps = "max_steps"
        case toolCatalogVersion = "tool_catalog_version"
        case toolCatalog = "tool_catalog"
        case latestWindowState = "latest_window_state"
        case priorOutcomes = "prior_tool_outcomes"
    }

    init(
        command: String,
        step: Int,
        maxSteps: Int?,
        toolCatalogVersion: String = ComputerUseToolRegistry.catalogVersion,
        toolCatalog: String = ComputerUseToolRegistry.promptDocumentation(),
        latestWindowState: ComputerUseWindowState,
        priorOutcomes: [ComputerUseToolOutcome]
    ) {
        self.command = command
        self.step = step
        self.maxSteps = maxSteps
        self.toolCatalogVersion = toolCatalogVersion
        self.toolCatalog = toolCatalog
        self.latestWindowState = latestWindowState
        self.priorOutcomes = priorOutcomes
    }

    var observation: ComputerUseObservation {
        latestWindowState.observation
    }
}
