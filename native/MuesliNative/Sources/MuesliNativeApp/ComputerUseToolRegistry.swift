import Foundation

struct ComputerUseToolDefinition: Codable, Equatable {
    let name: ComputerUseToolName
    let description: String
    let schema: ComputerUseToolSchema
    let riskPolicy: String
    let mutating: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case schema
        case riskPolicy = "risk_policy"
        case mutating
    }
}

struct ComputerUseToolSchema: Codable, Equatable {
    let type: String
    let properties: [String: ComputerUseToolSchemaProperty]
    let required: [String]
    let additionalProperties: Bool

    init(
        properties: [String: ComputerUseToolSchemaProperty],
        required: [String]
    ) {
        type = "object"
        self.properties = properties
        self.required = required
        additionalProperties = false
    }
}

struct ComputerUseToolSchemaProperty: Codable, Equatable {
    let type: String
    let description: String
    let enumValues: [String]?
    let items: ComputerUseToolSchemaArrayItems?

    enum CodingKeys: String, CodingKey {
        case type
        case description
        case enumValues = "enum"
        case items
    }

    init(
        type: String,
        description: String,
        enumValues: [String]? = nil,
        items: ComputerUseToolSchemaArrayItems? = nil
    ) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.items = items
    }
}

struct ComputerUseToolSchemaArrayItems: Codable, Equatable {
    let type: String
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case enumValues = "enum"
    }
}

enum ComputerUseToolRegistry {
    static let catalogVersion = "muesli-cua-tools-v1"

    static let definitions: [ComputerUseToolDefinition] = [
        definition(.listApps, "List running desktop apps with names, bundle IDs, process IDs, and active state.", required: [], properties: [:], risk: "safe read-only"),
        definition(.launchApp, "Launch or activate a macOS app by app_name or app_bundle_id.", required: [], properties: [
            "app_name": .string("Human app name, for example Google Chrome."),
            "app_bundle_id": .string("Bundle identifier, for example com.google.Chrome."),
        ], risk: "foreground activation allowed"),
        definition(.listWindows, "List visible windows, optionally scoped by app_bundle_id.", required: [], properties: [
            "app_bundle_id": .string("Optional bundle identifier to scope windows."),
        ], risk: "safe read-only"),
        definition(.getWindowState, "Capture the active window state: screenshot metadata, screenshot image for the planner, AX candidates, cursor, app, and window metadata.", required: [], properties: [
            "app_bundle_id": .string("Optional app bundle to activate before capture."),
            "window_id": .integer("Optional window id hint."),
        ], risk: "safe read-only"),
        definition(.moveCursor, "Move the visible Muesli CUA cursor to a screenshot coordinate without clicking. Use this before uncertain coordinate clicks to show intent.", required: ["screenshot_id", "x", "y"], properties: [
            "screenshot_id": .string("Current screenshot id."),
            "x": .number("Screenshot pixel x coordinate."),
            "y": .number("Screenshot pixel y coordinate."),
            "label": .string("Human target label for live feedback and trace."),
        ], risk: "visual feedback only"),
        definition(.click, "Click exactly one target: either an AX element from the latest get_window_state by element_index/element_id, or a screenshot coordinate when no AX target exists. Do not send both an element target and x/y.", required: [], properties: [
            "element_index": .integer("Temporary element index from the latest state. Element-indexed clicks are scoped to the current snapshot and expire after a new get_window_state."),
            "element_id": .string("Temporary element id from the latest state, for example e12. Use only when x/y are absent."),
            "screenshot_id": .string("Required current screenshot id when using x/y coordinates."),
            "x": .number("Screenshot pixel x coordinate. Use only with y and screenshot_id, and only when element_index/element_id are absent."),
            "y": .number("Screenshot pixel y coordinate. Use only with x and screenshot_id, and only when element_index/element_id are absent."),
            "clicks": .integer("1 for single click, 2 for double click."),
            "button": .string("left or right."),
            "label": .string("Human target label for trace and safety."),
        ], risk: "rejects mixed element/coordinate addressing; confirmation for risky labels or unknown coordinate targets"),
        definition(.setValue, "Set an AX element value by element_index/element_id from the latest state.", required: ["value"], properties: [
            "element_index": .integer("Temporary element index from the latest state."),
            "element_id": .string("Temporary element id from the latest state."),
            "value": .string("Value to set."),
            "label": .string("Human target label for trace."),
        ], risk: "local validation only; no send/submit bypass"),
        definition(.typeText, "Type literal text using keyboard input. Prefer app_name/app_bundle_id and, when available, element_index/element_id so Muesli can activate the app and focus the editable target before typing.", required: ["text"], properties: [
            "app_name": .string("Optional target app name, for example Notes."),
            "app_bundle_id": .string("Optional target app bundle identifier, for example com.apple.Notes."),
            "element_index": .integer("Optional temporary editable element index from the latest state."),
            "element_id": .string("Optional temporary editable element id from the latest state."),
            "text": .string("Text to type."),
            "label": .string("Human target label for trace."),
        ], risk: "safe primitive; activates optional app target and requires focused editable text"),
        definition(.pasteText, "Paste text into the focused editable field using the clipboard, then restore the user's clipboard. Prefer app_name/app_bundle_id and element_index/element_id when available. Prefer this for Apple Notes, native rich-text editors, and multi-word text insertion after focusing the editable target.", required: ["text"], properties: [
            "app_name": .string("Optional target app name, for example Notes."),
            "app_bundle_id": .string("Optional target app bundle identifier, for example com.apple.Notes."),
            "element_index": .integer("Optional temporary editable element index from the latest state."),
            "element_id": .string("Optional temporary editable element id from the latest state."),
            "text": .string("Text to paste."),
            "label": .string("Human target label for trace."),
        ], risk: "safe primitive; temporarily uses clipboard and restores it"),
        definition(.pressKey, "Press one key with optional modifiers.", required: ["key"], properties: [
            "key": .string("Key name, for example enter, tab, l, escape."),
            "modifiers": .array("Optional modifiers.", item: .string("Modifier", enumValues: ComputerUseKeyModifier.allCases.map(\.rawValue))),
        ], risk: "confirmation for Cmd-Q and Cmd-W"),
        definition(.hotkey, "Alias for press_key used for keyboard shortcuts.", required: ["key"], properties: [
            "key": .string("Key name."),
            "modifiers": .array("Required or optional modifiers.", item: .string("Modifier", enumValues: ComputerUseKeyModifier.allCases.map(\.rawValue))),
        ], risk: "confirmation for Cmd-Q and Cmd-W"),
        definition(.scroll, "Scroll the current view.", required: ["direction"], properties: [
            "direction": .string("Scroll direction.", enumValues: ["up", "down", "left", "right"]),
            "pages": .number("Approximate page count, default 1."),
        ], risk: "safe primitive"),
        definition(.drag, "Drag from one screenshot coordinate to another.", required: ["screenshot_id", "x", "y", "to_x", "to_y"], properties: [
            "screenshot_id": .string("Current screenshot id."),
            "x": .number("Start screenshot pixel x."),
            "y": .number("Start screenshot pixel y."),
            "to_x": .number("End screenshot pixel x."),
            "to_y": .number("End screenshot pixel y."),
            "label": .string("Human target label for trace and safety."),
        ], risk: "confirmation for risky labels"),
        definition(.listBrowserTabs, "List tabs in Chrome-compatible browser windows.", required: ["app_bundle_id"], properties: [
            "app_bundle_id": .string("Browser bundle identifier, currently com.google.Chrome."),
        ], risk: "safe read-only"),
        definition(.activateBrowserTab, "Activate a browser tab by window_index and tab_index.", required: ["app_bundle_id", "window_index", "tab_index"], properties: [
            "app_bundle_id": .string("Browser bundle identifier, currently com.google.Chrome."),
            "window_index": .integer("1-based browser window index."),
            "tab_index": .integer("1-based tab index in the window."),
        ], risk: "foreground activation allowed"),
        definition(.navigateURL, "Navigate the selected browser tab to a safe http/https URL.", required: ["app_bundle_id", "url"], properties: [
            "app_bundle_id": .string("Browser bundle identifier, currently com.google.Chrome."),
            "window_index": .integer("Optional 1-based browser window index."),
            "tab_index": .integer("Optional 1-based tab index."),
            "url": .string("http or https URL only."),
        ], risk: "rejects javascript:, file:, data:, shell-like strings, and unsafe URLs"),
        definition(.pageGetText, "Read visible/body text from a Chrome tab using read-only Apple Events JavaScript.", required: ["app_bundle_id"], properties: [
            "app_bundle_id": .string("Browser bundle identifier, currently com.google.Chrome."),
            "window_index": .integer("Optional 1-based browser window index."),
            "tab_index": .integer("Optional 1-based tab index."),
        ], risk: "safe read-only"),
        definition(.pageQueryDOM, "Query DOM nodes in a Chrome tab and return text plus selected attributes. Read-only only.", required: ["app_bundle_id", "selector"], properties: [
            "app_bundle_id": .string("Browser bundle identifier, currently com.google.Chrome."),
            "window_index": .integer("Optional 1-based browser window index."),
            "tab_index": .integer("Optional 1-based tab index."),
            "selector": .string("CSS selector."),
            "attributes": .array("Attributes to return.", item: .string("Attribute name.")),
        ], risk: "safe read-only"),
        definition(.finish, "Finish when the user task is complete. Use reason for the final answer.", required: [], properties: [
            "reason": .string("Final user-facing result."),
        ], risk: "safe finalization"),
        definition(.fail, "Fail explicitly when blocked, unsupported, unsafe, or incomplete. Use reason to explain.", required: ["reason"], properties: [
            "reason": .string("Failure reason."),
        ], risk: "safe finalization"),
    ]

    static func definition(for tool: ComputerUseToolName) -> ComputerUseToolDefinition? {
        definitions.first { $0.name == tool }
    }

    static func promptDocumentation() -> String {
        definitions.map { definition in
            let required = definition.schema.required.isEmpty ? "none" : definition.schema.required.joined(separator: ", ")
            let properties = definition.schema.properties
                .sorted { $0.key < $1.key }
                .map { key, property in
                    var line = "  - \(key): \(property.type). \(property.description)"
                    if let values = property.enumValues {
                        line += " Allowed: \(values.joined(separator: ", "))."
                    }
                    return line
                }
                .joined(separator: "\n")
            let propertyText = properties.isEmpty ? "  - no arguments" : properties
            return """
            Tool: \(definition.name.rawValue)
            Description: \(definition.description)
            Required: \(required)
            Risk policy: \(definition.riskPolicy)
            Schema properties:
            \(propertyText)
            """
        }.joined(separator: "\n\n")
    }

    static func nativeToolDefinitions() -> [[String: Any]] {
        definitions.map { definition in
            [
                "type": "function",
                "name": definition.name.rawValue,
                "description": "\(definition.description) Risk policy: \(definition.riskPolicy)",
                "parameters": toolParameters(for: definition),
            ]
        }
    }

    private static func toolParameters(for definition: ComputerUseToolDefinition) -> [String: Any] {
        let properties = definition.schema.properties
            .filter { $0.key != "tool" }
            .reduce(into: [String: Any]()) { partial, entry in
                partial[entry.key] = entry.value.jsonSchema
            }
        return [
            "type": definition.schema.type,
            "properties": properties,
            "required": definition.schema.required.filter { $0 != "tool" },
            "additionalProperties": definition.schema.additionalProperties,
        ]
    }

    private static func definition(
        _ name: ComputerUseToolName,
        _ description: String,
        required: [String],
        properties: [String: ComputerUseToolSchemaProperty],
        risk: String
    ) -> ComputerUseToolDefinition {
        ComputerUseToolDefinition(
            name: name,
            description: description,
            schema: ComputerUseToolSchema(
                properties: ["tool": .string("Tool name.", enumValues: [name.rawValue])].merging(properties) { current, _ in current },
                required: ["tool"] + required
            ),
            riskPolicy: risk,
            mutating: ComputerUseToolInvocation(tool: name).isMutating
        )
    }
}

private extension ComputerUseToolSchemaProperty {
    static func string(_ description: String, enumValues: [String]? = nil) -> ComputerUseToolSchemaProperty {
        ComputerUseToolSchemaProperty(type: "string", description: description, enumValues: enumValues)
    }

    static func integer(_ description: String) -> ComputerUseToolSchemaProperty {
        ComputerUseToolSchemaProperty(type: "integer", description: description)
    }

    static func number(_ description: String) -> ComputerUseToolSchemaProperty {
        ComputerUseToolSchemaProperty(type: "number", description: description)
    }

    static func array(_ description: String, item: ComputerUseToolSchemaProperty) -> ComputerUseToolSchemaProperty {
        ComputerUseToolSchemaProperty(
            type: "array",
            description: description,
            items: ComputerUseToolSchemaArrayItems(type: item.type, enumValues: item.enumValues)
        )
    }

    var jsonSchema: [String: Any] {
        var schema: [String: Any] = [
            "type": type,
            "description": description,
        ]
        if let enumValues {
            schema["enum"] = enumValues
        }
        if let items {
            var itemSchema: [String: Any] = ["type": items.type]
            if let enumValues = items.enumValues {
                itemSchema["enum"] = enumValues
            }
            schema["items"] = itemSchema
        }
        return schema
    }
}
