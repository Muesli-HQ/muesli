import AppKit
import Foundation
// Run from the repository root on macOS to populate locally ignored icon previews.
let names = ["clock", "waveform", "person.wave.2", "person.2", "bubble.left.and.bubble.right", "character.book.closed", "cpu", "command", "gearshape", "info.circle"]
for name in names {
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { fatalError("Missing symbol: \(name)") }
    let config = NSImage.SymbolConfiguration(pointSize: 32, weight: .medium)
    guard let configured = symbol.withSymbolConfiguration(config) else { fatalError(name) }
    let size = NSSize(width: 48, height: 48)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor.black.set()
    let rect = NSRect(x: 0, y: 0, width: 48, height: 48)
    configured.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let data = bitmap.representation(using: .png, properties: [:]) else { fatalError(name) }
    try data.write(to: URL(fileURLWithPath: "design-system/assets/icons/\(name).png"))
}
