import Foundation
import MuesliCore

/// A plain copy of one Accessibility element, captured by `PhoneCallerAXReader`.
struct CallerAXNode: Equatable, Sendable {
    var role: String?
    var subrole: String?
    var identifier: String?
    var title: String?
    var value: String?
    var description: String?
    var children: [CallerAXNode]
    /// Keypad controls found inside parser-opaque containers.
    var keypadKeyCount: Int = 0
}

enum CallerUnavailableReason: String, Sendable {
    case appNotRunning
    case noActiveCall
    case noHandle
    case incomplete
}

enum CallerCaptureResult: Equatable, Sendable {
    case identified(CallerHandle)
    case unavailable(CallerUnavailableReason)
    case ambiguous
    case permissionRequired
}

/// Finds the caller shown for the Phone app's active call.
///
/// The Phone app's live-call layout is not documented, so these rules prefer a
/// missed caller over a wrong one: a handle counts only when it is static text
/// close to an end-call control, outside lists, tables and editable fields.
enum PhoneCallerParser {
    private static let endLabels: Set<String> = ["end", "end call", "hang up"]
    private static let endIdentifierFragments = ["endcall", "hangup"]
    /// A call area must not contain any of these: they hold recents, contacts
    /// or search results rather than the active call.
    private static let excludedContainerRoles: Set<String> = [
        "AXTable", "AXOutline", "AXList", "AXBrowser", "AXScrollArea", "AXGrid", "AXRow", "AXCell",
    ]
    /// List-like SwiftUI and Catalyst containers that report a generic role.
    private static let excludedContainerSubroles: Set<String> = [
        "AXCollectionList", "AXSectionList", "AXContentList",
    ]
    /// Text under these is never read as the caller.
    private static let skippedRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
        "AXTable", "AXOutline", "AXList", "AXGrid", "AXRow", "AXCell", "AXMenu", "AXButton",
    ]
    private static let maxCallAreaLevels = 3
    private static let keypadLabels: Set<String> = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#"]
    static let keypadMinimumKeys = 10

    static func isOpaqueContainerRole(_ role: String?, subrole: String? = nil) -> Bool {
        if let role, excludedContainerRoles.contains(role) { return true }
        if let subrole, excludedContainerSubroles.contains(subrole) { return true }
        return false
    }

    static func isKeypadButton(_ node: CallerAXNode) -> Bool {
        node.role == "AXButton" && [node.title, node.description, node.identifier].contains {
            guard let label = $0?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return keypadLabels.contains(label)
        }
    }

    static func parse(windows: [CallerAXNode], region: String?) -> CallerCaptureResult {
        var areas: [[Int]: CallerAXNode] = [:]
        var windowsWithCalls: Set<Int> = []
        var endCallControlCount = 0
        for (index, window) in windows.enumerated() {
            visit(window, path: [index], ancestors: []) { node, ancestors in
                guard isEndControl(node), let area = callArea(ancestors: ancestors) else { return }
                endCallControlCount += 1
                areas[area.path] = area.node
                windowsWithCalls.insert(index)
            }
        }
        guard !areas.isEmpty else { return .unavailable(.noActiveCall) }
        guard endCallControlCount == areas.count else { return .ambiguous }
        // A visible keypad means a number may be digits the user typed.
        guard !windowsWithCalls.contains(where: { keypadKeyCount(windows[$0]) >= keypadMinimumKeys }) else {
            return .ambiguous
        }

        let perArea = areas.keys.sorted { $0.lexicographicallyPrecedes($1) }.map { handles(in: areas[$0]!, region: region) }
        if perArea.allSatisfy(\.isEmpty) { return .unavailable(.noHandle) }
        // Several call areas (say, a compact call window and the main window)
        // only count when every one shows the same single caller.
        guard perArea.allSatisfy({ $0.count == 1 }),
              Set(perArea.map { $0[0].key }).count == 1 else {
            return .ambiguous
        }
        return .identified(perArea[0][0])
    }

    private static func handles(in area: CallerAXNode, region: String?) -> [CallerHandle] {
        var handles: [CallerHandle] = []
        collectText(area) { text in
            guard let handle = CallerHandleNormalizer.handle(text, region: region),
                  !handles.contains(where: { $0.key == handle.key }) else { return }
            handles.append(handle)
        }
        return handles
    }

    private typealias Located = (node: CallerAXNode, path: [Int])

    private static func visit(
        _ node: CallerAXNode,
        path: [Int],
        ancestors: [Located],
        _ body: (CallerAXNode, [Located]) -> Void
    ) {
        body(node, ancestors)
        let lineage = ancestors + [(node, path)]
        for (index, child) in node.children.enumerated() {
            visit(child, path: path + [index], ancestors: lineage, body)
        }
    }

    private static func isEndControl(_ node: CallerAXNode) -> Bool {
        guard node.role == "AXButton" else { return false }
        let labels = [node.identifier, node.title, node.description].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if labels.contains(where: { endLabels.contains($0) }) { return true }
        let identifier = node.identifier?.lowercased() ?? ""
        return endIdentifierFragments.contains { identifier.contains($0) }
    }

    /// Grows upward from the end control's parent, stopping before the window
    /// root or any ancestor that contains a list-like container.
    private static func callArea(ancestors: [Located]) -> Located? {
        var area: Located?
        for level in 1...maxCallAreaLevels {
            let index = ancestors.count - level
            guard index >= 1, !containsExcludedContainer(ancestors[index].node) else { break }
            area = ancestors[index]
        }
        return area
    }

    private static func containsExcludedContainer(_ node: CallerAXNode) -> Bool {
        if let role = node.role, excludedContainerRoles.contains(role) { return true }
        if let subrole = node.subrole, excludedContainerSubroles.contains(subrole) { return true }
        return node.children.contains(where: containsExcludedContainer)
    }

    private static func keypadKeyCount(_ node: CallerAXNode) -> Int {
        node.keypadKeyCount + (isKeypadButton(node) ? 1 : 0)
            + node.children.reduce(0) { $0 + keypadKeyCount($1) }
    }

    private static func collectText(_ node: CallerAXNode, _ body: (String) -> Void) {
        if let role = node.role, skippedRoles.contains(role) { return }
        if let subrole = node.subrole, excludedContainerSubroles.contains(subrole) { return }
        if node.role == "AXStaticText", let text = node.value ?? node.title {
            body(text)
        }
        for child in node.children {
            collectText(child, body)
        }
    }
}
