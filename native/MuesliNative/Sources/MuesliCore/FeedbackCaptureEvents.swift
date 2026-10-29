import Foundation

/// Only pointer gestures are represented. Coordinates use the fixed display's top-left origin.
public struct FeedbackCaptureEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case click, drag, scroll }
    public var kind: Kind
    public var t: Int64
    public var t1: Int64?
    public var x: Double, y: Double
    public var x1: Double?, y1: Double?
    public var button: Int?
    public var dx: Double?, dy: Double?
    public var end: Int64 { t1 ?? t }
    public static func click(t: Int64, x: Double, y: Double, button: Int, t1: Int64? = nil) -> Self {
        Self(kind: .click, t: t, t1: t1, x: x, y: y, button: button)
    }
    public static func drag(t: Int64, t1: Int64, x0: Double, y0: Double, x1: Double, y1: Double) -> Self {
        Self(kind: .drag, t: t, t1: t1, x: x0, y: y0, x1: x1, y1: y1)
    }
    public static func scroll(t: Int64, x: Double, y: Double, dx: Double, dy: Double) -> Self {
        Self(kind: .scroll, t: t, x: x, y: y, dx: dx, dy: dy)
    }
    private enum CodingKeys: String, CodingKey { case kind, t, t1, x, y, x0, y0, x1, y1, button, dx, dy }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        t = try c.decode(Int64.self, forKey: .t)
        t1 = try c.decodeIfPresent(Int64.self, forKey: .t1)
        x = try c.decode(Double.self, forKey: kind == .drag ? .x0 : .x)
        y = try c.decode(Double.self, forKey: kind == .drag ? .y0 : .y)
        if kind == .click { button = try c.decode(Int.self, forKey: .button) }
        if kind == .drag {
            t1 = try c.decode(Int64.self, forKey: .t1)
            x1 = try c.decode(Double.self, forKey: .x1); y1 = try c.decode(Double.self, forKey: .y1)
        }
        if kind == .scroll { dx = try c.decode(Double.self, forKey: .dx); dy = try c.decode(Double.self, forKey: .dy) }
        // Context samples 250 ms after release; that offset must remain representable.
        guard t >= 0, end >= t, !end.addingReportingOverflow(250).overflow,
              [x, y, x1 ?? 0, y1 ?? 0].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              (dx ?? 0).isFinite, (dy ?? 0).isFinite else {
            throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "Invalid pointer event")
        }
    }
    private init(kind: Kind, t: Int64, t1: Int64? = nil, x: Double, y: Double,
                 x1: Double? = nil, y1: Double? = nil, button: Int? = nil, dx: Double? = nil, dy: Double? = nil) {
        self.kind = kind; self.t = t; self.t1 = t1; self.x = x; self.y = y
        self.x1 = x1; self.y1 = y1; self.button = button; self.dx = dx; self.dy = dy
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(t, forKey: .t); try c.encodeIfPresent(t1, forKey: .t1)
        try c.encode(x, forKey: kind == .drag ? .x0 : .x); try c.encode(y, forKey: kind == .drag ? .y0 : .y)
        try c.encodeIfPresent(x1, forKey: .x1); try c.encodeIfPresent(y1, forKey: .y1)
        try c.encodeIfPresent(button, forKey: .button); try c.encodeIfPresent(dx, forKey: .dx); try c.encodeIfPresent(dy, forKey: .dy)
    }
}

public struct FeedbackCaptureEvents: Sendable {
    public enum Phase: Sendable { case down, moved, up, scroll }
    private struct Press: Sendable { let t: Int64; let x: Double, y: Double; var travel: Double }
    private var presses: [Int: Press] = [:]
    private let target: FeedbackCaptureTarget
    public init(target: FeedbackCaptureTarget) { self.target = target }
    public mutating func receive(_ phase: Phase, t: Int64, x: Double, y: Double, button: Int = 0,
                                 dx: Double = 0, dy: Double = 0, excluded: Bool = false) -> FeedbackCaptureEvent? {
        let f = target.frame
        guard t >= 0, x.isFinite, y.isFinite, f.width > 0, f.height > 0 else { return nil }
        let inside = x >= f.x && x < f.x + f.width && y >= f.y && y < f.y + f.height
        func norm(_ x: Double, _ y: Double) -> (Double, Double) {
            (min(1, max(0, (x - f.x) / f.width)), min(1, max(0, (y - f.y) / f.height)))
        }
        switch phase {
        case .down:
            presses[button] = inside && !excluded ? Press(t: t, x: x, y: y, travel: 0) : nil
        case .moved:
            if var press = presses[button] {
                press.travel = max(press.travel, hypot(x - press.x, y - press.y)); presses[button] = press
            }
        case .up:
            guard let press = presses.removeValue(forKey: button), t >= press.t else { return nil }
            let start = norm(press.x, press.y), end = norm(x, y)
            if max(press.travel, hypot(x - press.x, y - press.y)) < 12 {
                return .click(t: press.t, x: start.0, y: start.1, button: button, t1: t)
            }
            return .drag(t: press.t, t1: t, x0: start.0, y0: start.1, x1: end.0, y1: end.1)
        case .scroll:
            guard inside, !excluded, dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return nil }
            let point = norm(x, y)
            return .scroll(t: t, x: point.0, y: point.1, dx: dx, dy: dy)
        }
        return nil
    }
    public static func merge(_ events: [FeedbackCaptureEvent], target: FeedbackCaptureTarget) -> [FeedbackCaptureEvent] {
        var result: [FeedbackCaptureEvent] = []
        let ordered = events.enumerated().sorted { $0.element.t == $1.element.t ? $0.offset < $1.offset : $0.element.t < $1.element.t }
        for entry in ordered {
            let event = entry.element
            if var last = result.last, last.kind == event.kind {
                let gap = event.t - last.end
                let clicks = event.kind == .click && last.button == event.button && gap >= 0 && gap <= 650
                    && hypot((last.x - event.x) * target.frame.width, (last.y - event.y) * target.frame.height) <= 4
                let dx = (last.dx ?? 0) + (event.dx ?? 0), dy = (last.dy ?? 0) + (event.dy ?? 0)
                let scrolls = event.kind == .scroll && gap >= 0 && gap <= 1500 && dx.isFinite && dy.isFinite
                if clicks || scrolls {
                    last.t1 = max(last.end, event.end)
                    if scrolls { last.dx = dx; last.dy = dy }
                    result[result.count - 1] = last; continue
                }
            }
            result.append(event)
        }
        return result
    }
    public static func replay(_ data: Data, target: FeedbackCaptureTarget) -> (events: [FeedbackCaptureEvent], failures: [FeedbackCaptureFailure]) {
        var events: [FeedbackCaptureEvent] = [], failures: [FeedbackCaptureFailure] = []
        let records = data.split(separator: 10, omittingEmptySubsequences: false)
        for (index, record) in records.enumerated() where !record.isEmpty {
            guard index < records.count - 1 else {
                failures.append(.init(stage: "events", message: "Truncated event log tail retained.")); break
            }
            do { events.append(try JSONDecoder().decode(FeedbackCaptureEvent.self, from: Data(record))) }
            catch { failures.append(.init(stage: "events", message: "Invalid event record \(index + 1) retained.")) }
        }
        return (merge(events, target: target), failures)
    }
}
