import AppKit
import SwiftUI

/// Non-shipping application delegate used only after the full fixture launch
/// contract has passed. It keeps visual tests out of the production delegate,
/// so no telemetry, network, permissions, audio, or user support paths start.
@MainActor
final class VisualFixtureApplicationDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: VisualFixtureApplicationDelegate?

    private let fixture: VisualTestLaunchConfiguration
    private var window: NSWindow?

    init(fixture: VisualTestLaunchConfiguration) {
        self.fixture = fixture
    }

    static func run(_ fixture: VisualTestLaunchConfiguration) -> Never {
        let application = NSApplication.shared
        let delegate = VisualFixtureApplicationDelegate(fixture: fixture)
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        fatalError("NSApplicationMain unexpectedly returned")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let scenario = fixture.scenario
        AppFonts.registerForRenderingIfNeeded()
        let size = NSSize(width: CGFloat(scenario.size.width), height: CGFloat(scenario.size.height))
        let appearance = NSAppearance(named: scenario.appearance == .dark ? .darkAqua : .aqua)
        let root = VisualScenarioViewFactory.view(for: scenario)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scenario.appearance == .dark ? .dark : .light)
        let hostingView = NSHostingView(rootView: root)
        hostingView.appearance = appearance

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("window.visual-test")
        window.title = "Muesli visual fixture: \(scenario.id)"
        window.appearance = appearance
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Publish only after the window has been ordered and laid out. UI
        // tests wait on this value instead of sleeping for an arbitrary time.
        hostingView.setAccessibilityIdentifier("visual-test.ready")
        hostingView.setAccessibilityLabel("Visual fixture ready")
        hostingView.setAccessibilityValue("scenario=\(scenario.id);generation=1")
        self.window = window
    }
}
