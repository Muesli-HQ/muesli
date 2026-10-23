import AppKit

/// Original orbital hourglass, drawn as a template for light and dark menu surfaces.
enum TimeTurnerIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 16, height: 16))
            ring.lineWidth = 1.15
            ring.stroke()
            let orbit = NSBezierPath(ovalIn: NSRect(x: 0.8, y: 6, width: 18.4, height: 8))
            let rotation = AffineTransform(translationByX: -10, byY: -10)
            orbit.transform(using: rotation)
            var tilt = AffineTransform(); tilt.rotate(byDegrees: 38)
            orbit.transform(using: tilt)
            orbit.transform(using: AffineTransform(translationByX: 10, byY: 10))
            orbit.lineWidth = 0.9; orbit.stroke()
            let glass = NSBezierPath()
            glass.move(to: NSPoint(x: 7, y: 15)); glass.line(to: NSPoint(x: 13, y: 15))
            glass.line(to: NSPoint(x: 13, y: 13)); glass.curve(to: NSPoint(x: 10, y: 10), controlPoint1: NSPoint(x: 13, y: 12), controlPoint2: NSPoint(x: 11, y: 11))
            glass.curve(to: NSPoint(x: 13, y: 7), controlPoint1: NSPoint(x: 11, y: 9), controlPoint2: NSPoint(x: 13, y: 8))
            glass.line(to: NSPoint(x: 13, y: 5)); glass.line(to: NSPoint(x: 7, y: 5)); glass.line(to: NSPoint(x: 7, y: 7))
            glass.curve(to: NSPoint(x: 10, y: 10), controlPoint1: NSPoint(x: 7, y: 8), controlPoint2: NSPoint(x: 9, y: 9))
            glass.curve(to: NSPoint(x: 7, y: 13), controlPoint1: NSPoint(x: 9, y: 11), controlPoint2: NSPoint(x: 7, y: 12))
            glass.close(); glass.lineWidth = 1.25; glass.lineJoinStyle = .round; glass.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Time Turner"
        return image
    }
}
