import AppKit
import QuartzCore

@MainActor
final class DictionarySuggestionPromptController: NSObject {
    private static let dismissDuration: TimeInterval = 15

    private var panel: NSPanel?
    private var dismissTimer: Timer?
    private var progressLayer: CALayer?
    private var dismissDeadline: Date?
    private var remainingDismissDuration: TimeInterval = 0
    private var isDismissPaused = false
    private var onDismiss: (() -> Void)?

    override init() {
        super.init()
    }

    static func shouldAutoDismissFromTimer(isPausedWhenTimerFires: Bool) -> Bool {
        !isPausedWhenTimerFires
    }

    static func shouldCompleteAutoDismissAfterFade(isPausedAtCompletion: Bool) -> Bool {
        !isPausedAtCompletion
    }

    var isShowing: Bool {
        panel != nil
    }

    func show(
        suggestion: DictionarySuggestion,
        anchorFrame: NSRect?,
        onAdd: @escaping () -> Void,
        onIgnore: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        dismiss(notify: false)

        let cardWidth: CGFloat = 356
        let cardHeight: CGFloat = 96
        let closeButtonSize: CGFloat = 22
        let cardX = closeButtonSize / 2 + 1
        let topGutter: CGFloat = closeButtonSize / 2 + 1
        let size = NSSize(width: cardWidth + cardX, height: cardHeight + topGutter)
        let frame = Self.frame(for: size, anchorFrame: anchorFrame)
        let panel = DictionarySuggestionPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let contentView = DictionarySuggestionHoverView(frame: NSRect(origin: .zero, size: size))
        contentView.onMouseEntered = { [weak self] in self?.pauseDismissCountdown() }
        contentView.onMouseExited = { [weak self] in self?.resumeDismissCountdown() }
        contentView.wantsLayer = true

        let cardView = DictionarySuggestionPromptView(
            frame: NSRect(origin: .zero, size: size),
            cardFrame: NSRect(x: cardX, y: 0, width: cardWidth, height: cardHeight),
            suggestion: suggestion,
            onProgressLayerReady: { [weak self] layer in
                self?.progressLayer = layer
            },
            onAdd: { [weak self] in
                self?.dismiss(notify: false)
                onAdd()
            },
            onIgnore: { [weak self] in
                self?.dismiss(notify: false)
                onIgnore()
            }
        )
        contentView.addSubview(cardView)

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

        panel.contentView = contentView

        self.panel = panel
        self.onDismiss = onDismiss
        panel.orderFrontRegardless()
        startDismissCountdown(duration: Self.dismissDuration)
    }

    func dismiss() {
        dismiss(notify: true)
    }

    func dismissWithoutNotification() {
        dismiss(notify: false)
    }

    private func dismiss(notify: Bool) {
        let dismissHandler = onDismiss
        onDismiss = nil
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
        let previousPanel = panel
        panel = nil
        previousPanel?.orderOut(nil)
        previousPanel?.close()
        if notify {
            dismissHandler?()
        }
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
            Task { @MainActor in
                self?.autoDismissNow()
            }
        }
    }

    private func autoDismissNow() {
        guard Self.shouldAutoDismissFromTimer(isPausedWhenTimerFires: isDismissPaused) else { return }
        animateOut { [weak self] in
            guard let self else { return }
            guard Self.shouldCompleteAutoDismissAfterFade(isPausedAtCompletion: self.isDismissPaused) else {
                self.restoreAfterPausedAutoDismissFade()
                return
            }
            self.dismiss(notify: true)
        }
    }

    private func pauseDismissCountdown() {
        guard !isDismissPaused else { return }
        isDismissPaused = true
        if let dismissDeadline {
            remainingDismissDuration = max(2.0, dismissDeadline.timeIntervalSinceNow)
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
        guard isDismissPaused else { return }
        isDismissPaused = false
        scheduleDismissTimer(after: remainingDismissDuration)

        guard let progressLayer else { return }
        let pausedTime = progressLayer.timeOffset
        let resumeHostTime = CACurrentMediaTime()
        progressLayer.speed = 1
        progressLayer.timeOffset = 0
        progressLayer.beginTime = resumeHostTime - pausedTime
    }

    @objc private func handleDismiss() {
        animateOut { [weak self] in
            self?.dismiss()
        }
    }

    private func animateOut(completion: @escaping @MainActor @Sendable () -> Void) {
        guard let panel else { completion(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                completion()
            }
        })
    }

    private func restoreAfterPausedAutoDismissFade() {
        guard let panel else { return }
        panel.alphaValue = 1
    }

    private static func frame(for size: NSSize, anchorFrame: NSRect?) -> NSRect {
        let screenFrame = (anchorFrame.flatMap { anchor in
            NSScreen.screens.first { screen in
                screen.visibleFrame.intersects(anchor)
            }
        } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)

        let anchor = anchorFrame ?? NSRect(
            x: screenFrame.midX - 22,
            y: screenFrame.minY + 24,
            width: 44,
            height: 28
        )

        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + 10
        if y + size.height > screenFrame.maxY {
            y = anchor.minY - size.height - 10
        }
        x = min(max(x, screenFrame.minX + 12), screenFrame.maxX - size.width - 12)
        y = min(max(y, screenFrame.minY + 12), screenFrame.maxY - size.height - 12)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

@MainActor
private final class DictionarySuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DictionarySuggestionHoverView: NSView {
    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

@MainActor
private final class DictionarySuggestionPromptView: NSView {
    private let cardFrame: NSRect
    private let suggestion: DictionarySuggestion
    private let onProgressLayerReady: (CALayer) -> Void
    private let onAdd: () -> Void
    private let onIgnore: () -> Void

    init(
        frame: NSRect,
        cardFrame: NSRect,
        suggestion: DictionarySuggestion,
        onProgressLayerReady: @escaping (CALayer) -> Void,
        onAdd: @escaping () -> Void,
        onIgnore: @escaping () -> Void
    ) {
        self.cardFrame = cardFrame
        self.suggestion = suggestion
        self.onProgressLayerReady = onProgressLayerReady
        self.onAdd = onAdd
        self.onIgnore = onIgnore
        super.init(frame: frame)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        let cardView = NSView(frame: cardFrame)
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 10
        cardView.layer?.masksToBounds = true
        cardView.layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.97).cgColor
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        addSubview(cardView)

        let countdownTrack = CALayer()
        countdownTrack.frame = CGRect(x: 0, y: 0, width: cardFrame.width, height: 5)
        countdownTrack.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        cardView.layer?.addSublayer(countdownTrack)

        let progressBar = CALayer()
        progressBar.frame = countdownTrack.bounds
        progressBar.backgroundColor = NSColor(red: 0.24, green: 0.56, blue: 1.0, alpha: 1.0).cgColor
        progressBar.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressBar.position = CGPoint(x: 0, y: countdownTrack.bounds.midY)
        countdownTrack.addSublayer(progressBar)
        onProgressLayerReady(progressBar)

        let iconSize: CGFloat = 24
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "text.book.closed", accessibilityDescription: "Dictionary")
            ?? NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Dictionary")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 14, y: cardFrame.height - 42, width: iconSize, height: iconSize)
        cardView.addSubview(iconView)

        let textX: CGFloat = 50
        let buttonWidth: CGFloat = 76
        let buttonGap: CGFloat = 8
        let buttonY: CGFloat = 13
        let buttonHeight: CGFloat = 28
        let ignoreX = cardFrame.width - 14 - buttonWidth
        let addX = ignoreX - buttonGap - buttonWidth
        let textWidth = cardFrame.width - textX - 14

        let title = label("Add correction?", font: .systemFont(ofSize: 13, weight: .semibold), color: .white)
        title.frame = NSRect(x: textX, y: 66, width: textWidth, height: 18)
        cardView.addSubview(title)

        let detail = label(
            "\"\(suggestion.observed)\" -> \"\(suggestion.replacement)\"",
            font: .systemFont(ofSize: 13),
            color: NSColor.white.withAlphaComponent(0.72),
            lineBreakMode: .byTruncatingMiddle
        )
        detail.toolTip = "\"\(suggestion.observed)\" -> \"\(suggestion.replacement)\""
        detail.frame = NSRect(x: textX, y: 43, width: textWidth, height: 18)
        cardView.addSubview(detail)

        let add = button(title: "Add", action: #selector(addTapped), isPrimary: true)
        add.frame = NSRect(x: addX, y: buttonY, width: buttonWidth, height: buttonHeight)
        cardView.addSubview(add)

        let ignore = button(title: "Ignore", action: #selector(ignoreTapped), isPrimary: false)
        ignore.frame = NSRect(x: ignoreX, y: buttonY, width: buttonWidth, height: buttonHeight)
        cardView.addSubview(ignore)
    }

    private func label(
        _ text: String,
        font: NSFont,
        color: NSColor,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = lineBreakMode
        return label
    }

    private func button(title: String, action: Selector, isPrimary: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.wantsLayer = true
        button.layer?.backgroundColor = isPrimary
            ? NSColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1.0).cgColor
            : NSColor.white.withAlphaComponent(0.12).cgColor
        button.layer?.cornerRadius = 6
        button.isBordered = false
        button.focusRingType = .none
        button.contentTintColor = .white
        return button
    }

    @objc private func addTapped() {
        onAdd()
    }

    @objc private func ignoreTapped() {
        onIgnore()
    }
}
