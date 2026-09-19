import Foundation

/// Shared by the floating pill and notch. Rendering remains owned by each surface.
enum IndicatorWaveformDynamics {
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
