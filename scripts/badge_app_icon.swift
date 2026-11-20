// Draws a build label (for example "DEV") as an orange pill across the lower
// edge of every PNG in an .iconset directory, in place.
// Usage: swift scripts/badge_app_icon.swift <dir.iconset> <label>
// Called by muesli_badge_icns in scripts/muesli_build_badge.sh.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, !arguments[2].isEmpty else {
    FileHandle.standardError.write(Data("usage: badge_app_icon.swift <dir.iconset> <label>\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: arguments[1])
let label = arguments[2]
// systemOrange (light), matching the in-app badge colour.
let orange = NSColor(srgbRed: 1, green: 0.584, blue: 0, alpha: 1)

/// Geometry is designed on a 512 px canvas and scaled to each icon size.
func drawBadge(in rect: NSRect) {
    let scale = rect.width / 512
    let maxWidth = rect.width * 0.8, padding = 64 * scale
    var font = NSFont.systemFont(ofSize: 96 * scale, weight: .heavy)
    let natural = (label as NSString).size(withAttributes: [.font: font]).width
    if natural + padding > maxWidth {
        font = NSFont.systemFont(ofSize: font.pointSize * (maxWidth - padding) / natural, weight: .heavy)
    }
    let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
    let textSize = text.size()
    let pill = NSRect(x: (rect.width - textSize.width - padding) / 2, y: rect.height * 0.08,
                      width: textSize.width + padding, height: textSize.height + 20 * scale)
    let shape = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
    orange.setFill()
    shape.fill()
    NSColor.white.withAlphaComponent(0.9).setStroke()
    shape.lineWidth = 8 * scale
    shape.stroke()
    text.draw(at: NSPoint(x: pill.midX - textSize.width / 2, y: pill.midY - textSize.height / 2))
}

do {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "png" }
    guard !files.isEmpty else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: directory.path]) }
    for file in files {
        guard let source = NSBitmapImageRep(data: try Data(contentsOf: file)),
              let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: output) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file.path])
        }
        let rect = NSRect(x: 0, y: 0, width: source.pixelsWide, height: source.pixelsHigh)
        output.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: rect)
        drawBadge(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = output.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        try png.write(to: file)
    }
} catch {
    FileHandle.standardError.write(Data("badge_app_icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
