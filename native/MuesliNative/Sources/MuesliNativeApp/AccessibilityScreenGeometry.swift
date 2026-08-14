import AppKit

/// Converts Accessibility/Quartz global coordinates (top-left origin) into
/// AppKit screen coordinates (bottom-left origin) without assuming one display.
enum AccessibilityScreenGeometry {
    struct ConvertedPoint: Equatable {
        let point: CGPoint
        let screenIndex: Int
    }

    static func appKitPoint(
        forQuartzPoint point: CGPoint,
        screenFrames: [CGRect],
        primaryScreenMaxY: CGFloat,
        tolerance: CGFloat = 0
    ) -> ConvertedPoint? {
        guard point.x.isFinite, point.y.isFinite, primaryScreenMaxY.isFinite else { return nil }
        let converted = CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
        guard let screenIndex = screenFrames.firstIndex(where: {
            $0.insetBy(dx: -tolerance, dy: -tolerance).contains(converted)
        }) else { return nil }
        return ConvertedPoint(point: converted, screenIndex: screenIndex)
    }

    static func appKitPoint(
        forQuartzPoint point: CGPoint,
        screens: [NSScreen] = NSScreen.screens,
        tolerance: CGFloat = 0
    ) -> (point: CGPoint, screen: NSScreen)? {
        guard let converted = appKitPoint(
            forQuartzPoint: point,
            screenFrames: screens.map(\.frame),
            primaryScreenMaxY: screens.first?.frame.maxY ?? 0,
            tolerance: tolerance
        ), screens.indices.contains(converted.screenIndex) else { return nil }
        return (converted.point, screens[converted.screenIndex])
    }
}
