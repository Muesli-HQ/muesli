import AppKit
import Testing
@testable import MuesliNativeApp

@Suite("Recording indicator icons")
@MainActor
struct RecordingIndicatorIconTests {
    private func pixels(of image: NSImage, side: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func isRed(_ color: NSColor?) -> Bool {
        guard let color = color?.usingColorSpace(.deviceRGB) else { return false }
        return color.alphaComponent > 0.9 && color.redComponent > 0.8 && color.greenComponent < 0.4 && color.blueComponent < 0.4
    }

    private let plainMark: NSImage = {
        let image = NSImage(size: NSSize(width: 36, height: 36), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(rect: rect.insetBy(dx: 6, dy: 6)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    @Test("the menu bar mark gets a red dot in its top-right corner")
    func menuBarMarkHasADot() {
        let rep = pixels(of: MenuBarIconRenderer.withRecordingDot(plainMark), side: 36)
        // Bitmap rows run top to bottom, so the dot is in the first rows and the last columns.
        #expect(isRed(rep.colorAt(x: 32, y: 4)))
        #expect(!isRed(rep.colorAt(x: 4, y: 32)))
    }

    @Test("the dotted menu bar mark is a colored image, not a template")
    func dottedMarkIsNotATemplate() {
        #expect(!MenuBarIconRenderer.withRecordingDot(plainMark).isTemplate)
    }

    @Test("the Dock icon gets the same dot")
    func dockIconHasADot() {
        let rep = pixels(of: DockRecordingIndicator.iconWithDot(plainMark, side: 36), side: 36)
        #expect(isRed(rep.colorAt(x: 32, y: 4)))
    }
}
