import AppKit
import SwiftUI

@MainActor
struct VisualSnapshotCapture {
    struct Capture {
        let pngData: Data
        let pixelSize: VisualPixelSize
    }

    /// Hosts SwiftUI in a real NSWindow and NSHostingView so AppKit-backed
    /// controls, materials, font fallback, and layout use the macOS renderer.
    static func capture(scenario: VisualScenario) throws -> Capture {
        AppFonts.registerForRenderingIfNeeded()
        let size = NSSize(width: CGFloat(scenario.size.width), height: CGFloat(scenario.size.height))
        let appearance = NSAppearance(named: scenario.appearance == .dark ? .darkAqua : .aqua)
        let root = VisualScenarioViewFactory.view(for: scenario)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scenario.appearance == .dark ? .dark : .light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.appearance = appearance

        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hostingView
        defer { window.close() }

        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: scenario.pixelSize.width,
            pixelsHigh: scenario.pixelSize.height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw VisualSnapshotCaptureError.unavailableBitmap
        }
        // The backing bitmap has an explicit 2x (or future profile-specific)
        // pixel size while its logical size stays in the scenario's points.
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw VisualSnapshotCaptureError.unavailablePNG
        }
        return Capture(
            pngData: pngData,
            pixelSize: VisualPixelSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        )
    }
}

@MainActor
enum VisualScenarioViewFactory {
    static func view(for scenario: VisualScenario) -> AnyView {
        switch scenario.screen {
        case .notchInstructionPreview:
            #if DEBUG
            AnyView(NotchInstructionPreview(
                accent: .purple,
                mode: "Computer use",
                phase: "Needs approval"
            ))
            #else
            // Fixture mode is Debug-only. Keep the app module buildable in
            // Release even though this preview source is Debug-only.
            AnyView(EmptyView())
            #endif
        case .liveInstruction:
            AnyView(NotchLiveInstructionView(
                instruction: "Turn these notes into a concise project update.",
                status: "Review the proposed change",
                appName: "Muesli",
                appIcon: nil,
                accent: .purple,
                requiresReview: true,
                onCollapse: {},
                onCancel: {}
            ))
        case .recordingIndicatorPicker:
            AnyView(
                RecordingIndicatorStylePicker(selection: .classic, onSelect: { _ in })
                    .padding(20)
                    .background(MuesliTheme.backgroundBase)
            )
        }
    }
}

enum VisualSnapshotCaptureError: LocalizedError {
    case unavailableBitmap
    case unavailablePNG

    var errorDescription: String? {
        switch self {
        case .unavailableBitmap: "AppKit did not provide a bitmap for the visual snapshot."
        case .unavailablePNG: "AppKit did not encode the visual snapshot as PNG."
        }
    }
}
