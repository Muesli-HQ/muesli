import AppKit
import QuartzCore
import Foundation
import MuesliCore
import os

@MainActor
final class MeetingNotificationController {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingNotification")

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var progressLayer: CALayer?
    private var dismissDeadline: Date?
    private var remainingDismissDuration: TimeInterval = 0
    private var isDismissPaused = false
    private var onStartRecording: (() -> Void)?
    private var onJoinAndRecord: (() -> Void)?
    private var onJoinOnly: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private var onAutoDismiss: (() -> Void)?
    private(set) var isVisible = false
    private(set) var currentPromptID: String?
    private(set) var shownAt: Date?

    private static let dismissDuration: TimeInterval = 15

    @discardableResult
    func show(
        promptID: String? = nil,
        title: String,
        subtitle: String,
        actionLabel: String = "Start Recording",
        meetingURL: URL? = nil,
        preferredScreen: NSScreen? = nil,
        platform explicitPlatform: MeetingPlatform? = nil,
        dismissAfter: TimeInterval? = nil,
        onStartRecording: @escaping () -> Void,
        onJoinAndRecord: (() -> Void)? = nil,
        onJoinOnly: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onAutoDismiss: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) -> Bool {
        // Nil out onClose before close() so the old panel's teardown
        // doesn't fire its callback (e.g. resetting isShowingCalendarNotification).
        self.onClose = nil
        close()

        let duration = dismissAfter ?? Self.dismissDuration
        self.onStartRecording = onStartRecording
        self.onJoinAndRecord = onJoinAndRecord
        self.onJoinOnly = onJoinOnly
        self.onDismiss = onDismiss
        self.onAutoDismiss = onAutoDismiss

        let hasJoinButton = meetingURL != nil && onJoinAndRecord != nil
        let platform = explicitPlatform ?? meetingURL.flatMap { MeetingPlatform.detect(from: $0) }

        let cardWidth: CGFloat = 344
        let cardHeight: CGFloat = 60
        let closeButtonSize: CGFloat = 22
        let cardX = closeButtonSize / 2 + 1
        let topGutter: CGFloat = closeButtonSize / 2 + 1
        let width = cardWidth + cardX
        let height = cardHeight + topGutter
        let margin: CGFloat = 16
        guard let frame = verifiedNotificationFrame(
            preferredScreen: preferredScreen,
            width: width,
            height: height,
            margin: margin
        ) else {
            Self.logger.error("notification_frame_unavailable title=\(title, privacy: .public)")
            return false
        }
        self.onClose = onClose

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true

        let contentView = HoverAwareView(frame: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        contentView.onMouseEntered = { [weak self] in self?.pauseDismissCountdown() }
        contentView.onMouseExited = { [weak self] in self?.resumeDismissCountdown() }
        contentView.wantsLayer = true

        let cardView = NSView(frame: NSRect(x: cardX, y: 0, width: cardWidth, height: cardHeight))
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 10
        cardView.layer?.masksToBounds = true
        cardView.layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.97).cgColor
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        contentView.addSubview(cardView)

        // Countdown progress bar at bottom
        let progressBar = CALayer()
        progressBar.frame = CGRect(x: 0, y: 0, width: cardWidth, height: 3)
        progressBar.backgroundColor = NSColor(red: 0.3, green: 0.6, blue: 1.0, alpha: 0.8).cgColor
        cardView.layer?.addSublayer(progressBar)
        self.progressLayer = progressBar

        progressBar.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressBar.position = CGPoint(x: 0, y: 1.5)

        let dismissButton = NSButton(title: "×", target: self, action: #selector(handleDismiss))
        dismissButton.font = .systemFont(ofSize: 15, weight: .medium)
        dismissButton.frame = NSRect(
            x: cardX - closeButtonSize / 2,
            y: cardHeight + topGutter - closeButtonSize,
            width: closeButtonSize,
            height: closeButtonSize
        )
        dismissButton.wantsLayer = true
        dismissButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.70).cgColor
        dismissButton.layer?.borderWidth = 1
        dismissButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        dismissButton.layer?.cornerRadius = closeButtonSize / 2
        dismissButton.alignment = .center
        dismissButton.focusRingType = .none
        dismissButton.isBordered = false
        dismissButton.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        dismissButton.toolTip = "Dismiss"
        contentView.addSubview(dismissButton)
        contentView.hoverFrames = [cardView.frame, dismissButton.frame]

        // Platform icon + text layout
        let textX: CGFloat
        if let platform, let icon = platform.loadIcon() {
            let iconSize: CGFloat = 26
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.frame = NSRect(x: 14, y: (cardHeight - iconSize) / 2 + 1, width: iconSize, height: iconSize)
            cardView.addSubview(iconView)
            textX = 14 + iconSize + 9
        } else {
            textX = 14
        }

        // Title label
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: textX, y: 32, width: 144, height: 18)
        cardView.addSubview(titleLabel)

        // Subtitle label
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.frame = NSRect(x: textX, y: 14, width: 144, height: 16)
        cardView.addSubview(subtitleLabel)

        if hasJoinButton {
            // Split button: "Join & Record" (main) + chevron dropdown with "Join Only"
            let buttonWidth: CGFloat = 98
            let chevronWidth: CGFloat = 24
            let totalWidth = buttonWidth + chevronWidth
            let buttonX = cardWidth - totalWidth - 12
            let textMaxX = buttonX - 8
            let greenColor = NSColor(red: 0.20, green: 0.72, blue: 0.53, alpha: 1.0)
            let greenDarker = NSColor(red: 0.15, green: 0.58, blue: 0.42, alpha: 1.0)

            // Clamp text labels so they don't overlap the button
            titleLabel.frame.size.width = textMaxX - textX
            subtitleLabel.frame.size.width = textMaxX - textX

            // Main "Join & Record" button
            let joinButton = NSButton(title: "Join & Record", target: self, action: #selector(handleJoinAndRecord))
            joinButton.font = .systemFont(ofSize: 11, weight: .medium)
            joinButton.frame = NSRect(x: buttonX, y: 15, width: buttonWidth, height: 30)
            joinButton.wantsLayer = true
            joinButton.layer?.backgroundColor = greenColor.cgColor
            joinButton.layer?.cornerRadius = 6
            joinButton.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            joinButton.isBordered = false
            joinButton.contentTintColor = .white
            cardView.addSubview(joinButton)

            // Chevron dropdown button
            let chevronButton = NSButton(title: "▾", target: self, action: #selector(handleChevronClick(_:)))
            chevronButton.font = .systemFont(ofSize: 9, weight: .medium)
            chevronButton.frame = NSRect(x: buttonX + buttonWidth, y: 15, width: chevronWidth, height: 30)
            chevronButton.wantsLayer = true
            chevronButton.layer?.backgroundColor = greenDarker.cgColor
            chevronButton.layer?.cornerRadius = 6
            chevronButton.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            chevronButton.isBordered = false
            chevronButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
            cardView.addSubview(chevronButton)
        } else {
            // Single "Start Recording" button
            let startButton = NSButton(title: actionLabel, target: self, action: #selector(handleStartRecording))
            startButton.font = .systemFont(ofSize: 12, weight: .medium)
            startButton.frame = NSRect(x: cardWidth - 122, y: 15, width: 110, height: 30)
            startButton.wantsLayer = true
            startButton.layer?.backgroundColor = NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0).cgColor
            startButton.layer?.cornerRadius = 6
            startButton.isBordered = false
            startButton.contentTintColor = .white
            cardView.addSubview(startButton)
        }

        panel.contentView = contentView
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        self.panel = panel
        isVisible = true
        currentPromptID = promptID
        shownAt = Date()
        Self.logger.notice(
            "notification_panel_shown promptID=\(promptID ?? "nil", privacy: .public) level=\(panel.level.rawValue) frame=\(NSStringFromRect(frame), privacy: .public)"
        )

        startDismissCountdown(duration: duration)
        return true
    }

    var onClose: (() -> Void)?

    static func suppressesCloseCallbackDuringAutoDismiss(hasAutoDismissHandler: Bool) -> Bool {
        hasAutoDismissHandler
    }

    static func firesAutoDismissCallbackAfterFade(wasDismissPaused: Bool) -> Bool {
        !wasDismissPaused
    }

    func close() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissDeadline = nil
        remainingDismissDuration = 0
        isDismissPaused = false
        progressLayer?.removeAllAnimations()
        progressLayer?.speed = 1
        progressLayer?.timeOffset = 0
        progressLayer?.beginTime = 0
        progressLayer = nil
        panel?.close()
        panel = nil
        onStartRecording = nil
        onJoinAndRecord = nil
        onJoinOnly = nil
        onDismiss = nil
        onAutoDismiss = nil
        isVisible = false
        currentPromptID = nil
        shownAt = nil
        onClose?()
        onClose = nil
    }

    private func startDismissCountdown(duration: TimeInterval) {
        remainingDismissDuration = duration
        isDismissPaused = false
        startProgressAnimation(duration: duration)
        scheduleDismissTimer(after: duration)
    }

    private func startProgressAnimation(duration: TimeInterval) {
        guard let progressLayer else { return }
        let shrink = CABasicAnimation(keyPath: "bounds.size.width")
        shrink.fromValue = progressLayer.bounds.width
        shrink.toValue = 0
        shrink.duration = duration
        shrink.timingFunction = CAMediaTimingFunction(name: .linear)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        progressLayer.add(shrink, forKey: "countdown")
    }

    private func scheduleDismissTimer(after duration: TimeInterval) {
        dismissTimer?.invalidate()
        dismissDeadline = Date().addingTimeInterval(duration)
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.autoDismissNow()
            }
        }
    }

    private func autoDismissNow() {
        guard !isDismissPaused else { return }
        animateOut { [weak self] in
            guard let self else { return }
            let wasPaused = self.isDismissPaused
            let autoDismiss = self.onAutoDismiss
            let shouldFireAutoDismiss = Self.firesAutoDismissCallbackAfterFade(wasDismissPaused: wasPaused)
            if shouldFireAutoDismiss,
               Self.suppressesCloseCallbackDuringAutoDismiss(hasAutoDismissHandler: autoDismiss != nil) {
                self.onClose = nil
            }
            self.close()
            if shouldFireAutoDismiss {
                autoDismiss?()
            }
        }
    }

    private func pauseDismissCountdown() {
        guard isVisible, !isDismissPaused else { return }
        isDismissPaused = true
        if let dismissDeadline {
            remainingDismissDuration = max(0.1, dismissDeadline.timeIntervalSinceNow)
        }
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissDeadline = nil

        guard let progressLayer else { return }
        let pausedTime = progressLayer.convertTime(CACurrentMediaTime(), from: nil)
        progressLayer.speed = 0
        progressLayer.timeOffset = pausedTime
    }

    private func resumeDismissCountdown() {
        guard isVisible, isDismissPaused else { return }
        isDismissPaused = false
        scheduleDismissTimer(after: remainingDismissDuration)

        guard let progressLayer else { return }
        let pausedTime = progressLayer.timeOffset
        let resumeHostTime = CACurrentMediaTime()
        progressLayer.speed = 1
        progressLayer.timeOffset = 0
        progressLayer.beginTime = resumeHostTime - pausedTime
    }

    private func animateOut(completion: @escaping () -> Void) {
        guard let panel else { completion(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    @objc private func handleStartRecording() {
        let action = onStartRecording
        animateOut { [weak self] in
            self?.close()
            action?()
        }
    }

    @objc private func handleJoinAndRecord() {
        let action = onJoinAndRecord
        animateOut { [weak self] in
            self?.close()
            action?()
        }
    }

    @objc private func handleJoinOnly() {
        let action = onJoinOnly
        animateOut { [weak self] in
            self?.close()
            action?()
        }
    }

    @objc private func handleChevronClick(_ sender: NSButton) {
        let menu = NSMenu()
        let joinOnlyItem = NSMenuItem(title: "Join Only", action: #selector(handleJoinOnly), keyEquivalent: "")
        joinOnlyItem.target = self
        menu.addItem(joinOnlyItem)

        let recordOnlyItem = NSMenuItem(title: "Record Only", action: #selector(handleStartRecording), keyEquivalent: "")
        recordOnlyItem.target = self
        menu.addItem(recordOnlyItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func handleDismiss() {
        let action = onDismiss
        animateOut { [weak self] in
            self?.close()
            action?()
        }
    }

    private func verifiedNotificationFrame(
        preferredScreen: NSScreen?,
        width: CGFloat,
        height: CGFloat,
        margin: CGFloat
    ) -> NSRect? {
        let orderedScreens = uniqueScreens(
            [preferredScreen, NSScreen.main, screenForMouse()].compactMap { $0 } + NSScreen.screens
        )

        for screen in orderedScreens {
            let frame = notificationFrame(on: screen, width: width, height: height, margin: margin)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(frame) }) {
                return frame
            }
        }
        guard let fallbackScreen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return notificationFrame(on: fallbackScreen, width: width, height: height, margin: margin)
    }

    private func screenForMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
    }

    private func notificationFrame(
        on screen: NSScreen,
        width: CGFloat,
        height: CGFloat,
        margin: CGFloat
    ) -> NSRect {
        let visible = screen.visibleFrame
        let x = min(
            max(visible.maxX - width - margin, visible.minX + margin),
            visible.maxX - width
        )
        let y = min(
            max(visible.maxY - height - margin, visible.minY + margin),
            visible.maxY - height
        )
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func uniqueScreens(_ screens: [NSScreen]) -> [NSScreen] {
        var seen = Set<ObjectIdentifier>()
        return screens.filter { screen in
            seen.insert(ObjectIdentifier(screen)).inserted
        }
    }
}

private final class HoverAwareView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var hoverFrames: [NSRect] = []
    private var isHoveringActiveFrame = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for trackingArea in trackingAreas {
            removeTrackingArea(trackingArea)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoverState(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoverState(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setHoveringActiveFrame(false)
    }

    private func updateHoverState(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        setHoveringActiveFrame(hoverFrames.contains { $0.contains(point) })
    }

    private func setHoveringActiveFrame(_ isHovering: Bool) {
        guard isHovering != isHoveringActiveFrame else { return }
        isHoveringActiveFrame = isHovering
        if isHovering {
            onMouseEntered?()
        } else {
            onMouseExited?()
        }
    }
}

// MARK: - Meeting Platform Detection

enum MeetingPlatform: Equatable {
    case zoom
    case googleMeet
    case teams
    case slack
    case webex
    case facetime

    static func detect(from url: URL) -> MeetingPlatform? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("zoom.us") { return .zoom }
        if host == "meet.google.com" { return .googleMeet }
        if host.hasSuffix("teams.microsoft.com") { return .teams }
        if host.hasSuffix("webex.com") { return .webex }
        if host == "facetime.apple.com" { return .facetime }
        if host == "app.slack.com" && url.path.hasPrefix("/huddle/") { return .slack }
        return nil
    }

    init?(_ platform: MeetingCandidate.Platform) {
        switch platform {
        case .zoom:
            self = .zoom
        case .googleMeet:
            self = .googleMeet
        case .teams:
            self = .teams
        case .slack:
            self = .slack
        case .webex:
            self = .webex
        case .facetime:
            self = .facetime
        case .whatsApp, .unknown:
            return nil
        }
    }

    func loadIcon() -> NSImage? {
        switch self {
        case .zoom:
            if let url = Bundle.main.url(forResource: "zoom-app", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
            return NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Zoom")
        case .googleMeet:
            if let url = Bundle.main.url(forResource: "google-meet", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
            return NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Google Meet")
        case .teams:
            if let url = Bundle.main.url(forResource: "teams", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
            return NSImage(systemSymbolName: "person.3.fill", accessibilityDescription: "Teams")
        case .slack:
            if let url = Bundle.main.url(forResource: "slack", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
            return NSImage(systemSymbolName: "message.fill", accessibilityDescription: "Slack")
        case .webex:
            return NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Webex")
        case .facetime:
            return NSImage(systemSymbolName: "video.fill", accessibilityDescription: "FaceTime")
        }
    }
}
