import Foundation

/// Shared by the floating pill and notch. Rendering remains owned by each surface.
enum IndicatorWaveformDynamics {
    /// Classic capsule dimensions, also used by the notch's standing waveform.
    static func standingBarFrame(index: Int, count: Int = 5, amplitude: CGFloat, bounds: CGRect) -> CGRect {
        guard count > 0, index >= 0, index < count else { return .zero }
        let naturalWidth = CGFloat(count * 6 - 3)
        let scale = min(1, max(0, bounds.width) / naturalWidth)
        let width: CGFloat = 3 * scale
        let spacing: CGFloat = 3 * scale
        let total = CGFloat(count) * width + CGFloat(max(0, count - 1)) * spacing
        let height = min(bounds.height, 3 + 11 * max(0, min(1, amplitude)))
        return CGRect(x: bounds.midX - total / 2 + CGFloat(index) * (width + spacing),
                      y: bounds.midY - height / 2, width: width, height: height)
    }

    static func amplitude(decibels: Float) -> CGFloat {
        guard decibels.isFinite else { return 0 }
        return max(0, min(1, CGFloat(decibels + 68) / 38))
    }

    static func smooth(_ amplitude: CGFloat, previous: CGFloat) -> CGFloat {
        0.48 * amplitude + 0.52 * previous
    }

    static func standingWeight(index: Int, count: Int) -> CGFloat {
        let profile: [CGFloat] = [0.6, 0.85, 1, 0.85, 0.6]
        guard count > 1 else { return 1 }
        let position = CGFloat(index) / CGFloat(count - 1) * 4
        let lower = min(3, max(0, Int(position)))
        let fraction = position - CGFloat(lower)
        return profile[lower] + (profile[lower + 1] - profile[lower]) * fraction
    }
}
