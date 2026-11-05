import SwiftUI

/// Viewfinder corners frame a play symbol, matching the weight of nearby icons.
struct VidshotIcon: View {
    /// AppKit menus and shared settings headings use the same template glyph.
    @MainActor private static let cachedImage: NSImage = {
        let renderer = ImageRenderer(content: VidshotIcon().foregroundStyle(.black).frame(width: 18, height: 18))
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }()

    @MainActor static func image() -> NSImage { cachedImage }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let x = (geometry.size.width - side) / 2, y = (geometry.size.height - side) / 2
            Path { path in
                let inset = side * 0.11, arm = side * 0.25
                for (horizontal, vertical) in [(false, false), (true, false), (false, true), (true, true)] {
                    let cx = x + (horizontal ? side - inset : inset)
                    let cy = y + (vertical ? side - inset : inset)
                    let dx = horizontal ? -arm : arm, dy = vertical ? -arm : arm
                    path.move(to: CGPoint(x: cx + dx, y: cy))
                    path.addLine(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx, y: cy + dy))
                }
            }
            .stroke(style: StrokeStyle(lineWidth: max(1, side * 0.09), lineCap: .round, lineJoin: .round))
            Path { path in
                path.move(to: CGPoint(x: x + side * 0.42, y: y + side * 0.31))
                path.addLine(to: CGPoint(x: x + side * 0.69, y: y + side * 0.5))
                path.addLine(to: CGPoint(x: x + side * 0.42, y: y + side * 0.69))
                path.closeSubpath()
            }
            .fill()
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
