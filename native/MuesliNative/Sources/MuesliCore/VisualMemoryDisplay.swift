import Foundation
import CoreGraphics

/// Physical display identity is separate from the apps represented by its image.
public struct VisualMemoryDisplay: Codable, Sendable, Equatable {
    public let id: UInt32
    public let uuid: String
    public let name: String
    public init(id: UInt32, uuid: String, name: String) {
        self.id = id; self.uuid = uuid; self.name = name
    }
}

public struct VisualMemoryApp: Codable, Sendable, Equatable, Hashable {
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) { self.bundleID = bundleID; self.name = name }
}

/// Pure policy shared by capture planning and synthetic multi-monitor regressions.
public enum VisualMemoryDisplayPolicy {
    /// Selection never falls back to an unselected display after disconnection.
    public static func selects(uuid: String, scope: String, selected: Set<String>) -> Bool {
        scope == "all_displays" || (scope == "selected_displays" && selected.contains(uuid))
    }

    public static func includes(window: CGRect, layer: Int, display: CGRect,
                                bundleID: String, title: String, excluded: Set<String>) -> Bool {
        guard layer == 0, !bundleID.isEmpty, !excluded.contains(bundleID),
              window.width >= 100, window.height >= 100 else { return false }
        let overlap = window.intersection(display)
        return !overlap.isNull && overlap.width > 0 && overlap.height > 0 && !isPrivate(title)
    }

    public static func isPrivate(_ title: String) -> Bool {
        ["incognito", "private browsing", "inprivate"].contains { title.localizedCaseInsensitiveContains($0) }
    }
}

/// Deduplication is per display and is committed only after the media/store write succeeds.
public struct VisualMemoryDisplayChanges: Sendable {
    private struct Value: Equatable, Sendable { let fingerprint: Data; let text: String; let source: String }
    private var saved: [String: Value] = [:]
    public init() {}
    public func isUnchanged(display: String, fingerprint: Data, text: String, source: String) -> Bool {
        saved[display] == Value(fingerprint: fingerprint, text: text, source: source)
    }
    public mutating func record(display: String, fingerprint: Data, text: String, source: String) {
        saved[display] = Value(fingerprint: fingerprint, text: text, source: source)
    }
    public mutating func retain(displays: Set<String>) { saved = saved.filter { displays.contains($0.key) } }
}
