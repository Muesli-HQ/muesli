import AppKit
import SwiftUI
import Testing
@testable import MuesliNativeApp

@Suite("Scrawl pill", .serialized)
@MainActor
struct FeedbackCapturePillTests {
    /// A private fixture: construct/layout real controller content without showing a window.
    final class HiddenPanel: InteractiveFloatingPanel {
        private(set) var presented = false
        override func orderFrontRegardless() { presented = true }
        override func orderOut(_ sender: Any?) { presented = false }
    }

    private func withIndicators(config: AppConfig = AppConfig(), _ body: @MainActor (FloatingIndicatorController, NotchIndicatorController, () -> [HiddenPanel]) throws -> Void) rethrows {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        var created: [HiddenPanel] = []
        let makePanel: () -> NSPanel = {
            let panel = HiddenPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            created.append(panel); return panel
        }
        let notch = NotchIndicatorController(resolveGeometry: { screen in
            .init(cutout: CGRect(x: screen.frame.midX - 90, y: screen.frame.maxY - 32, width: 180, height: 32), wingWidth: 110)
        }, makeFeedbackCapturePanel: makePanel)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ConfigStore(supportDirectory: root); store.save(config)
        let indicator = FloatingIndicatorController(configStore: store, notchIndicator: notch,
            makePanel: { frame in let panel = makePanel() as! HiddenPanel; panel.setFrame(frame, display: false); return panel },
            makeFeedbackCapturePanel: makePanel)
        defer { indicator.close(); created.forEach { $0.close() } }
        try body(indicator, notch, { created })
    }

    @Test("Ready Copy is wired through both indicator styles", arguments: [IndicatorAnchor.bottomCenter, .notch])
    func readyCopyCallback(anchor: IndicatorAnchor) throws {
        var config = AppConfig(); config.indicatorAnchor = anchor
        try withIndicators(config: config) { indicator, _, created in
            var copies = 0
            indicator.showFeedbackCapture(.readyToCopy(partial: "frames failed"), config: config,
                power: { -160 }, finish: {}, discard: {}, open: {}, repairPermission: {}, copy: { copies += 1 })
            let hosting = try #require(created().first?.contentView as? NSHostingView<FeedbackCapturePillView>)
            hosting.layoutSubtreeIfNeeded()
            let button = try #require(accessibilityElements(hosting).first { $0.accessibilityRole() == .button && $0.accessibilityLabel() == "Copy" })
            #expect(button.isAccessibilityEnabled())
            #expect(button.accessibilityPerformPress())
            #expect(copies == 1)
        }
    }

    @Test func styleTransitionRetiresOnlyPreviousFeedbackSurface() throws {
        try withIndicators { indicator, notch, created in
            let screen = try #require(NSScreen.main)
            var config = AppConfig(); config.showFloatingIndicator = true; config.indicatorAnchor = .notch
            @MainActor func update() {
                indicator.showFeedbackCapture(.recording(seconds: 1, deadMicrophone: false), config: config,
                    power: { -30 }, finish: {}, discard: {}, open: {}, repairPermission: {})
            }
            update()
            let previous = try #require(created().first)
            let notchHost = try #require(previous.contentView)
            config.indicatorAnchor = .bottomCenter; update()
            let floating = try #require(created().last)
            let floatingHost = try #require(floating.contentView)
            #expect(created().count == 2 && floating.presented)
            #expect(!previous.presented, "Classic must retire the previous notch feedback pill")
            config.indicatorAnchor = .notch; update()
            #expect(previous.presented && !floating.presented)
            #expect(previous.contentView === notchHost)
            config.indicatorAnchor = .bottomCenter; update()
            #expect(created().count == 2 && floating.contentView === floatingHost)
            #expect(!previous.presented)
            #expect(notch.showStatus(on: screen, kind: .loading, message: "Other activity", duration: nil))
            update()
            #expect(previous.presented && notch.status == .loading, "A floating feedback update must preserve another notch activity")
        }
    }

    @Test("floating Scrawl pill stays within the visible frame at a trailing-edge anchor")
    func floatingPillStaysWithinVisibleFrameAtTrailingEdge() throws {
        var config = AppConfig(); config.indicatorAnchor = .midTrailing
        try withIndicators(config: config) { indicator, _, created in
            let visibleFrame = try #require(NSScreen.main?.visibleFrame)
            indicator.setState(.idle, config: config)
            let idlePanel = try #require(created().first)
            #expect(idlePanel.frame.maxX == visibleFrame.maxX - 8, "The fixture places the idle indicator at the right edge")

            indicator.showFeedbackCapture(.recording(seconds: 1, deadMicrophone: false), config: config,
                power: { -30 }, finish: {}, discard: {}, open: {}, repairPermission: {})
            let feedbackPanel = try #require(created().last)
            #expect(feedbackPanel.frame.minX >= visibleFrame.minX)
            #expect(feedbackPanel.frame.maxX <= visibleFrame.maxX, "The Finish and Open controls must remain on-screen")
        }
    }

    @Test("Both indicator owners retain panels and hosted controls across recording updates", arguments: [IndicatorAnchor.bottomCenter, .notch])
    func stablePresentations(anchor: IndicatorAnchor) throws {
        var config = AppConfig(); config.indicatorAnchor = anchor
        try withIndicators(config: config) { indicator, notch, created in
            var finishes = 0, discards = 0, opens = 0
            @MainActor func update(_ state: FeedbackCapturePillState?) {
                indicator.showFeedbackCapture(state, config: config, power: { -30 }, finish: { finishes += 1 },
                    discard: { discards += 1 }, open: { opens += 1 }, repairPermission: {})
            }
            update(.recording(seconds: 0, deadMicrophone: false))
            let first = try #require(created().first)
            let hosting = try #require(first.contentView as? NSHostingView<FeedbackCapturePillView>)
            for state in [FeedbackCapturePillState.recording(seconds: 0, deadMicrophone: false),
                          .recording(seconds: 1, deadMicrophone: true), .discardConfirmation(seconds: 1, deadMicrophone: true),
                          .processing, .ready] {
                for busy in state == .processing ? [false, true] : [false] {
                    update(state)
                    #expect(hosting.rootView.state == state)
                    if busy { update(.busy(activity: "Wait for feedback processing")) }
                    let surfaces = try created().filter { $0.presented }.map { panel in
                        let host = try #require(panel.contentView as? NSHostingView<FeedbackCapturePillView>)
                        return (panel: panel, host: host, state: host.rootView.state)
                    }
                    for notice in [0, 1, 2] {
                        if notice == 0 { indicator.showLoading("Background model progress") }
                        else if notice == 1 { indicator.showWarning("Background model warning") }
                        else { indicator.showSuccess("Background model ready") }
                        #expect(first.contentView === hosting && first.presented)
                        #expect(created().filter { $0.presented }.count == surfaces.count, "Background work cannot cover feedback, including after Busy")
                        #expect(!indicator.isShowingLoading)
                        for surface in surfaces {
                            #expect(surface.panel.contentView === surface.host && surface.panel.presented)
                            #expect(surface.host.rootView.state == surface.state)
                            #expect(accessibilityElements(surface.host).contains { ($0.accessibilityValue() as? String) == surface.state.title })
                        }
                        indicator.hideLoading()
                        #expect(first.contentView === hosting && first.presented, "Late loading cleanup preserves feedback")
                    }
                    hosting.layoutSubtreeIfNeeded()
                    let buttons = accessibilityElements(hosting).filter { $0.accessibilityRole() == .button }
                    #expect(Set(buttons.compactMap { $0.accessibilityLabel() }) == (state.isRecording ? ["Discard capture", "Finish"] : state == .ready ? ["Open"] : []))
                    for button in buttons { #expect(button.accessibilityPerformPress()) }
                }
            }
            #expect(finishes == 3 && discards == 3 && opens == 1)
            update(.busy(activity: "Finish dictation"))
            #expect(first.contentView === hosting, "Busy must preserve the existing surface")
            update(.recording(seconds: 2, deadMicrophone: false))
            indicator.setState(.recording, config: config)
            #expect(!first.presented || !(first.contentView is NSHostingView<FeedbackCapturePillView>), "Foreground activity takes ownership")
            let foreground = created().filter { $0.presented }.map { (panel: $0, content: $0.contentView) }
            update(.busy(activity: "Finish dictation"))
            #expect(!foreground.isEmpty)
            #expect(foreground.allSatisfy { $0.panel.presented && $0.panel.contentView === $0.content }, "Busy cannot replace unrelated foreground activity")
            indicator.hideLoading()
            indicator.setState(.idle, config: config)
            update(.ready); update(nil)
            indicator.showSuccess("After capture")
            if anchor == .notch { #expect(notch.status == .success && notch.statusMessage == "After capture") }
            else {
                let text = created().filter { $0.presented }.compactMap(\.contentView).flatMap { accessibilityElements($0) }
                #expect(text.contains { ($0.accessibilityValue() as? String) == "After capture" })
            }
        }
    }

    // SwiftUI's AccessibilityNode implements these public selectors without
    // declaring NSAccessibilityProtocol conformance. Keep the actual nodes.
    struct PillAccessibility {
        let node: NSObject
        func object(_ name: String) -> Any? {
            let selector = NSSelectorFromString(name)
            return node.responds(to: selector) ? node.perform(selector)?.takeUnretainedValue() : nil
        }
        func boolean(_ name: String) -> Bool {
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return false }
            let method = unsafeBitCast(node.method(for: selector), to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            return method(node, selector)
        }
        func accessibilityRole() -> NSAccessibility.Role? { (object("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:)) }
        func accessibilityLabel() -> String? { object("accessibilityLabel") as? String }
        func accessibilityValue() -> Any? { object("accessibilityValue") }
        func isAccessibilityEnabled() -> Bool { boolean("isAccessibilityEnabled") }
        func accessibilityPerformPress() -> Bool { boolean("accessibilityPerformPress") }
    }
    func accessibilityElements(_ node: Any) -> [PillAccessibility] {
        guard let node = node as? NSObject else { return [] }
        if let view = node as? NSView { view.layoutSubtreeIfNeeded() }
        let element = PillAccessibility(node: node)
        return [element] + (element.object("accessibilityChildren") as? [Any] ?? []).flatMap { accessibilityElements($0) }
    }

    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    @Test("Shared states lay out in both appearances with Reduce Motion")
    func allStates() throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: attribute) }
        let states: [FeedbackCapturePillState] = [.preparing, .recording(seconds: 33, deadMicrophone: false),
            .recording(seconds: 600, deadMicrophone: true), .discardConfirmation(seconds: 33, deadMicrophone: false),
            .processing, .ready, .recovered, .copied(partial: nil), .copied(partial: "no transcript"),
            .copied(partial: "frames failed"), .readyToCopy(partial: nil), .readyToCopy(partial: "no transcript"),
            .blocked(permission: "Screen Recording"), .blocked(permission: "Microphone"),
            .blocked(permission: "Accessibility"), .blocked(permission: "Input Monitoring"),
            .busy(activity: "Finish dictation"), .busy(activity: "Stop the meeting"),
            .failed(stage: "Video", message: "The encoder stopped. Narration is retained for playback.", retainedMedia: true),
            .failed(stage: "Preparation", message: "Display unavailable", retainedMedia: false)]
        for state in states {
            for scheme in [ColorScheme.light, .dark] {
                for reduced in [false, true] {
                    var actions: [String] = []
                    let view = FeedbackCapturePillView(state: state, finish: { actions.append("Finish") },
                        discard: { actions.append("Discard capture") }, open: { actions.append("Open") },
                        repairPermission: { actions.append("Open Settings") }, reduceMotionOverride: reduced)
                        .environment(\.colorScheme, scheme)
                    let hosting = NSHostingView(rootView: view)
                    let size = hosting.fittingSize
                    #expect(size.width > 60 && size.width < 1000)
                    #expect(size.height >= 28)
                    let panel = HiddenPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    panel.contentView = hosting
                    hosting.frame = NSRect(origin: .zero, size: size); hosting.layoutSubtreeIfNeeded()
                    let elements = accessibilityElements(hosting)
                    #expect(elements.contains { ($0.accessibilityValue() as? String) == state.title || $0.accessibilityLabel() == state.title })
                    let expected: Set<String>
                    switch state {
                    case .recording, .discardConfirmation: expected = ["Discard capture", "Finish"]
                    case .blocked: expected = ["Open Settings"]
                    case .readyToCopy: expected = ["Copy", "Open"]
                    case .ready, .recovered, .copied, .failed(_, _, true): expected = ["Open"]
                    default: expected = []
                    }
                    let buttons = elements.filter { $0.accessibilityRole() == .button }
                    #expect(Set(buttons.compactMap { $0.accessibilityLabel() }) == expected)
                    for button in buttons {
                        if button.accessibilityLabel() == "Copy" { #expect(!button.isAccessibilityEnabled()) }
                        else { #expect(button.isAccessibilityEnabled()); #expect(button.accessibilityPerformPress()) }
                    }
                    #expect(Set(actions) == expected.subtracting(["Copy"]))
                    if case .recording(_, let dead) = state {
                        if dead { #expect(elements.contains { $0.accessibilityLabel() == "No microphone samples" }) }
                        else { #expect(views(hosting).contains { $0 is NotchWaveformView && $0.bounds.width == 36 && $0.bounds.height == 18 && $0.layer?.sublayers?.isEmpty == false }) }
                    }
                    if case .discardConfirmation(_, let dead) = state {
                        if dead { #expect(elements.contains { $0.accessibilityLabel() == "No microphone samples" }) }
                        else { #expect(views(hosting).contains { $0 is NotchWaveformView && $0.bounds.width == 36 && $0.bounds.height == 18 && $0.layer?.sublayers?.isEmpty == false }) }
                    }
                    #expect(elements.contains { $0.accessibilityRole() == .progressIndicator || $0.accessibilityRole() == .busyIndicator } == (state == .preparing || state == .processing))
                    panel.close()
                }
            }
        }
    }
}
