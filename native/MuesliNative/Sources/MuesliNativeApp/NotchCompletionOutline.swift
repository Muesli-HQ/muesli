import SwiftUI
import AppKit

/// Animate progress itself, not the two clamped trim endpoints. Interpolating
/// endpoints from (0, 0) to (1, 1) otherwise produces an empty path every frame.
struct NotchCompletionOutline: Shape {
    var progress: CGFloat
    var reduceMotion = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let outline = UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
            .inset(by: 1.5)
            .path(in: rect)
        if reduceMotion { return outline }
        return outline.trimmedPath(from: max(0, progress - 0.35), to: min(1, progress))
    }
}

enum NotchCompletionTiming {
    static let duration: TimeInterval = 0.8
    static func sweep(keyPath: String) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        // Offset the endpoints in time so the moving segment never collapses
        // into the old (0,0) -> (1,1) invisible animation.
        if keyPath == "strokeStart" {
            animation.values = [0, 0, 1]
            animation.keyTimes = [0, NSNumber(value: 0.35 / 1.35), 1]
        } else {
            animation.values = [0, 1, 1]
            animation.keyTimes = [0, NSNumber(value: 1 / 1.35), 1]
        }
        animation.duration = 0.65
        animation.calculationMode = .linear
        animation.fillMode = .forwards
        return animation
    }
}

struct NotchCompletionAnimation: NSViewRepresentable {
    let completionID: Int
    let reduceMotion: Bool

    func makeNSView(context: Context) -> NotchCompletionAnimationView { NotchCompletionAnimationView() }
    func updateNSView(_ view: NotchCompletionAnimationView, context: Context) {
        view.update(completionID: completionID, reduceMotion: reduceMotion)
    }
    static func dismantleNSView(_ view: NotchCompletionAnimationView, coordinator: ()) { view.stop() }
}

@MainActor
final class NotchCompletionAnimationView: NSView {
    override var isFlipped: Bool { true }
    private let sweep = CAShapeLayer()
    private let outline = CAShapeLayer()
    private var lastCompletionID = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        for shape in [outline, sweep] {
            shape.fillColor = nil
            shape.strokeColor = NSColor.systemOrange.cgColor
            shape.lineWidth = 2
            shape.lineCap = .round
            shape.opacity = 0
            layer?.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = NotchCompletionOutline(progress: 0, reduceMotion: true).path(in: bounds).cgPath
        for shape in [outline, sweep] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    func stop() {
        sweep.removeAllAnimations()
        outline.removeAllAnimations()
    }

    func update(completionID: Int, reduceMotion: Bool) {
        guard completionID != lastCompletionID else { return }
        lastCompletionID = completionID
        stop()
        guard completionID > 0 else { return }
        let maximumFPS = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        let rate = CAFrameRateRange(minimum: min(60, maximumFPS), maximum: maximumFPS, preferred: maximumFPS)
        for (shape, opacity) in [(outline, Float(0.3)), (sweep, Float(1))] {
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [opacity, opacity, 0]
            fade.keyTimes = [0, 0.8125, 1]
            fade.duration = NotchCompletionTiming.duration
            fade.calculationMode = reduceMotion ? .discrete : .linear
            let group = CAAnimationGroup()
            group.animations = [fade]
            if shape === sweep && !reduceMotion {
                group.animations?.append(contentsOf: [NotchCompletionTiming.sweep(keyPath: "strokeStart"),
                                                     NotchCompletionTiming.sweep(keyPath: "strokeEnd")])
            }
            group.duration = NotchCompletionTiming.duration
            group.preferredFrameRateRange = rate
            shape.add(group, forKey: "completion")
        }
    }
}
