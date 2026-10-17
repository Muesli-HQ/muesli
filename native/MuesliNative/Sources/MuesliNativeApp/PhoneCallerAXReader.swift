import AppKit
import ApplicationServices
import Foundation
import MuesliCore

enum CallerAXRead<T> {
    case success(T)
    /// The attribute is unsupported or has no value.
    case missing
    /// The request failed or timed out; the snapshot can no longer be trusted.
    case failed
}

struct CallerAXAttributes: Equatable, Sendable {
    var role: String?
    var subrole: String?
    var identifier: String?
    var title: String?
    var value: String?
    var description: String?
}

/// One element's attributes and up to `childLimit` of its children.
struct CallerAXNodeRead<Element> {
    var attributes: CallerAXAttributes
    var children: [Element]
    /// The element had more children than were returned.
    var truncated: Bool
}

/// The Accessibility calls the reader needs, injectable for tests.
protocol CallerAXClient: Sendable {
    associatedtype Element
    func isTrusted() -> Bool
    func phoneAppPIDs() -> [pid_t]
    func windows(pid: pid_t, deadline: TimeInterval) -> CallerAXRead<[Element]>
    /// Reads an element in a single request: a Phone window has hundreds of
    /// nodes, so one round trip per attribute would not fit the time budget.
    func node(_ element: Element, childLimit: Int, deadline: TimeInterval) -> CallerAXRead<CallerAXNodeRead<Element>>
    func now() -> TimeInterval
}

enum PhoneCallerAXLimits {
    static let maxDepth = 12
    static let maxNodes = 500
    static let maxChildren = 50
    static let totalSeconds: TimeInterval = 1.0
    static let requestSeconds: TimeInterval = 0.1
    static let maxStringLength = 256
}

/// Takes a bounded snapshot of the Phone app and parses the active caller.
/// Any failed read, timeout or limit makes the snapshot incomplete, because a
/// second call or handle could be hidden in what was not read. Synchronous;
/// callers run it off the main actor.
struct PhoneCallerAXReader<Client: CallerAXClient>: Sendable {
    static var phoneBundleID: String { "com.apple.mobilephone" }

    let client: Client
    let region: String?

    init(client: Client, region: String? = Locale.current.region?.identifier) {
        self.client = client
        self.region = region
    }

    func capture() -> CallerCaptureResult {
        guard client.isTrusted() else { return .permissionRequired }
        let pids = client.phoneAppPIDs()
        guard let pid = pids.first else { return .unavailable(.appNotRunning) }
        guard pids.count == 1 else { return .ambiguous }

        let deadline = client.now() + PhoneCallerAXLimits.totalSeconds
        let windows: [Client.Element]
        switch client.windows(pid: pid, deadline: deadline) {
        case .success(let elements): windows = elements
        case .missing: windows = []
        case .failed: return .unavailable(.incomplete)
        }

        var nodeCount = 0
        var snapshot: [CallerAXNode] = []
        for window in windows {
            guard let node = snapshotNode(window, depth: 0, nodeCount: &nodeCount, deadline: deadline) else {
                return .unavailable(.incomplete)
            }
            snapshot.append(node)
        }
        return PhoneCallerParser.parse(windows: snapshot, region: region)
    }

    private func snapshotNode(
        _ element: Client.Element,
        depth: Int,
        nodeCount: inout Int,
        deadline: TimeInterval
    ) -> CallerAXNode? {
        guard depth <= PhoneCallerAXLimits.maxDepth,
              nodeCount < PhoneCallerAXLimits.maxNodes,
              client.now() < deadline else {
            return nil
        }
        nodeCount += 1

        let read: CallerAXNodeRead<Client.Element>
        switch client.node(element, childLimit: PhoneCallerAXLimits.maxChildren, deadline: deadline) {
        case .success(let value): read = value
        case .missing: read = CallerAXNodeRead(attributes: CallerAXAttributes(), children: [], truncated: false)
        case .failed: return nil
        }
        let attributes = read.attributes
        if PhoneCallerParser.isOpaqueContainerRole(attributes.role, subrole: attributes.subrole) {
            var probedNodes = 0
            let keypadKeyCount = probeKeypadKeyCount(
                element,
                depth: depth,
                nodeCount: &probedNodes,
                deadline: deadline,
                isRoot: true
            ) ?? PhoneCallerParser.keypadMinimumKeys
            return CallerAXNode(
                role: attributes.role,
                subrole: attributes.subrole,
                identifier: attributes.identifier,
                title: attributes.title,
                value: attributes.value,
                description: attributes.description,
                children: [],
                keypadKeyCount: keypadKeyCount
            )
        }
        guard !read.truncated else { return nil }

        var children: [CallerAXNode] = []
        for child in read.children {
            guard let node = snapshotNode(child, depth: depth + 1, nodeCount: &nodeCount, deadline: deadline) else {
                return nil
            }
            children.append(node)
        }

        return CallerAXNode(
            role: attributes.role,
            subrole: attributes.subrole,
            identifier: attributes.identifier,
            title: attributes.title,
            value: attributes.value,
            description: attributes.description,
            children: children
        )
    }

    /// Counts keypad controls inside an opaque container without including its
    /// subtree in the caller parser's snapshot. If a bounded probe is incomplete,
    /// the result conservatively blocks identification as a possible keypad.
    private func probeKeypadKeyCount(
        _ element: Client.Element,
        depth: Int,
        nodeCount: inout Int,
        deadline: TimeInterval,
        isRoot: Bool = false
    ) -> Int? {
        guard depth <= PhoneCallerAXLimits.maxDepth,
              nodeCount < PhoneCallerAXLimits.maxNodes,
              client.now() < deadline else {
            return nil
        }
        nodeCount += 1

        let childLimit = isRoot ? PhoneCallerAXLimits.maxNodes : PhoneCallerAXLimits.maxChildren
        let read: CallerAXNodeRead<Client.Element>
        switch client.node(element, childLimit: childLimit, deadline: deadline) {
        case .success(let value): read = value
        case .missing: return 0
        case .failed: return nil
        }
        guard !read.truncated else { return nil }

        let keypadNode = CallerAXNode(
            role: read.attributes.role,
            subrole: read.attributes.subrole,
            identifier: read.attributes.identifier,
            title: read.attributes.title,
            value: read.attributes.value,
            description: read.attributes.description,
            children: []
        )
        var count = PhoneCallerParser.isKeypadButton(keypadNode) ? 1 : 0
        if count >= PhoneCallerParser.keypadMinimumKeys { return count }
        for child in read.children {
            guard let childCount = probeKeypadKeyCount(
                child,
                depth: depth + 1,
                nodeCount: &nodeCount,
                deadline: deadline
            ) else {
                return nil
            }
            count += childCount
            if count >= PhoneCallerParser.keypadMinimumKeys { return count }
        }
        return count
    }
}

/// Public Accessibility API client. Every element gets its own messaging
/// timeout before each request, since a timeout set on one element does not
/// apply to others.
struct SystemCallerAXClient: CallerAXClient {
    typealias Element = AXUIElement

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func phoneAppPIDs() -> [pid_t] {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: PhoneCallerAXReader<Self>.phoneBundleID)
            .filter { !$0.isTerminated }
            .map(\.processIdentifier)
    }

    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func windows(pid: pid_t, deadline: TimeInterval) -> CallerAXRead<[AXUIElement]> {
        switch elements(of: AXUIElementCreateApplication(pid), attribute: kAXWindowsAttribute, deadline: deadline) {
        case .success(let read): return read.truncated ? .failed : .success(read.elements)
        case .missing: return .missing
        case .failed: return .failed
        }
    }

    func node(
        _ element: AXUIElement,
        childLimit: Int,
        deadline: TimeInterval
    ) -> CallerAXRead<CallerAXNodeRead<AXUIElement>> {
        let fields: [WritableKeyPath<CallerAXAttributes, String?>] = [
            \.role, \.subrole, \.identifier, \.title, \.value, \.description,
        ]
        let names = [
            kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute,
            kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute,
        ]
        guard prepare(element, deadline: deadline) else { return .failed }
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &values
        ) == .success, let read = values as? [AnyObject], read.count == names.count else {
            return .failed
        }

        var attributes = CallerAXAttributes()
        for (index, field) in fields.enumerated() {
            switch Self.decode(read[index]) {
            case .failed: return .failed
            case .missing: continue
            case .success(let value):
                if let text = value as? String {
                    attributes[keyPath: field] = String(text.prefix(PhoneCallerAXLimits.maxStringLength))
                }
            }
        }

        switch Self.decode(read[fields.count]) {
        case .failed:
            return .failed
        case .missing:
            return .success(CallerAXNodeRead(attributes: attributes, children: [], truncated: false))
        case .success(let value):
            guard let array = value as? [AnyObject] else { return .failed }
            var children: [AXUIElement] = []
            for item in array.prefix(childLimit) {
                guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return .failed }
                children.append(item as! AXUIElement)
            }
            return .success(CallerAXNodeRead(
                attributes: attributes,
                children: children,
                truncated: array.count > childLimit
            ))
        }
    }

    /// Multiple-attribute reads report a per-attribute failure as an AXValue
    /// wrapping an AXError instead of failing the whole request.
    private static func decode(_ value: AnyObject) -> CallerAXRead<AnyObject> {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return .success(value) }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .axError else { return .success(value) }
        var error = AXError.success
        guard AXValueGetValue(axValue, .axError, &error) else { return .failed }
        switch error {
        case .attributeUnsupported, .noValue: return .missing
        default: return .failed
        }
    }

    private func elements(
        of element: AXUIElement,
        attribute: String,
        limit: Int = PhoneCallerAXLimits.maxChildren,
        deadline: TimeInterval
    ) -> CallerAXRead<(elements: [AXUIElement], truncated: Bool)> {
        guard prepare(element, deadline: deadline) else { return .failed }
        var count: CFIndex = 0
        switch AXUIElementGetAttributeValueCount(element, attribute as CFString, &count) {
        case .success: break
        case .attributeUnsupported, .noValue: return .missing
        default: return .failed
        }
        guard count > 0 else { return .missing }
        guard prepare(element, deadline: deadline) else { return .failed }
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(
            element,
            attribute as CFString,
            0,
            min(count, limit + 1),
            &values
        ) == .success, let read = values as? [AnyObject] else {
            return .failed
        }
        var elements: [AXUIElement] = []
        for item in read.prefix(limit) {
            // A cast to a CF type always succeeds, so check the real type.
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return .failed }
            elements.append(item as! AXUIElement)
        }
        return .success((elements, count > limit))
    }

    private func prepare(_ element: AXUIElement, deadline: TimeInterval) -> Bool {
        let remaining = deadline - now()
        guard remaining > 0 else { return false }
        let timeout = Float(min(PhoneCallerAXLimits.requestSeconds, remaining))
        return AXUIElementSetMessagingTimeout(element, timeout) == .success
    }
}
