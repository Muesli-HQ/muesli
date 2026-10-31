import AppKit
import QuartzCore
import Foundation
import MuesliCore
import os

@MainActor
final class MeetingNotificationController {
    private static let logger = Logger(subsystem: "com.muesli.native", category: "MeetingNotification")

    private(set) var panel: NSPanel?
    private var dismissTimer: Timer?
    private var progressLayer: CALayer?
    private var dismissDeadline: Date?
    private var remainingDismissDuration: TimeInterval = 0
    private(set) var isDismissPaused = false
    enum DismissPauseReason: Hashable { case hover, picker, work }
    private var dismissPauseReasons: Set<DismissPauseReason> = []
    private var presentationID = UUID()
    private var timerID = UUID()
    private var fadeID = UUID()
    private var isAutoDismissFading = false
    private var currentDismissDuration: TimeInterval = dismissDuration
    private let contactPicker: any MeetingContactPresenting
    private var completionSession: MeetingCompletionContactSession?
    private var completionParticipantLabel: NSTextField?
    private var completionErrorLabel: NSTextField?
    private var completionButton: NSButton?
    private var completionCaret: NSButton?
    private var completionAnchor: NSView?
    private weak var previousKeyWindow: NSWindow?
    private var onStartRecording: (() -> Void)?
    private var onJoinAndRecord: (() -> Void)?
    private var onJoinOnly: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private var onAutoDismiss: (() -> Void)?
    private var splitButtonAlternatives: [MeetingJoinDefaultAction] = []
    private(set) var isVisible = false
    private(set) var currentPromptID: String?
    private(set) var shownAt: Date?

    private static let dismissDuration: TimeInterval = 15

    init(contactPicker: (any MeetingContactPresenting)? = nil) {
        self.contactPicker = contactPicker ?? MeetingContactPickerPresenter()
    }

    /// Fixed geometry for the split button, so swapping which action is armed never
    /// reflows the card. `splitButtonLabelFits` guards the assumption in tests.
    static let splitButtonWidth: CGFloat = 126
    static let splitButtonFont = AppFonts.font(size: 11, weight: .medium)

    static func splitButtonLabelFits(_ label: String, horizontalPadding: CGFloat = 12) -> Bool {
        let labelWidth = (label as NSString).size(withAttributes: [.font: splitButtonFont]).width
        return labelWidth + horizontalPadding <= splitButtonWidth
    }

    static func singleActionTextWidth(
        cardWidth: CGFloat,
        textX: CGFloat,
        buttonWidth: CGFloat = 126,
        trailingInset: CGFloat = 12,
        spacing: CGFloat = 8
    ) -> CGFloat {
        max(0, cardWidth - trailingInset - buttonWidth - spacing - textX)
    }

    static func singleActionCardWidth(
        requiredTextWidth: CGFloat,
        textX: CGFloat,
        buttonWidth: CGFloat = 126,
        trailingInset: CGFloat = 12,
        spacing: CGFloat = 8,
        minimumWidth: CGFloat = 344,
        maximumWidth: CGFloat = 420
    ) -> CGFloat {
        let requiredWidth = ceil(textX + requiredTextWidth + spacing + buttonWidth + trailingInset)
        return min(maximumWidth, max(minimumWidth, requiredWidth))
    }

    @discardableResult
    func show(
        promptID: String? = nil,
        title: String,
        subtitle: String,
        actionLabel: String = "Start Transcribing",
        meetingURL: URL? = nil,
        preferredScreen: NSScreen? = nil,
        platform explicitPlatform: MeetingPlatform? = nil,
        dismissAfter: TimeInterval? = nil,
        defaultAction: MeetingJoinDefaultAction = .fallback,
        completionSession: MeetingCompletionContactSession? = nil,
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

        let hasJoinAndRecord = meetingURL != nil && onJoinAndRecord != nil
        let hasJoinOnly = meetingURL != nil && onJoinOnly != nil
        let armedAction = defaultAction.resolved(hasJoinAndRecord: hasJoinAndRecord, hasJoinOnly: hasJoinOnly)
        splitButtonAlternatives = defaultAction.availableAlternatives(
            hasJoinAndRecord: hasJoinAndRecord,
            hasJoinOnly: hasJoinOnly
        )
        // Nothing to drop down (a prompt with no join link, or "Stop Transcribing")
        // keeps the plain single-action button.
        let hasJoinButton = completionSession != nil || !splitButtonAlternatives.isEmpty
        let platform = explicitPlatform ?? meetingURL.flatMap { MeetingPlatform.detect(from: $0) }
        let platformIcon = platform?.loadIcon()
        let iconSize: CGFloat = 26
        let textX: CGFloat = platformIcon == nil ? 14 : 14 + iconSize + 9
        let titleFont = AppFonts.font(size: 13, weight: .semibold)
        let subtitleFont = AppFonts.font(size: 11)

        let minimumCardWidth: CGFloat = 344
        let cardWidth: CGFloat
        if hasJoinButton {
            cardWidth = minimumCardWidth
        } else {
            let titleWidth = (title as NSString).size(withAttributes: [.font: titleFont]).width
            let subtitleWidth = (subtitle as NSString).size(withAttributes: [.font: subtitleFont]).width
            cardWidth = Self.singleActionCardWidth(
                requiredTextWidth: max(titleWidth, subtitleWidth),
                textX: textX,
                minimumWidth: minimumCardWidth
            )
        }
        let cardHeight: CGFloat = completionSession == nil ? 60 : 94
        let closeButtonSize = NotificationDismissButton.size
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
        self.completionSession = completionSession
        let presentationID = self.presentationID
        currentDismissDuration = duration

        let panel = MeetingNotificationPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isCompletionPanel = completionSession != nil
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true

        let contentView = HoverAwareView(frame: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
        contentView.onMouseEntered = { [weak self] in
            guard let self, self.presentationID == presentationID else { return }
            self.setDismissPause(.hover, paused: true)
        }
        contentView.onMouseExited = { [weak self] in
            guard let self, self.presentationID == presentationID else { return }
            self.setDismissPause(.hover, paused: false)
        }
        contentView.wantsLayer = true

        let cardView: NSView
        let cardFrame = NSRect(x: cardX, y: 0, width: cardWidth, height: cardHeight)
        if completionSession != nil {
            let completionCard = CompletionNotificationCardView(frame: cardFrame)
            completionCard.onOpenNotes = { [weak self] in
                guard let self, self.presentationID == presentationID else { return }
                let action = self.onStartRecording
                self.close()
                action?()
            }
            completionCard.toolTip = "Open notes"
            completionCard.setAccessibilityLabel(title)
            completionCard.setAccessibilityRole(.group)
            completionCard.setAccessibilityElement(true)
            completionCard.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Open notes") { [weak completionCard] in
                    completionCard?.accessibilityPerformPress() ?? false
                },
            ])
            cardView = completionCard
        } else {
            cardView = NSView(frame: cardFrame)
        }
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

        let dismissButton = NotificationDismissButton.make(target: self, action: #selector(handleDismiss))
        dismissButton.frame = NSRect(
            x: cardX - closeButtonSize / 2,
            y: cardHeight + topGutter - closeButtonSize,
            width: closeButtonSize,
            height: closeButtonSize
        )
        contentView.addSubview(dismissButton)
        contentView.hoverFrames = [cardView.frame, dismissButton.frame]

        // Platform icon + text layout
        if let icon = platformIcon {
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.frame = NSRect(x: 14, y: (cardHeight - iconSize) / 2 + 1, width: iconSize, height: iconSize)
            cardView.addSubview(iconView)
        }

        // Title label
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = titleFont
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: textX, y: 32, width: 144, height: 18)
        cardView.addSubview(titleLabel)

        // Subtitle label
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = subtitleFont
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitleLabel.frame = NSRect(x: textX, y: 14, width: 144, height: 16)
        cardView.addSubview(subtitleLabel)

        if hasJoinButton {
            // Split button: the armed action (main) + chevron dropdown with the others
            let buttonWidth = Self.splitButtonWidth
            let chevronWidth: CGFloat = 24
            let totalWidth = buttonWidth + chevronWidth
            let buttonX = cardWidth - totalWidth - 12
            let textMaxX = buttonX - 8
            let greenColor = NSColor(red: 0.20, green: 0.72, blue: 0.53, alpha: 1.0)
            let greenDarker = NSColor(red: 0.15, green: 0.58, blue: 0.42, alpha: 1.0)

            // Clamp text labels so they don't overlap the button
            titleLabel.frame.size.width = textMaxX - textX
            subtitleLabel.frame.size.width = textMaxX - textX

            // Main button for the user's default action
            let joinButton = NSButton(
                title: completionSession?.buttonLabel ?? armedAction.buttonLabel,
                target: self,
                action: completionSession == nil ? Self.selector(for: armedAction) : #selector(handleAddContact(_:))
            )
            joinButton.font = Self.splitButtonFont
            let buttonY: CGFloat = completionSession == nil ? 15 : 4
            joinButton.frame = NSRect(x: buttonX, y: buttonY, width: buttonWidth, height: 30)
            joinButton.wantsLayer = true
            joinButton.layer?.backgroundColor = greenColor.cgColor
            joinButton.layer?.cornerRadius = 6
            joinButton.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
            joinButton.isBordered = false
            joinButton.contentTintColor = .white
            cardView.addSubview(joinButton)

            // Chevron dropdown button
            let chevronButton = NSButton(title: "▾", target: self, action: completionSession == nil ? #selector(handleChevronClick(_:)) : #selector(handleAddContact(_:)))
            chevronButton.font = .systemFont(ofSize: 9, weight: .medium)
            chevronButton.frame = NSRect(x: buttonX + buttonWidth, y: buttonY, width: chevronWidth, height: 30)
            chevronButton.wantsLayer = true
            chevronButton.layer?.backgroundColor = greenDarker.cgColor
            chevronButton.layer?.cornerRadius = 6
            chevronButton.layer?.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
            chevronButton.isBordered = false
            chevronButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
            chevronButton.toolTip = splitButtonAlternatives.map(\.buttonLabel).joined(separator: " · ")
            cardView.addSubview(chevronButton)
            if let completionSession {
                titleLabel.frame = NSRect(x: textX, y: 70, width: cardWidth - textX - 14, height: 18)
                subtitleLabel.frame = NSRect(x: textX, y: 52, width: cardWidth - textX - 14, height: 16)
                subtitleLabel.lineBreakMode = .byTruncatingTail
                let people = NSTextField(labelWithString: "")
                people.identifier = NSUserInterfaceItemIdentifier("completionParticipants")
                people.font = subtitleFont
                people.textColor = subtitleLabel.textColor
                people.frame = NSRect(x: textX, y: 36, width: cardWidth - textX - 14, height: 16)
                people.lineBreakMode = .byTruncatingTail
                cardView.addSubview(people)
                let error = NSTextField(labelWithString: "")
                error.identifier = NSUserInterfaceItemIdentifier("completionError")
                error.font = .systemFont(ofSize: 11)
                error.textColor = .systemRed
                error.frame = NSRect(x: textX, y: 11, width: buttonX - textX - 8, height: 16)
                cardView.addSubview(error)
                completionParticipantLabel = people
                completionErrorLabel = error
                completionButton = joinButton
                completionCaret = chevronButton
                completionAnchor = cardView
                chevronButton.toolTip = "Add contact"
                chevronButton.setAccessibilityLabel("Add contact")
                completionSession.onChange = { [weak self] in
                    guard let self, self.presentationID == presentationID else { return }
                    self.updateCompletionCard()
                }
            }
        } else {
            // Single "Start Transcribing" button
            let buttonWidth: CGFloat = 126
            let buttonX = cardWidth - buttonWidth - 12
            let textWidth = Self.singleActionTextWidth(cardWidth: cardWidth, textX: textX, buttonWidth: buttonWidth)
            titleLabel.frame.size.width = textWidth
            subtitleLabel.frame.size.width = textWidth

            let startButton = NSButton(title: actionLabel, target: self, action: #selector(handleStartRecording))
            startButton.font = AppFonts.font(size: 12, weight: .medium)
            startButton.frame = NSRect(x: buttonX, y: 15, width: buttonWidth, height: 30)
            startButton.wantsLayer = true
            startButton.layer?.backgroundColor = NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0).cgColor
            startButton.layer?.cornerRadius = 6
            startButton.isBordered = false
            startButton.contentTintColor = .white
            cardView.addSubview(startButton)
        }

        if completionSession != nil {
            // Expose the controls and status text inside the card, rather than a leaf button.
            cardView.setAccessibilityChildren(cardView.subviews)
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
        if let completionSession {
            updateCompletionCard()
            if !completionSession.hasLoaded {
                Task { [weak self] in
                    await completionSession.load()
                    guard let self, self.presentationID == presentationID else { return }
                    if completionSession.errorMessage != nil { self.restartDismissCountdown() }
                }
            }
        }
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
        presentationID = UUID()
        timerID = UUID()
        fadeID = UUID()
        isAutoDismissFading = false
        completionSession?.invalidate()
        completionSession = nil
        contactPicker.close()
        completionParticipantLabel = nil
        completionErrorLabel = nil
        completionButton = nil
        completionCaret = nil
        completionAnchor = nil
        previousKeyWindow = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
        dismissDeadline = nil
        remainingDismissDuration = 0
        isDismissPaused = false
        dismissPauseReasons = []
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
        splitButtonAlternatives = []
        isVisible = false
        currentPromptID = nil
        shownAt = nil
        let closeCallback = onClose
        onClose = nil
        closeCallback?()
    }

    func setDismissPause(_ reason: DismissPauseReason, paused: Bool) {
        if paused { dismissPauseReasons.insert(reason) } else { dismissPauseReasons.remove(reason) }
        if dismissPauseReasons.isEmpty { resumeDismissCountdown() } else { pauseDismissCountdown() }
    }

    private func restartDismissCountdown() {
        startDismissCountdown(duration: currentDismissDuration)
    }

    private func updateCompletionCard() {
        guard let session = completionSession else { return }
        completionParticipantLabel?.stringValue = session.participantSummary(maxWidth: completionParticipantLabel?.frame.width ?? 316)
        completionParticipantLabel?.setAccessibilityValue(session.fullParticipantSummary)
        completionErrorLabel?.stringValue = session.errorMessage ?? ""
        completionButton?.title = session.buttonLabel
        let enabled = session.canPresentPicker && !dismissPauseReasons.contains(.picker)
        setCompletionControlsEnabled(enabled)
        setDismissPause(.work, paused: session.isBusy)
    }

    private func setCompletionControlsEnabled(_ enabled: Bool) {
        for button in [completionButton, completionCaret] {
            button?.isEnabled = enabled
            button?.layer?.opacity = enabled ? 1 : 0.45
        }
    }

    @objc private func handleAddContact(_ sender: NSButton) {
        guard let session = completionSession, session.canPresentPicker,
              !dismissPauseReasons.contains(.picker), sender.window === panel,
              let anchor = completionAnchor, let button = completionButton, let caret = completionCaret else { return }
        let presentationID = self.presentationID
        // A failed initial read retries the participant snapshot before opening ContactsUI.
        if !session.hasLoaded {
            Task { [weak self] in
                await session.load()
                guard let self, self.presentationID == presentationID else { return }
                if session.hasLoaded { self.handleAddContact(sender) } else { self.restartDismissCountdown() }
            }
            return
        }
        setDismissPause(.picker, paused: true)
        updateCompletionCard()
        (panel as? MeetingNotificationPanel)?.allowsPickerKey = true
        previousKeyWindow = NSApplication.shared.keyWindow === panel ? nil : NSApplication.shared.keyWindow
        panel?.makeKey()
        contactPicker.present(relativeTo: anchor, rect: button.frame.union(caret.frame), preferredEdge: .minY, onSelect: { [weak self] contact in
            guard let self, self.presentationID == presentationID else { return }
            // Acquire work before the picker-close callback can release its pause.
            self.setDismissPause(.work, paused: true)
            self.setCompletionControlsEnabled(false)
            Task { [weak self] in
                let result = await session.select(contact)
                guard let self, self.presentationID == presentationID else { return }
                self.updateCompletionCard()
                if result == .added || result == .failed { self.restartDismissCountdown() }
            }
        }, onClose: { [weak self] in
            guard let self, self.presentationID == presentationID else { return }
            self.restorePickerFocus()
            self.setDismissPause(.picker, paused: false)
            // Don't release a selection's work pause before its Task starts.
            if !self.dismissPauseReasons.contains(.work) { self.updateCompletionCard() }
        })
    }

    private func restorePickerFocus() {
        defer { previousKeyWindow = nil }
        guard let panel else { return }
        (panel as? MeetingNotificationPanel)?.allowsPickerKey = false
        guard panel.isKeyWindow else { return }
        if let previousKeyWindow, previousKeyWindow !== panel,
           previousKeyWindow.isVisible, previousKeyWindow.canBecomeKey {
            previousKeyWindow.makeKey()
        } else {
            let presentationID = self.presentationID
            // Ordering releases key status through AppKit; resignKey() is only a notification hook.
            panel.orderOut(nil)
            guard self.panel === panel, self.presentationID == presentationID else { return }
            panel.orderFrontRegardless()
        }
    }

    private func startDismissCountdown(duration: TimeInterval) {
        remainingDismissDuration = duration
        isDismissPaused = false
        progressLayer?.removeAllAnimations()
        progressLayer?.speed = 1
        progressLayer?.timeOffset = 0
        progressLayer?.beginTime = 0
        startProgressAnimation(duration: duration)
        scheduleDismissTimer(after: duration)
        if !dismissPauseReasons.isEmpty { pauseDismissCountdown() }
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
        timerID = UUID()
        let timerID = self.timerID
        dismissDeadline = Date().addingTimeInterval(duration)
        dismissTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.timerID == timerID else { return }
                self.autoDismissNow()
            }
        }
    }

    private func autoDismissNow() {
        guard !isDismissPaused else { return }
        isAutoDismissFading = true
        animateOut { [weak self] in
            guard let self else { return }
            self.isAutoDismissFading = false
            let wasPaused = self.isDismissPaused
            guard !wasPaused else { return }
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
        timerID = UUID()
        if isAutoDismissFading {
            fadeID = UUID()
            isAutoDismissFading = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                panel?.animator().alphaValue = 1
            }
        }
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
        guard isVisible, isDismissPaused, dismissPauseReasons.isEmpty else { return }
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
        fadeID = UUID()
        let fadeID = self.fadeID
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel, self.fadeID == fadeID else { return }
            completion()
        })
    }

    @objc private func handleStartRecording() {
        let action = onStartRecording
        animateOut { [weak self] in self?.close() }
        action?()
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

    /// Maps a join action to the handler that performs it. The transcribe-only handler is
    /// the same `onStartRecording` used by single-action prompts.
    private static func selector(for action: MeetingJoinDefaultAction) -> Selector {
        switch action {
        case .joinAndRecord:
            return #selector(handleJoinAndRecord)
        case .joinOnly:
            return #selector(handleJoinOnly)
        case .recordOnly:
            return #selector(handleStartRecording)
        }
    }

    @objc private func handleChevronClick(_ sender: NSButton) {
        let menu = NSMenu()
        for action in splitButtonAlternatives {
            let item = NSMenuItem(title: action.buttonLabel, action: Self.selector(for: action), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

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

private final class MeetingNotificationPanel: NSPanel {
    var allowsPickerKey = false
    var isCompletionPanel = false
    override var canBecomeKey: Bool { isCompletionPanel ? allowsPickerKey : super.canBecomeKey }
}

private final class CompletionNotificationCardView: NSView {
    var onOpenNotes: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Labels and blank space open notes; button segments retain their own actions.
        var view: NSView? = hit
        while let current = view, current !== self {
            if current is NSButton { return hit }
            view = current.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) { onOpenNotes?() }
    override func accessibilityPerformPress() -> Bool {
        onOpenNotes?()
        return true
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
        if host.hasSuffix("teams.microsoft.com") || host == "teams.live.com" { return .teams }
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
