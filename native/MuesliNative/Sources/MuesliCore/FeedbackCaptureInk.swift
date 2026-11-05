import Foundation

public enum FeedbackCaptureDrawModifier: String, Codable, CaseIterable, Sendable {
    case shift, option, control, fn
    public var label: String { rawValue == "fn" ? "Fn" : rawValue.capitalized }
}

public struct FeedbackCaptureStroke: Codable, Equatable, Sendable {
    public var t0: Int64, t1: Int64
    public let fw: Double, fh: Double
    public var pin: Int?
    /// Integer normalized x, y, milliseconds since t0, repeated for each sample.
    public var pts: [Int]
    public init(t0: Int64, t1: Int64, fw: Double, fh: Double, pin: Int? = nil, pts: [Int]) {
        self.t0 = t0; self.t1 = t1; self.fw = fw; self.fh = fh; self.pin = pin; self.pts = pts
    }
    public var boxNorm: [Double] {
        let xs = stride(from: 0, to: pts.count, by: 3).map { Double(pts[$0]) / 10000 }
        let ys = stride(from: 1, to: pts.count, by: 3).map { Double(pts[$0]) / 10000 }
        return [xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0]
    }
    private enum CodingKeys: String, CodingKey { case t0, t1, fw, fh, pin, pts }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t0 = try c.decode(Int64.self, forKey: .t0); t1 = try c.decode(Int64.self, forKey: .t1)
        fw = try c.decode(Double.self, forKey: .fw); fh = try c.decode(Double.self, forKey: .fh)
        pin = try c.decodeIfPresent(Int.self, forKey: .pin); pts = try c.decode([Int].self, forKey: .pts)
        guard t0 >= 0, t1 >= t0, fw.isFinite, fh.isFinite, fw > 0, fh > 0,
              !pts.isEmpty, pts.count.isMultiple(of: 3), pts.count <= 7200, pin == nil || pin! > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .pts, in: c, debugDescription: "Invalid ink stroke")
        }
        var prior = 0
        for i in stride(from: 0, to: pts.count, by: 3) {
            guard (0...10000).contains(pts[i]), (0...10000).contains(pts[i + 1]),
                  pts[i + 2] >= prior, Int64(pts[i + 2]) <= t1 - t0 else {
                throw DecodingError.dataCorruptedError(forKey: .pts, in: c, debugDescription: "Invalid ink sample")
            }
            prior = pts[i + 2]
        }
    }
}

public struct FeedbackCaptureMark: Codable, Equatable, Sendable {
    public var id: String
    public var strokes: [Int]
    public var t0: Int64, t1: Int64
    public var boxNorm: [Double]
    public var pin: Int?
    public var description: String
    public var frame: String?
}

/// Pure input reducer. All distances are in display points, independent of backing scale.
public struct FeedbackCaptureInk: Sendable {
    public enum Modifier: String, Sendable { case shift, option, control, fn, command }
    private let target: FeedbackCaptureTarget
    private let modifier: Modifier
    private var armed = false
    private var usedHold = false
    private var lastPoint: (x: Double, y: Double)?
    private var bounds: (x0: Double, y0: Double, x1: Double, y1: Double)?
    private struct Press: Sendable { let t: Int64; let x: Double, y: Double; var travel: Double; let pinEligible: Bool }
    private var presses: [Int: Press] = [:]
    private var nextPin = 1
    public private(set) var liveStroke: FeedbackCaptureStroke?
    public private(set) var strokes: [FeedbackCaptureStroke] = []
    public init(target: FeedbackCaptureTarget, modifier: FeedbackCaptureDrawModifier = .shift) {
        self.target = target; self.modifier = Modifier(rawValue: modifier.rawValue)!
    }
    private func inside(_ x: Double, _ y: Double) -> Bool {
        let f = target.frame
        return x.isFinite && y.isFinite && x >= f.x && x < f.x + f.width && y >= f.y && y < f.y + f.height
    }
    private var eligible: Bool {
        guard let bounds else { return false }
        return max(bounds.x1 - bounds.x0, bounds.y1 - bounds.y0) >= 6
    }
    public var visibleLiveStroke: FeedbackCaptureStroke? { eligible ? liveStroke : nil }
    @discardableResult public mutating func sample(t: Int64, x: Double, y: Double, modifiers: Set<Modifier>, excluded: Bool = false) -> FeedbackCaptureStroke? {
        guard t >= 0 else { return nil }
        // Global pointer callbacks can arrive after polling has recorded a newer sample.
        if let liveStroke, t < liveStroke.t1 { return nil }
        if !modifiers.contains(modifier) { armed = true }
        let active = armed && modifiers == [modifier]
        if !active {
            let result = finish(t: t)
            if !modifiers.contains(modifier) { usedHold = false }
            return result
        }
        guard inside(x, y), !excluded, target.frame.width > 0, target.frame.height > 0 else { return finish(t: t) }
        if liveStroke == nil {
            liveStroke = .init(t0: t, t1: t, fw: target.frame.width, fh: target.frame.height, pts: [])
            lastPoint = nil; bounds = nil
        }
        for button in presses.keys {
            if var press = presses[button] { press.travel = max(press.travel, hypot(x - press.x, y - press.y)); presses[button] = press }
        }
        guard let live = liveStroke, t >= live.t0 else { return nil }
        if let lastPoint, hypot(x - lastPoint.x, y - lastPoint.y) < 1.5 { return nil }
        guard live.pts.count < 7200 else { return nil }
        let f = target.frame
        liveStroke?.pts += [Int(((x - f.x) / f.width * 10000).rounded()),
                            Int(((y - f.y) / f.height * 10000).rounded()), Int(t - live.t0)]
        liveStroke?.t1 = t
        lastPoint = (x, y)
        if let b = bounds { bounds = (min(b.x0, x), min(b.y0, y), max(b.x1, x), max(b.y1, y)) }
        else { bounds = (x, y, x, y) }
        if eligible { usedHold = true }
        return nil
    }
    public mutating func pointer(_ phase: FeedbackCaptureEvents.Phase, t: Int64, x: Double, y: Double,
                                 modifiers: Set<Modifier>, button: Int = 0, excluded: Bool = false) -> (owned: Bool, stroke: FeedbackCaptureStroke?) {
        if phase == .down {
            guard armed, modifiers == [modifier], inside(x, y), !excluded else { return (false, nil) }
            presses[button] = Press(t: t, x: x, y: y, travel: 0, pinEligible: !usedHold)
            _ = sample(t: t, x: x, y: y, modifiers: modifiers)
            return (true, nil)
        }
        guard var press = presses[button] else { return (false, nil) }
        press.travel = max(press.travel, hypot(x - press.x, y - press.y))
        presses[button] = press
        if phase == .up {
            presses.removeValue(forKey: button)
            if press.pinEligible, press.travel < 12, t >= press.t, t - press.t <= 1000,
               modifiers == [modifier], inside(x, y), !excluded {
                let f = target.frame
                let pin = FeedbackCaptureStroke(t0: press.t, t1: t, fw: f.width, fh: f.height, pin: nextPin,
                    pts: [Int(((press.x - f.x) / f.width * 10000).rounded()), Int(((press.y - f.y) / f.height * 10000).rounded()), 0])
                nextPin += 1; liveStroke = nil; lastPoint = nil; bounds = nil; usedHold = false
                strokes.append(pin)
                return (true, pin)
            }
        }
        return (true, nil)
    }
    @discardableResult public mutating func finish(t: Int64) -> FeedbackCaptureStroke? {
        defer { liveStroke = nil; lastPoint = nil; bounds = nil }
        guard var stroke = liveStroke, eligible, t >= stroke.t0 else { return nil }
        stroke.t1 = t; strokes.append(stroke)
        return stroke
    }
    public mutating func undo() {
        if !strokes.isEmpty { strokes.removeLast() }
    }
    public static func marks(_ strokes: [FeedbackCaptureStroke], splitBeforeStrokeIndices: Set<Int> = []) -> [FeedbackCaptureMark] {
        var result: [FeedbackCaptureMark] = []
        for (index, stroke) in strokes.enumerated() {
            let box = stroke.boxNorm
            if var last = result.last, !splitBeforeStrokeIndices.contains(index), last.pin == nil, stroke.pin == nil, last.strokes.count < 6,
               stroke.t0 >= last.t1, stroke.t0 - last.t1 < 1200 {
                last.strokes.append(index); last.t1 = stroke.t1
                last.boxNorm = [min(last.boxNorm[0], box[0]), min(last.boxNorm[1], box[1]), max(last.boxNorm[2], box[2]), max(last.boxNorm[3], box[3])]
                last.description = describe(last.boxNorm); result[result.count - 1] = last
            } else {
                result.append(.init(id: "m\(result.count + 1)", strokes: [index], t0: stroke.t0, t1: stroke.t1, boxNorm: box,
                    pin: stroke.pin, description: stroke.pin.map { "pin \($0)" } ?? describe(box), frame: nil))
            }
        }
        return result
    }
    private static func describe(_ b: [Double]) -> String {
        String(format: "marked region x %.2f–%.2f, y %.2f–%.2f", b[0], b[2], b[1], b[3])
    }
}
