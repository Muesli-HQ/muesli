import Foundation
import os

/// Numeric performance markers only. Never attach audio, text or token IDs.
enum BodhanProfiling {
    private static let log = OSLog(subsystem: "com.muesli.bodhan", category: .pointsOfInterest)
    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }
    static func end(_ name: StaticString, _ id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
    static func measure<T>(_ name: StaticString, _ operation: () throws -> T) rethrows -> T {
        let id = begin(name)
        defer { end(name, id) }
        return try operation()
    }
}
