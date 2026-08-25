import AppKit
import QuartzCore
import Foundation
import MuesliCore

enum FloatingIndicatorPointerIntent {
    static let dragThreshold: CGFloat = 4

    static func isDrag(from start: NSPoint, to current: NSPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= dragThreshold
    }
}

final class InteractiveFloatingPanel: NSPanel {
    var leftMouseDownHandler: ((NSPoint) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            if leftMouseDownHandler?(event.locationInWindow) == true {
                return
            }
        }
        super.sendEvent(event)
    }
}

@MainActor
private final class HoverIndicatorView: NSView {
    weak var owner: FloatingIndicatorController?
    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownScreenLocation: NSPoint?
    private var windowOriginAtMouseDown: NSPoint?
    private var didDrag = false

    /// In shortcut-pill mode the panel is a large fixed canvas, but only the
    /// visible grip (resting) or pill + capsule (hovered) should intercept
    /// input. Outside those rects clicks fall through to apps underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let owner, !owner.pointerInteractiveRect(in: bounds).contains(point) {
            return nil
        }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        // .inVisibleRect would discard a narrowed rect and track the full
        // bounds, so only include it when the interactive rect is the full
        // bounds (classic style); shortcut-pill tracks its explicit rect.
        let interactiveRect = owner?.pointerInteractiveRect(in: bounds) ?? bounds
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        if interactiveRect.equalTo(bounds) {
            options.insert(.inVisibleRect)
        }
        let tracking = NSTrackingArea(
            rect: interactiveRect,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        owner?.scheduleHoverExit()
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        mouseDownScreenLocation = NSEvent.mouseLocation
        owner?.pointerInteractionBegan()
        windowOriginAtMouseDown = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let mouseDownScreenLocation,
              let windowOriginAtMouseDown else { return }
        let currentScreenLocation = NSEvent.mouseLocation
        let deltaX = currentScreenLocation.x - mouseDownScreenLocation.x
        let deltaY = currentScreenLocation.y - mouseDownScreenLocation.y
        guard didDrag || FloatingIndicatorPointerIntent.isDrag(
            from: mouseDownScreenLocation,
            to: currentScreenLocation
        ) else { return }
        if !didDrag {
            owner?.pointerDragBegan()
        }
        didDrag = true
        window.setFrameOrigin(
            NSPoint(
                x: windowOriginAtMouseDown.x + deltaX,
                y: windowOriginAtMouseDown.y + deltaY
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            owner?.savePosition()
        } else if event.modifierFlags.contains(.option) {
            owner?.handleOptionClick()
        } else {
            let clickX = convert(event.locationInWindow, from: nil).x
            owner?.handleClick(atX: clickX)
        }
        owner?.pointerInteractionEnded()
        mouseDownScreenLocation = nil
        windowOriginAtMouseDown = nil
        didDrag = false
    }

    override func rightMouseUp(with event: NSEvent) {
        owner?.handleOptionClick()
    }
}

// A self-contained rounded "shortcut pill" shown beside the idle indicator on
// hover when `IndicatorHoverStyle.shortcutPill` is configured. Drawn as one
// rounded rectangle so the label never inherits the mic surface's shape.
private final class IdleShortcutPillView: NSView {
    var title = "" {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pillRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.97).setFill()
        pillPath.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        pillPath.lineWidth = 1
        pillPath.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            .paragraphStyle: paragraph
        ]
        let attributedTitle = NSAttributedString(string: title, attributes: attributes)
        let textSize = attributedTitle.size()
        attributedTitle.draw(at: NSPoint(
            x: floor((bounds.width - textSize.width) / 2),
            y: floor((bounds.height - textSize.height) / 2)
        ))
    }
}

@MainActor
final class FloatingIndicatorController: NSObject {
    private var panel: NSPanel?
    private var containerView: NSView?
    private var contentView: HoverIndicatorView?
    private var iconLabel: NSTextField?
    private var textLabel: NSTextField?
    private var state: DictationState = .idle
    private var isHovered = false
    private var lastLoadedConfig: AppConfig?
    private var preservesCollapsedLeftEdge = false
    private var hoverExitWorkItem: DispatchWorkItem?
    private let configStore: ConfigStore
    private var isMeetingRecording = false
    private var isMeetingRecordingPaused = false
    private var isMeetingTranscriptManuallyDismissed = false
    private lazy var meetingTranscriptPanel = FloatingMeetingTranscriptPanelController(
        onHoverChanged: { [weak self] hovered in
            self?.setMeetingTranscriptPanelHovered(hovered)
        },
        onOpenNotes: { [weak self] in
            self?.openMeetingNotesFromTranscript()
        },
        onDismiss: { [weak self] in
            self?.dismissMeetingTranscript()
        }
    )
    private var glassView: NSVisualEffectView?
    private var tintLayer: CALayer?
    private var idleShortcutPillView: IdleShortcutPillView?
    private var idleIconBackgroundLayer: CALayer?
    private var micIconView: NSImageView?
    private var wandIconView: NSImageView?
    private var quillIconView: NSImageView?
    private var barLayers: [CALayer] = []
    private var amplitudeTimer: Timer?
    private var smoothedAmplitude: CGFloat = 0
    private var waveformAnimationMode: WaveformAnimationMode = .level
    private var recordingWaveformMode: WaveformAnimationMode = .level
    private var waveformAnimationStartedAt = Date()
    fileprivate var isDragging = false
    var powerProvider: (() -> Float)?
    var onStopMeeting: (() -> Void)?
    var onDiscardMeeting: (() -> Void)?
    var onToggleMeetingPause: (() -> Void)?
    var onOpenMeetingNotes: (() -> Void)?
    var onCancelToggleDictation: (() -> Void)?
    var onPositionSaved: ((CGPoint) -> Void)?
    var isToggleDictation = false
    private var stopLayer: CALayer?
    private var transcribingTitle = "Transcribing"
    private var instructionTranscriptText: String?
    private var instructionTranscriptShowsProgress = false
    private var loadingSpinner: NSProgressIndicator?
    private var isShowingLoading = false
    private var isComputerUseCursorMode = false
    private var computerUseCursorReturnFrame: NSRect?

    private enum WaveformAnimationMode {
        case level
        case waiting
    }

    init(configStore: ConfigStore) {
        self.configStore = configStore
        super.init()
    }

    var onStopToggleDictation: (() -> Void)?

    var currentFrame: NSRect? {
        indicatorScreenFrame
    }

    func pointerDragBegan() {
        hideMeetingTranscript()
    }

    func pointerInteractionBegan() {
        isDragging = true
        hoverExitWorkItem?.cancel()
    }

    func pointerInteractionEnded() {
        isDragging = false
        if state == .idle, isHovered, !pointerIsInsidePanel() {
            scheduleHoverExit()
        }
    }

    func handleClick(atX x: CGFloat? = nil) {
        if state == .recording, let x {
            if x < 30 {
                if isMeetingRecording {
                    onToggleMeetingPause?()
                } else {
                    onCancelToggleDictation?()
                }
            } else {
                if isMeetingRecording {
                    onStopMeeting?()
                } else {
                    onStopToggleDictation?()
                }
            }
        } else if state == .recording {
            if isMeetingRecording {
                onStopMeeting?()
            } else {
                onStopToggleDictation?()
            }
        }
    }

    func handleOptionClick() {
        if isMeetingRecording, state == .recording {
            onDiscardMeeting?()
        } else if state == .recording {
            onCancelToggleDictation?()
        }
    }

    func savePosition() {
        guard let frame = indicatorScreenFrame else { return }
        let center = Self.positionCenter(
            for: frame,
            preservesCollapsedLeftEdge: preservesCollapsedLeftEdge
        )
        onPositionSaved?(center)
    }

    func setToggleDictation(_ active: Bool, config: AppConfig) {
        isToggleDictation = active
        if active {
            setState(.recording, config: config)
        } else {
            removeStopLayer()
            setState(.idle, config: config)
        }
    }

    func setMeetingRecording(_ recording: Bool, config: AppConfig) {
        isMeetingRecording = recording
        recordingWaveformMode = .level
        if !recording {
            isMeetingRecordingPaused = false
            hideMeetingTranscript(reset: true)
        }
        if recording {
            setState(.recording, config: config)
        } else {
            setState(.idle, config: config)
        }
    }

    func setRecordingWaveformWaiting(config: AppConfig) {
        recordingWaveformMode = .waiting
        guard state == .recording else { return }
        let targetSize = frameForState(.recording, config: config).size
        ensureWaveformAnimation(in: targetSize, mode: .waiting)
    }

    func setRecordingWaveformLevel(config: AppConfig) {
        recordingWaveformMode = .level
        guard state == .recording else {
            setState(.recording, config: config)
            return
        }
        let targetSize = frameForState(.recording, config: config).size
        ensureWaveformAnimation(in: targetSize, mode: .level)
    }

    func setPreparingWaveformWaiting(config: AppConfig) {
        recordingWaveformMode = .waiting
        guard state == .preparing else {
            setState(.preparing, config: config)
            return
        }
        if let contentView {
            ensureWaveformAnimation(in: contentView.frame.size, mode: .waiting)
        }
    }

    func setMeetingRecordingPaused(_ paused: Bool, config: AppConfig) {
        guard isMeetingRecordingPaused != paused else { return }
        isMeetingRecordingPaused = paused
        meetingTranscriptPanel.setPaused(paused)
        hideMeetingTranscript()
        guard isMeetingRecording, state == .recording else { return }
        setState(.recording, config: config)
    }

    func updateMeetingTranscript(
        transcript: String,
        partialYou: String,
        partialOthers: String
    ) {
        meetingTranscriptPanel.update(
            transcript: transcript,
            partialYou: partialYou,
            partialOthers: partialOthers
        )
    }

    func refreshMeetingTranscriptPreference(config: AppConfig) {
        guard config.showMeetingTranscriptOnIndicatorHover else {
            hideMeetingTranscript()
            return
        }
        if isMeetingRecording,
           state == .recording,
           pointerIsInsidePanel(),
           panel != nil {
            showMeetingTranscript()
        }
    }

    private var indicatorScreenFrame: NSRect? {
        guard let panel, let contentView else { return nil }
        return panel.convertToScreen(contentView.frame)
    }

    private func showMeetingTranscript() {
        guard let panel,
              let containerView,
              let contentView,
              let indicatorFrame = indicatorScreenFrame else { return }
        panel.ignoresMouseEvents = false
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(indicatorFrame) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let transcriptFrame = FloatingMeetingTranscriptPlacement.frame(
            beside: indicatorFrame,
            visibleFrame: visibleFrame
        )
        let expandedFrame = indicatorFrame.union(transcriptFrame)
        panel.setFrame(expandedFrame, display: true)
        containerView.frame = NSRect(origin: .zero, size: expandedFrame.size)
        contentView.frame = localFrame(indicatorFrame, in: expandedFrame)
        meetingTranscriptPanel.show(
            in: containerView,
            frame: localFrame(transcriptFrame, in: expandedFrame)
        )
    }

    private func hideMeetingTranscript(reset: Bool = false) {
        guard meetingTranscriptPanel.isVisible else {
            if reset { meetingTranscriptPanel.reset() }
            return
        }
        guard let panel,
              let containerView,
              let contentView,
              let indicatorFrame = indicatorScreenFrame else {
            if reset { meetingTranscriptPanel.reset() } else { meetingTranscriptPanel.hide() }
            return
        }
        if reset {
            meetingTranscriptPanel.reset()
        } else {
            meetingTranscriptPanel.hide()
        }
        panel.setFrame(indicatorFrame, display: true)
        containerView.frame = NSRect(origin: .zero, size: indicatorFrame.size)
        contentView.frame = NSRect(origin: .zero, size: indicatorFrame.size)
    }

    private func localFrame(_ screenFrame: NSRect, in windowFrame: NSRect) -> NSRect {
        NSRect(
            x: screenFrame.minX - windowFrame.minX,
            y: screenFrame.minY - windowFrame.minY,
            width: screenFrame.width,
            height: screenFrame.height
        )
    }

    func setTranscribingTitle(_ title: String, config: AppConfig) {
        instructionTranscriptText = nil
        instructionTranscriptShowsProgress = false
        hideInstructionProgress()
        transcribingTitle = title
        guard state == .transcribing else { return }
        setState(.transcribing, config: config)
    }

    func showComputerUseTranscript(_ transcript: String, config: AppConfig) {
        showInstructionTranscript(
            transcript,
            fallbackTitle: "Starting CUA",
            showsProgress: false,
            config: config
        )
    }

    func showQuilInstruction(_ instruction: String, config: AppConfig) {
        showInstructionTranscript(
            instruction,
            fallbackTitle: "Rewriting selection",
            showsProgress: true,
            config: config
        )
    }

    private func showInstructionTranscript(
        _ transcript: String,
        fallbackTitle: String,
        showsProgress: Bool,
        config: AppConfig
    ) {
        let normalized = Self.normalizedInstructionTranscript(transcript)
        instructionTranscriptText = normalized.isEmpty ? nil : normalized
        instructionTranscriptShowsProgress = showsProgress && !normalized.isEmpty
        transcribingTitle = normalized.isEmpty ? fallbackTitle : normalized
        setState(.transcribing, config: config)
    }

    func setState(_ state: DictationState, config: AppConfig) {
        lastLoadedConfig = config
        let previousState = self.state
        let previousHover = isHovered
        let previouslyPreservedCollapsedLeftEdge = preservesCollapsedLeftEdge
        if isComputerUseCursorMode {
            exitComputerUseCursorMode(restoreFrame: false)
        }
        self.state = state
        if state != .idle {
            hideShortcutPillChrome()
        }
        if state != .transcribing {
            transcribingTitle = "Transcribing"
            instructionTranscriptText = nil
            instructionTranscriptShowsProgress = false
            hideInstructionProgress()
        } else if !instructionTranscriptShowsProgress {
            hideInstructionProgress()
        }
        if state != .recording {
            recordingWaveformMode = .level
        }
        if state != .idle {
            isHovered = false
        }
        preservesCollapsedLeftEdge = state == .idle && isHovered
        if !config.showFloatingIndicator && state == .idle {
            close()
            return
        }
        if panel == nil {
            createPanel(config: config)
        }
        guard let panel, let contentView, let iconLabel, let textLabel else { return }

        let preservesWaveformAcrossTransition = previousState == .preparing && state == .recording
        if (previousState == .recording || previousState == .preparing)
            && state != previousState
            && !preservesWaveformAcrossTransition {
            stopWaveformAnimation()
        }

        // Immediately snap glass elements off when leaving idle so the SF Symbol
        // mic doesn't linger/fade during the recording/transcribing transition.
        if state != .idle {
            micIconView?.isHidden = true
            glassView?.isHidden = true
            tintLayer?.isHidden = true

        }

        let style = styleForState(state, config: config)
        let customPositionCenter: CGPoint?
        if previousState == .idle,
           state != .idle,
           config.indicatorAnchor == .custom,
           let currentFrame = indicatorScreenFrame {
            customPositionCenter = Self.positionCenter(
                for: currentFrame,
                preservesCollapsedLeftEdge: previouslyPreservedCollapsedLeftEdge
            )
        } else {
            customPositionCenter = nil
        }
        let targetFrame = frameForState(
            state,
            config: config,
            customPositionCenter: customPositionCenter
        )

        let duration = transitionDuration(
            from: previousState,
            to: state,
            wasHovered: previousHover,
            isHovered: isHovered
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = style.alpha

            contentView.animator().frame = NSRect(origin: .zero, size: targetFrame.size)
            contentView.layer?.cornerRadius = targetFrame.height / 2
            contentView.layer?.backgroundColor = style.background.cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = style.border.cgColor

            if state == .recording {
                // Dictation uses cancel on the left. Meeting recordings use pause/resume.
                iconLabel.isHidden = false
                iconLabel.animator().alphaValue = 1
                iconLabel.stringValue = recordingControlSymbol()
                iconLabel.textColor = .white.withAlphaComponent(isMeetingRecording ? 0.86 : 0.45)
                iconLabel.font = NSFont.systemFont(ofSize: isMeetingRecording ? 8 : 7, weight: .semibold)
                let xSize: CGFloat = 10
                iconLabel.frame = NSRect(
                    x: 7,
                    y: floor((targetFrame.height - xSize) / 2),
                    width: xSize,
                    height: xSize
                )

                textLabel.animator().alphaValue = 0
                textLabel.isHidden = true
            } else {
                iconLabel.isHidden = false
                iconLabel.animator().alphaValue = 1
                iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
                iconLabel.stringValue = style.icon
                iconLabel.textColor = style.iconColor
                configureTextLabelForTranscript(state == .transcribing && instructionTranscriptText != nil)
                textLabel.stringValue = style.title
                textLabel.textColor = style.textColor
                textLabel.animator().alphaValue = style.title.isEmpty ? 0 : 1
                textLabel.isHidden = style.title.isEmpty
                if state == .transcribing, instructionTranscriptText != nil {
                    layoutInstructionTranscript(in: targetFrame.size, animated: true)
                } else {
                    layoutLabels(
                        iconLabel: iconLabel,
                        textLabel: textLabel,
                        in: targetFrame.size,
                        hasTitle: !style.title.isEmpty,
                        animated: true
                    )
                }
            }

            // Apply glass state last so it can override iconLabel visibility set above.
            applyGlassState(state, frameSize: targetFrame.size)
        }

        // Manage SF Symbol effects — stop everything first, then start for the new state.
        micIconView?.removeAllSymbolEffects(animated: false)
        wandIconView?.removeAllSymbolEffects(animated: false)

        switch state {
        case .recording:
            ensureWaveformAnimation(in: targetFrame.size, mode: recordingWaveformMode)
            addStopLayer(in: targetFrame.size)
        case .transcribing:
            if #available(macOS 15, *) {
                wandIconView?.addSymbolEffect(
                    .wiggle.backward.byLayer,
                    options: .repeating, animated: true
                )
            }
        case .preparing:
            hideShortcutPillChrome()
            ensureWaveformAnimation(in: targetFrame.size, mode: .waiting)
        default:
            break
        }

        panel.orderFrontRegardless()
        if state == .preparing {
            contentView.displayIfNeeded()
            panel.displayIfNeeded()
        }
    }

    func showComputerUseCursor(at quartzPoint: CGPoint, label rawLabel: String?) {
        hideShortcutPillChrome()
        let config = configStore.load()
        if panel == nil {
            createPanel(config: config)
        }
        guard let panel, let contentView, let iconLabel, let textLabel else { return }

        if !isComputerUseCursorMode {
            computerUseCursorReturnFrame = panel.frame
        }
        isComputerUseCursorMode = true
        hoverExitWorkItem?.cancel()
        isHovered = false
        preservesCollapsedLeftEdge = false
        isShowingLoading = false
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.isHidden = true
        stopWaveformAnimation()

        let label = Self.cursorLabel(rawLabel)
        let targetSize = Self.computerUseCursorSize(label: label)
        let targetFrame = Self.computerUseCursorFrame(
            forQuartzPoint: quartzPoint,
            size: targetSize,
            offsetFromTarget: !label.isEmpty
        )

        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        glassView?.isHidden = true
        tintLayer?.isHidden = true
        micIconView?.isHidden = true
        wandIconView?.isHidden = true
        quillIconView?.isHidden = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1.0
            contentView.animator().frame = NSRect(origin: .zero, size: targetSize)
            contentView.layer?.cornerRadius = targetSize.height / 2
            contentView.layer?.backgroundColor = NSColor.colorWith(hex: 0x1455D9, alpha: 0.88).cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = NSColor.colorWith(hex: 0xFFFFFF, alpha: 0.34).cgColor

            iconLabel.isHidden = false
            iconLabel.animator().alphaValue = 1
            iconLabel.stringValue = "•"
            iconLabel.font = NSFont.systemFont(ofSize: 18, weight: .heavy)
            iconLabel.textColor = .white

            textLabel.stringValue = label
            textLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            textLabel.textColor = .white.withAlphaComponent(0.92)
            textLabel.isHidden = label.isEmpty
            textLabel.animator().alphaValue = label.isEmpty ? 0 : 1
            layoutLabels(
                iconLabel: iconLabel,
                textLabel: textLabel,
                in: targetSize,
                hasTitle: !label.isEmpty,
                animated: true
            )
        }
        panel.orderFrontRegardless()
    }

    func hideComputerUseCursor() {
        exitComputerUseCursorMode(restoreFrame: true)
    }

    func ensureVisible(config: AppConfig) {
        setState(state, config: config)
    }

    /// Refresh the idle icon to match the user's selected menu bar icon.
    func refreshIcon() {
        let config = configStore.load()
        let fallback = NSImage(systemSymbolName: "waveform.badge.microphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? NSImage()
        let newImage = MenuBarIconRenderer.make(choice: config.menuBarIcon) ?? fallback
        newImage.isTemplate = true
        micIconView?.image = newImage
    }

    /// Flash a brief warning message on the indicator pill, then snap back to idle.
    func showWarning(_ message: String, icon: String = "⚡", duration: TimeInterval = 2.5) {
        hideShortcutPillChrome()
        guard state == .idle else { return }
        let config = configStore.load()
        if panel == nil { createPanel(config: config) }
        guard let panel, let contentView, let iconLabel, let textLabel else { return }
        guard let screen = NSScreen.main?.visibleFrame else { return }

        preservesCollapsedLeftEdge = false
        let warningFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let warningSize = warningPillSize(
            message: message,
            icon: icon,
            font: warningFont,
            screen: screen
        )
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let x = min(max(center.x - warningSize.width / 2, screen.minX), screen.maxX - warningSize.width)
        let y = min(max(center.y - warningSize.height / 2, screen.minY), screen.maxY - warningSize.height)
        let targetFrame = NSRect(x: x, y: y, width: warningSize.width, height: warningSize.height)

        // Warning uses its own solid amber background — hide glass layers.
        glassView?.isHidden = true
        tintLayer?.isHidden = true
        micIconView?.isHidden = true

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1.0
            contentView.animator().frame = NSRect(origin: .zero, size: warningSize)
            contentView.layer?.cornerRadius = warningSize.height / 2
            contentView.layer?.backgroundColor = NSColor.colorWith(hex: 0xD99A11, alpha: 0.92).cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = NSColor.colorWith(hex: 0xFFFFFF, alpha: 0.24).cgColor

            let hasIcon = !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            iconLabel.isHidden = !hasIcon
            iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
            iconLabel.stringValue = icon
            iconLabel.textColor = NSColor.colorWith(hex: 0x1A140D, alpha: 0.95)
            iconLabel.animator().alphaValue = hasIcon ? 1 : 0

            textLabel.stringValue = message
            textLabel.font = warningFont
            textLabel.textColor = NSColor.colorWith(hex: 0x1A140D, alpha: 0.95)
            textLabel.isHidden = false
            textLabel.animator().alphaValue = 1
            layoutLabels(iconLabel: iconLabel, textLabel: textLabel, in: warningSize, hasTitle: true, animated: true)
        }
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.state == .idle else { return }
            self.setState(.idle, config: self.configStore.load())
        }
    }

    private func warningPillSize(message: String, icon: String, font: NSFont, screen: NSRect) -> NSSize {
        let horizontalPadding: CGFloat = 18
        let hasIcon = !icon.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let iconWidth = hasIcon
            ? max(24, ceil((icon as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold)]).width) + 2)
            : 0
        let iconGap: CGFloat = hasIcon ? 4 : 0
        let textWidth = ceil((message as NSString).size(withAttributes: [.font: font]).width) + 2
        let preferredWidth = horizontalPadding + iconWidth + iconGap + textWidth + horizontalPadding
        let minWidth: CGFloat = hasIcon ? 180 : 88
        let maxWidth = max(minWidth, min(640, screen.width - 32))
        return NSSize(width: min(max(preferredWidth, minWidth), maxWidth), height: 36)
    }

    func showLoading(_ message: String) {
        hideShortcutPillChrome()
        let config = configStore.load()
        if panel == nil { createPanel(config: config) }
        guard let panel, let contentView, let textLabel else { return }
        guard let screen = NSScreen.main?.visibleFrame else { return }

        isShowingLoading = true
        preservesCollapsedLeftEdge = false
        let loadingSize = loadingPillSize(message: message, screen: screen)
        let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let x = min(max(center.x - loadingSize.width / 2, screen.minX), screen.maxX - loadingSize.width)
        let y = min(max(center.y - loadingSize.height / 2, screen.minY), screen.maxY - loadingSize.height)
        let targetFrame = NSRect(x: x, y: y, width: loadingSize.width, height: loadingSize.height)

        ensureLoadingSpinner(in: contentView)

        let spinnerSize: CGFloat = 16
        let gap: CGFloat = 8
        let horizontalPadding: CGFloat = 16
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        let measuredTextW = ceil((message as NSString).size(withAttributes: attrs).width) + 2
        let availableTextW = max(40, loadingSize.width - (horizontalPadding * 2) - spinnerSize - gap)
        let textW = min(measuredTextW, availableTextW)
        let totalW = spinnerSize + gap + textW
        let startX = max(horizontalPadding, (loadingSize.width - totalW) / 2)

        micIconView?.isHidden = true
        wandIconView?.isHidden = true
        quillIconView?.isHidden = true
        iconLabel?.isHidden = true
        glassView?.isHidden = false
        tintLayer?.isHidden = false
        tintLayer?.backgroundColor = NSColor.colorWith(hexString: "1e1e2e", alpha: 0.72).cgColor
        applyTintLayerGeometry(size: loadingSize, radius: loadingSize.height / 2)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true

            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1.0
            contentView.animator().frame = NSRect(origin: .zero, size: loadingSize)
            contentView.layer?.cornerRadius = loadingSize.height / 2
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.borderWidth = 1.0
            contentView.layer?.borderColor = NSColor.colorWith(hex: 0xFFFFFF, alpha: 0.16).cgColor

            loadingSpinner?.frame = NSRect(
                x: startX, y: (loadingSize.height - spinnerSize) / 2,
                width: spinnerSize, height: spinnerSize
            )
            loadingSpinner?.isHidden = false
            loadingSpinner?.startAnimation(nil)

            textLabel.stringValue = message
            textLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.maximumNumberOfLines = 1
            textLabel.usesSingleLineMode = true
            textLabel.cell?.wraps = false
            textLabel.cell?.isScrollable = false
            textLabel.textColor = NSColor.colorWith(hex: 0xFFFFFF, alpha: 0.82)
            textLabel.frame = NSRect(
                x: startX + spinnerSize + gap,
                y: (loadingSize.height - 14) / 2,
                width: textW, height: 14
            )
            textLabel.isHidden = false
            textLabel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
    }

    private func loadingPillSize(message: String, screen: NSRect) -> NSSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let spinnerSize: CGFloat = 16
        let gap: CGFloat = 8
        let horizontalPadding: CGFloat = 16
        let textWidth = ceil((message as NSString).size(withAttributes: [.font: font]).width) + 2
        let preferredWidth = horizontalPadding + spinnerSize + gap + textWidth + horizontalPadding
        let minWidth = min(CGFloat(180), max(120, screen.width - 32))
        let maxWidth = max(minWidth, min(360, screen.width - 32))
        return NSSize(width: min(max(preferredWidth, minWidth), maxWidth), height: 36)
    }

    private func ensureLoadingSpinner(in contentView: NSView) {
        guard loadingSpinner == nil else { return }
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.isHidden = true
        contentView.addSubview(spinner)
        loadingSpinner = spinner
    }

    private func hideInstructionProgress() {
        guard !isShowingLoading else { return }
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.isHidden = true
    }

    func hideLoading() {
        guard isShowingLoading else { return }
        isShowingLoading = false
        loadingSpinner?.stopAnimation(nil)
        loadingSpinner?.isHidden = true
        // Only reset to idle if no dictation started during the warmup window
        if state == .idle || state == .preparing {
            setState(.idle, config: configStore.load())
        }
    }

    func setHovered(_ hovered: Bool) {
        if state == .recording, isMeetingRecording, !isShowingLoading, !isDragging {
            guard hovered else {
                isMeetingTranscriptManuallyDismissed = false
                hideMeetingTranscript()
                return
            }
            guard !isMeetingTranscriptManuallyDismissed else { return }
            let config = configStore.load()
            guard config.showMeetingTranscriptOnIndicatorHover, panel != nil else { return }
            hoverExitWorkItem?.cancel()
            showMeetingTranscript()
            return
        }
        guard state == .idle, !isShowingLoading, !isDragging, isHovered != hovered else { return }
        hoverExitWorkItem?.cancel()
        isHovered = hovered
        let config = configStore.load()
        setState(.idle, config: config)
        contentView?.updateTrackingAreas()
        if hovered, config.indicatorHoverStyle == .shortcutPill {
            animateIdleHoverPop()
        }

    }

    func scheduleHoverExit() {
        if state == .recording, isMeetingRecording, meetingTranscriptPanel.isVisible {
            scheduleMeetingTranscriptHoverExit()
            return
        }
        guard state == .idle, !isShowingLoading, isHovered else { return }
        hoverExitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.pointerIsInsidePanel() else { return }
            self.setHovered(false)
        }
        hoverExitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: workItem)
    }

    func closeIfIdle() {
        if state == .idle, !isShowingLoading { close() }
    }

    func close() {
        stopWaveformAnimation()
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
        preservesCollapsedLeftEdge = false
        panel?.close()
        panel = nil
        containerView = nil
        contentView = nil
        iconLabel = nil
        textLabel = nil
        glassView = nil
        tintLayer = nil
        micIconView = nil
        wandIconView = nil
        quillIconView = nil
        loadingSpinner = nil
        instructionTranscriptShowsProgress = false
        isShowingLoading = false
        meetingTranscriptPanel.close()
    }

    private func setMeetingTranscriptPanelHovered(_ hovered: Bool) {
        if hovered {
            hoverExitWorkItem?.cancel()
        } else {
            scheduleMeetingTranscriptHoverExit()
        }
    }

    private func dismissMeetingTranscript() {
        isMeetingTranscriptManuallyDismissed = true
        hoverExitWorkItem?.cancel()
        hideMeetingTranscript()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.pointerIsInsidePanel() else { return }
            self.isMeetingTranscriptManuallyDismissed = false
        }
    }

    private func openMeetingNotesFromTranscript() {
        hideMeetingTranscript()
        onOpenMeetingNotes?()
    }

    private func scheduleMeetingTranscriptHoverExit() {
        hoverExitWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.pointerIsInsidePanel(),
                  !self.meetingTranscriptPanel.containsMouseLocation() else { return }
            self.hideMeetingTranscript()
        }
        hoverExitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    // MARK: - Stop Layer (toggle dictation)

    private func addStopLayer(in size: NSSize) {
        removeStopLayer()
        guard let contentView else { return }

        let sq: CGFloat = 6
        let stop = CALayer()
        stop.frame = CGRect(
            x: size.width - sq - 8,
            y: floor((size.height - sq) / 2),
            width: sq,
            height: sq
        )
        stop.cornerRadius = 1
        stop.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor

        contentView.layer?.addSublayer(stop)
        stopLayer = stop
    }

    private func recordingControlSymbol() -> String {
        guard isMeetingRecording else { return "\u{2715}" }
        return isMeetingRecordingPaused ? "\u{25B6}" : "\u{23F8}"
    }

    private func removeStopLayer() {
        stopLayer?.removeFromSuperlayer()
        stopLayer = nil
    }

    private func stopWaveformAnimation() {
        amplitudeTimer?.invalidate()
        amplitudeTimer = nil
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        smoothedAmplitude = 0
        waveformAnimationMode = .level
        powerProvider = nil
        contentView?.layer?.transform = CATransform3DIdentity
        removeStopLayer()
    }

    private func setupWaveformBars(in frameSize: NSSize) {
        barLayers.forEach { $0.removeFromSuperlayer() }
        barLayers.removeAll()
        guard let layer = contentView?.layer else { return }

        let barCount = 5
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 3
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (frameSize.width - totalWidth) / 2
        let minHeight: CGFloat = 4

        for i in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
            bar.cornerRadius = barWidth / 2
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            bar.frame = CGRect(x: x, y: (frameSize.height - minHeight) / 2, width: barWidth, height: minHeight)
            layer.addSublayer(bar)
            barLayers.append(bar)
        }
    }

    private func updateWaveformBarsLayout(in frameSize: NSSize) {
        guard !barLayers.isEmpty else { return }
        let barWidth: CGFloat = 3
        let barSpacing: CGFloat = 3
        let totalWidth = CGFloat(barLayers.count) * barWidth + CGFloat(max(0, barLayers.count - 1)) * barSpacing
        let startX = (frameSize.width - totalWidth) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            var frame = bar.frame
            frame.origin.x = startX + CGFloat(i) * (barWidth + barSpacing)
            frame.origin.y = (frameSize.height - frame.height) / 2
            frame.size.width = barWidth
            bar.frame = frame
            bar.cornerRadius = barWidth / 2
        }
        CATransaction.commit()
    }

    private func ensureWaveformAnimation(in frameSize: NSSize, mode: WaveformAnimationMode) {
        if barLayers.isEmpty {
            setupWaveformBars(in: frameSize)
        } else {
            updateWaveformBarsLayout(in: frameSize)
        }
        setWaveformAnimationMode(mode)
        if amplitudeTimer == nil {
            startWaveformAnimation(mode: mode)
        }
    }

    private func setWaveformAnimationMode(_ mode: WaveformAnimationMode) {
        guard waveformAnimationMode != mode else { return }
        waveformAnimationMode = mode
        waveformAnimationStartedAt = Date()
    }

    private func startWaveformAnimation(mode: WaveformAnimationMode) {
        amplitudeTimer?.invalidate()
        waveformAnimationMode = mode
        waveformAnimationStartedAt = Date()
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(waveformTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        amplitudeTimer = timer
    }

    @objc private func waveformTimerFired(_ timer: Timer) {
        guard let contentView else { return }
        let multipliers: [CGFloat] = [0.6, 0.85, 1.0, 0.85, 0.6]
        let minHeight: CGFloat = 3
        let maxHeight: CGFloat = 14
        let pillHeight = contentView.frame.height
        let elapsed = CGFloat(Date().timeIntervalSince(waveformAnimationStartedAt))
        let levelAmplitude: CGFloat
        if waveformAnimationMode == .level {
            let dB = CGFloat(powerProvider?() ?? -160)
            let raw = max(0, min(1, (dB + 68) / 38))
            smoothedAmplitude = 0.48 * raw + 0.52 * smoothedAmplitude
            levelAmplitude = smoothedAmplitude
        } else {
            levelAmplitude = 0
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in barLayers.enumerated() {
            let m = i < multipliers.count ? multipliers[i] : 1.0
            let amplitude: CGFloat
            switch waveformAnimationMode {
            case .level:
                amplitude = levelAmplitude * m
                bar.opacity = 0.85
            case .waiting:
                let phase = elapsed * 5.8 + CGFloat(i) * 0.72
                amplitude = 0.28 + (sin(phase) + 1) * 0.22 * m
                bar.opacity = Float(0.38 + (sin(phase) + 1) * 0.18)
            }
            let h = minHeight + (maxHeight - minHeight) * amplitude
            bar.frame.size.height = h
            bar.frame.origin.y = (pillHeight - h) / 2
        }
        CATransaction.commit()
    }


    /// The rect that should respond to pointer input right now. Classic style
    /// uses the full panel; shortcut-pill limits interaction to the visible
    /// resting grip, expanding to the label pill + mic capsule only while hovered.
    func pointerInteractiveRect(in bounds: NSRect) -> NSRect {
        // Cache: hit-testing runs on the pointer hot path; reading + decoding
        // config from disk per event would add avoidable main-thread latency.
        let config = lastLoadedConfig ?? configStore.load()
        guard state == .idle, config.indicatorHoverStyle == .shortcutPill else { return bounds }
        let placement = idleHoverPlacement(for: config.indicatorAnchor)
        if isHovered {
            let (pill, _, _, _) = shortcutPillHoverFrame(
                placement: placement,
                frameSize: bounds.size,
                config: config
            )
            return pill.insetBy(dx: -6, dy: -6).intersection(bounds)
        }
        return idleRestingHandleFrame(placement: placement, frameSize: bounds.size)
            .insetBy(dx: -6, dy: -6)
            .intersection(bounds)
    }

    /// Unified hover pill for `IndicatorHoverStyle.shortcutPill`: the classic
    /// stadium shape (icon + text in one rounded rectangle), popping
    /// bottom-to-top from the resting grip instead of left-to-right.
    private func shortcutPillHoverFrame(
        placement: IdleHoverPlacement,
        frameSize: NSSize,
        config: AppConfig
    ) -> (pill: CGRect, title: String, font: NSFont, textWidth: CGFloat) {
        let title = "Hold \(config.dictationHotkey.label) to dictate"
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 4
        let pad: CGFloat = 14
        let gap: CGFloat = 6
        let iconW: CGFloat = 15
        let pillW = pad + iconW + gap + textWidth + pad
        let pillH: CGFloat = 30
        let handle = idleRestingHandleFrame(placement: placement, frameSize: frameSize)
        let pill: CGRect
        switch placement {
        case .above:
            // Grip at the canvas bottom; the pill grows upward from its baseline.
            pill = CGRect(x: handle.midX - pillW / 2, y: handle.minY, width: pillW, height: pillH)
        case .below:
            pill = CGRect(x: handle.midX - pillW / 2, y: handle.maxY - pillH, width: pillW, height: pillH)
        case .leading:
            // Grip sits at the canvas's trailing edge; pop leftward from it.
            pill = CGRect(x: handle.maxX - pillW, y: handle.midY - pillH / 2, width: pillW, height: pillH)
        case .trailing:
            // Grip sits at the leading edge; pop rightward from it.
            pill = CGRect(x: handle.minX, y: handle.midY - pillH / 2, width: pillW, height: pillH)
        }
        return (pill, title, font, textWidth)
    }

    /// Shortcut-pill chrome belongs to the idle presentation only. Every
    /// non-idle path (transcribing, loading, warning, automation cursor) must
    /// clear it or the grip/label lingers on top of those overlays.
    private func hideShortcutPillChrome() {
        idleShortcutPillView?.isHidden = true
        idleIconBackgroundLayer?.isHidden = true
    }

    /// Idle layout for `IndicatorHoverStyle.shortcutPill`: the resting state is a
    /// thin grip handle; on hover the mic capsule and an adjacent rounded label
    /// pill appear without resizing the window.
    private func layoutShortcutPillIdle(frameSize: NSSize, config: AppConfig) {
        // Transparent host: only the resting grip or the unified hover pill
        // draws. The classic canvas chrome would paint the whole area as a blob.
        tintLayer?.isHidden = true
        glassView?.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentView?.layer?.borderWidth = 0
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
        wandIconView?.isHidden = true
        quillIconView?.isHidden = true
        iconLabel?.isHidden = true
        idleShortcutPillView?.isHidden = true

        let placement = idleHoverPlacement(for: config.indicatorAnchor)
        let (pillFrame, title, font, textWidth) = shortcutPillHoverFrame(
            placement: placement,
            frameSize: frameSize,
            config: config
        )
        let restingHandle = idleRestingHandleFrame(
            placement: placement,
            frameSize: frameSize
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        idleIconBackgroundLayer?.isHidden = false
        idleIconBackgroundLayer?.backgroundColor = isHovered
            ? NSColor.colorWith(hex: 0x111111, alpha: 1).cgColor
            : NSColor.colorWith(hex: 0x696969, alpha: 0.82).cgColor
        idleIconBackgroundLayer?.borderWidth = isHovered ? 1 : 0
        idleIconBackgroundLayer?.frame = isHovered ? pillFrame : restingHandle
        idleIconBackgroundLayer?.cornerRadius = isHovered ? pillFrame.height / 2 : 5
        CATransaction.commit()

        let iconSize = NSSize(width: 15, height: 15)
        micIconView?.isHidden = !isHovered
        if let mic = micIconView {
            mic.alphaValue = 1
            mic.frame = NSRect(
                x: pillFrame.minX + 14,
                y: pillFrame.midY - iconSize.height / 2,
                width: iconSize.width,
                height: iconSize.height
            )
        }

        if let textLabel {
            textLabel.stringValue = title
            textLabel.font = font
            textLabel.textColor = .white.withAlphaComponent(0.88)
            textLabel.alignment = .left
            textLabel.isHidden = !isHovered
            textLabel.alphaValue = isHovered ? 1 : 0
            textLabel.frame = NSRect(
                x: pillFrame.minX + 14 + 15 + 6,
                y: pillFrame.midY - 8,
                width: textWidth,
                height: 16
            )
        }
    }

    private func applyGlassState(_ state: DictationState, frameSize: NSSize) {
        let config = configStore.load()
        let radius = frameSize.height / 2
        let themeHex = config.recordingColorHex

        // During recording, hide frost and show solid accent. Otherwise frosted glass.
        let isRecording = (state == .recording)
        glassView?.isHidden = isRecording
        glassView?.frame = NSRect(origin: .zero, size: frameSize)
        glassView?.layer?.cornerRadius = radius
        glassView?.layer?.masksToBounds = true

        let tintAlpha: CGFloat
        let tintHex: String
        switch state {
        case .idle:
            tintAlpha = isHovered ? 0.72 : 0.44
            tintHex = "1e1e2e"
        case .preparing:
            tintAlpha = 0.62
            tintHex = "1e1e2e"
        case .recording:
            tintAlpha = 0.85
            tintHex = themeHex
        case .transcribing:
            tintAlpha = 0.62
            tintHex = "1e1e2e"
        }
        tintLayer?.isHidden = false
        tintLayer?.backgroundColor = NSColor.colorWith(hexString: tintHex, alpha: tintAlpha).cgColor
        applyTintLayerGeometry(size: frameSize, radius: radius)

        let iconSize = NSSize(width: 18, height: 18)

        switch state {
        case .idle:
            if config.indicatorHoverStyle == .shortcutPill {
                layoutShortcutPillIdle(frameSize: frameSize, config: config)
                return
            }
            idleShortcutPillView?.isHidden = true
            idleIconBackgroundLayer?.isHidden = true
            // Mic symbol centred (or left-aligned when hovered beside text).
            wandIconView?.isHidden = true
            quillIconView?.isHidden = true
            iconLabel?.isHidden = true
            micIconView?.isHidden = false
            if let mic = micIconView {
                mic.alphaValue = 1
                if isHovered {
                    mic.frame = NSRect(
                        x: 14,
                        y: (frameSize.height - iconSize.height) / 2,
                        width: iconSize.width,
                        height: iconSize.height
                    )
                    if let textLabel {
                        let textX: CGFloat = 42
                        let textHeight: CGFloat = 16
                        textLabel.frame = NSRect(
                            x: textX,
                            y: floor((frameSize.height - textHeight) / 2),
                            width: max(0, frameSize.width - textX - 14),
                            height: textHeight
                        )
                    }
                } else {
                    let showsHotkey = config.showHotkeyOnFloatingIndicator
                    let compactIconSize = NSSize(width: 14, height: 14)
                    let iconX = showsHotkey
                        ? CGFloat(6)
                        : floor((frameSize.width - compactIconSize.width) / 2)
                    mic.frame = NSRect(
                        x: iconX,
                        y: floor((frameSize.height - compactIconSize.height) / 2),
                        width: compactIconSize.width,
                        height: compactIconSize.height
                    )
                    if let textLabel, showsHotkey {
                        textLabel.stringValue = MenuBarIconRenderer.hotkeyCueLabel(
                            for: config.dictationHotkey
                        )
                        textLabel.font = NSFont.monospacedSystemFont(ofSize: 8, weight: .semibold)
                        textLabel.textColor = .white.withAlphaComponent(0.78)
                        textLabel.alignment = .center
                        textLabel.isHidden = false
                        textLabel.alphaValue = 1
                        textLabel.frame = NSRect(x: 21, y: 7, width: 18, height: 13)
                    } else {
                        textLabel?.isHidden = true
                        textLabel?.alphaValue = 0
                    }
                }
            }

        case .recording:
            hideShortcutPillChrome()
            // Waveform bars replace mic icon during recording.
            wandIconView?.isHidden = true
            quillIconView?.isHidden = true
            iconLabel?.isHidden = false   // keeps the ✕ cancel label
            micIconView?.isHidden = true

        case .transcribing:
            // Quill uses its feather mark plus a compact spinner while keeping the
            // dictated instruction visible. Other transcribing states keep the wand.
            micIconView?.isHidden = true
            iconLabel?.isHidden = true
            if instructionTranscriptText != nil {
                wandIconView?.isHidden = instructionTranscriptShowsProgress
                quillIconView?.isHidden = !instructionTranscriptShowsProgress
                layoutInstructionTranscript(in: frameSize, animated: false)
                return
            }
            quillIconView?.isHidden = true
            wandIconView?.isHidden = false
            if let wand = wandIconView {
                let gap: CGFloat = 6
                let horizontalPadding: CGFloat = 14
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular)
                ]
                let measuredTextW = max(
                    ceil((transcribingTitle as NSString).size(withAttributes: attrs).width),
                    ceil(textLabel?.intrinsicContentSize.width ?? 0)
                ) + 8
                let availableTextW = max(0, frameSize.width - iconSize.width - gap - (horizontalPadding * 2))
                let textW = min(measuredTextW, availableTextW)
                let totalW = iconSize.width + gap + textW
                let startX = (frameSize.width - totalW) / 2
                wand.frame = NSRect(x: startX, y: (frameSize.height - iconSize.height) / 2,
                                    width: iconSize.width, height: iconSize.height)
                // Reposition text label to sit right of the wand.
                let textH: CGFloat = 14
                textLabel?.frame = NSRect(x: startX + iconSize.width + gap,
                                          y: (frameSize.height - textH) / 2,
                                          width: textW, height: textH)
                textLabel?.isHidden = false
                textLabel?.alphaValue = 1
            }

        case .preparing:
            wandIconView?.isHidden = true
            quillIconView?.isHidden = true
            iconLabel?.isHidden = true
            micIconView?.isHidden = true
        }
    }

    private func configureTextLabelForTranscript(_ isTranscript: Bool) {
        guard let textLabel else { return }
        Self.configureTextLabel(textLabel, forTranscript: isTranscript)
    }

    private static func configureTextLabel(_ textLabel: NSTextField, forTranscript isTranscript: Bool) {
        textLabel.alignment = .left
        if isTranscript {
            textLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            textLabel.lineBreakMode = .byWordWrapping
            textLabel.maximumNumberOfLines = 0
            textLabel.usesSingleLineMode = false
            textLabel.cell?.wraps = true
            textLabel.cell?.isScrollable = false
        } else {
            textLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.maximumNumberOfLines = 1
            textLabel.usesSingleLineMode = true
            textLabel.cell?.wraps = false
            textLabel.cell?.isScrollable = false
        }
    }

    private func layoutInstructionTranscript(in size: NSSize, animated: Bool) {
        guard let textLabel else { return }
        let leadingIcon = instructionTranscriptShowsProgress ? quillIconView : wandIconView
        guard let leadingIcon else { return }
        let iconSize = NSSize(width: 18, height: 18)
        let gap: CGFloat = 8
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 12
        let textX = horizontalPadding + iconSize.width + gap
        let spinnerSize: CGFloat = instructionTranscriptShowsProgress ? 14 : 0
        let spinnerGap: CGFloat = instructionTranscriptShowsProgress ? 8 : 0
        let textWidth = max(
            40,
            size.width - textX - horizontalPadding - spinnerGap - spinnerSize
        )
        let textHeight = max(16, size.height - (verticalPadding * 2))
        let textFrame = NSRect(
            x: textX,
            y: floor((size.height - textHeight) / 2),
            width: textWidth,
            height: textHeight
        )
        let iconFrame = NSRect(
            x: horizontalPadding,
            y: floor(size.height - verticalPadding - iconSize.height),
            width: iconSize.width,
            height: iconSize.height
        )

        wandIconView?.isHidden = instructionTranscriptShowsProgress
        quillIconView?.isHidden = !instructionTranscriptShowsProgress
        leadingIcon.isHidden = false
        textLabel.isHidden = false
        if instructionTranscriptShowsProgress, let contentView {
            ensureLoadingSpinner(in: contentView)
            loadingSpinner?.frame = NSRect(
                x: size.width - horizontalPadding - spinnerSize,
                y: floor((size.height - spinnerSize) / 2),
                width: spinnerSize,
                height: spinnerSize
            )
            loadingSpinner?.isHidden = false
            loadingSpinner?.startAnimation(nil)
        } else {
            hideInstructionProgress()
        }
        if animated {
            leadingIcon.animator().alphaValue = 1
            leadingIcon.animator().frame = iconFrame
            textLabel.animator().alphaValue = 1
            textLabel.animator().frame = textFrame
        } else {
            leadingIcon.alphaValue = 1
            leadingIcon.frame = iconFrame
            textLabel.alphaValue = 1
            textLabel.frame = textFrame
        }
    }

    private func createPanel(config: AppConfig) {
        let panel = InteractiveFloatingPanel(
            contentRect: frameForState(.idle, config: config),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.leftMouseDownHandler = { [weak self] windowPoint in
            self?.meetingTranscriptPanel.handleClick(atWindowPoint: windowPoint) ?? false
        }

        let containerView = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        containerView.wantsLayer = true

        let contentView = HoverIndicatorView(frame: containerView.bounds)
        contentView.owner = self
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = panel.frame.height / 2
        contentView.layer?.masksToBounds = false

        let iconLabel = NSTextField(labelWithString: "")
        iconLabel.alignment = .center
        iconLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        contentView.addSubview(iconLabel)

        let textLabel = NSTextField(labelWithString: "")
        textLabel.alignment = .left
        textLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        Self.configureTextLabel(textLabel, forTranscript: false)
        contentView.addSubview(textLabel)

        containerView.addSubview(contentView)
        panel.contentView = containerView

        self.panel = panel
        self.containerView = containerView
        self.contentView = contentView
        self.iconLabel = iconLabel
        self.textLabel = textLabel

        setupGlassLayer(in: contentView, iconLabel: iconLabel)
    }

    private func exitComputerUseCursorMode(restoreFrame: Bool) {
        guard isComputerUseCursorMode else { return }
        isComputerUseCursorMode = false
        panel?.ignoresMouseEvents = false
        panel?.level = .floating
        if restoreFrame, let frame = computerUseCursorReturnFrame {
            panel?.setFrame(frame, display: true)
            contentView?.frame = NSRect(origin: .zero, size: frame.size)
        }
        computerUseCursorReturnFrame = nil
    }

    private static func cursorLabel(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= 24 { return trimmed }
        return String(trimmed.prefix(21)) + "..."
    }

    private static func computerUseCursorSize(label: String) -> NSSize {
        guard !label.isEmpty else {
            return NSSize(width: 36, height: 36)
        }
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        return NSSize(width: min(max(84, textWidth + 48), 190), height: 34)
    }

    private static func computerUseCursorFrame(
        forQuartzPoint point: CGPoint,
        size: NSSize,
        offsetFromTarget: Bool
    ) -> NSRect {
        let screen = NSScreen.screens.first { screen in
            let convertedY = screen.frame.maxY - point.y
            return point.x >= screen.frame.minX
                && point.x <= screen.frame.maxX
                && convertedY >= screen.frame.minY
                && convertedY <= screen.frame.maxY
        } ?? NSScreen.main

        guard let screen else {
            return NSRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        let appKitPoint = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
        let xOffset: CGFloat = offsetFromTarget ? 14 : 0
        let yOffset: CGFloat = offsetFromTarget ? 14 : 0
        let proposed = NSRect(
            x: appKitPoint.x - size.width / 2 + xOffset,
            y: appKitPoint.y - size.height / 2 - yOffset,
            width: size.width,
            height: size.height
        )
        let bounds = screen.visibleFrame.insetBy(dx: 4, dy: 4)
        return NSRect(
            x: min(max(proposed.minX, bounds.minX), bounds.maxX - size.width),
            y: min(max(proposed.minY, bounds.minY), bounds.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    private func setupGlassLayer(in contentView: HoverIndicatorView, iconLabel: NSTextField) {
        // masksToBounds clips both the glass blur and the tint layer to the pill shape.
        // The panel's compositor-level shadow is unaffected.
        contentView.layer?.masksToBounds = true

        // NSVisualEffectView — frosted blur behind the pill.
        let vev = NSVisualEffectView(frame: contentView.bounds)
        vev.autoresizingMask = [.width, .height]
        vev.material = .hudWindow
        vev.blendingMode = .behindWindow
        vev.state = .active
        // Force dark appearance so the glass always looks dark regardless of
        // what's behind the pill (light windows, bright desktops, etc.).
        vev.appearance = NSAppearance(named: .darkAqua)
        vev.isHidden = true
        contentView.addSubview(vev, positioned: .below, relativeTo: iconLabel)
        glassView = vev

        // Dark Catppuccin Mocha tint over the blur — gives the pill a defined
        // dark glass presence rather than showing everything underneath.
        let tint = CALayer()
        tint.backgroundColor = NSColor.colorWith(hex: 0x1e1e2e, alpha: 0.44).cgColor
        tint.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        tint.masksToBounds = false
        tint.cornerCurve = .continuous
        tint.isHidden = true
        contentView.layer?.insertSublayer(tint, at: 0)
        tintLayer = tint

        // Shortcut-pill hover style: adjacent label pill + mic capsule/handle.
        let shortcutPill = IdleShortcutPillView(frame: .zero)
        shortcutPill.wantsLayer = true
        shortcutPill.isHidden = true
        contentView.addSubview(shortcutPill)
        idleShortcutPillView = shortcutPill

        let iconBackground = CALayer()
        iconBackground.backgroundColor = NSColor.colorWith(hex: 0x111111, alpha: 1).cgColor
        iconBackground.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        iconBackground.borderWidth = 1
        iconBackground.cornerCurve = .circular
        iconBackground.isHidden = true
        contentView.layer?.insertSublayer(iconBackground, above: tint)
        idleIconBackgroundLayer = iconBackground

        // Idle icon — uses the user's selected menu bar icon from config.
        // Falls back to waveform.badge.microphone if the configured icon can't be loaded.
        let config = configStore.load()
        let fallbackImage = NSImage(systemSymbolName: "waveform.badge.microphone", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) ?? NSImage()
        let idleImage = MenuBarIconRenderer.make(choice: config.menuBarIcon) ?? fallbackImage
        idleImage.isTemplate = true
        let micView = NSImageView(image: idleImage)
        micView.contentTintColor = .white
        micView.imageScaling = .scaleProportionallyDown
        micView.isHidden = true
        contentView.addSubview(micView)
        micIconView = micView

        // wand.and.sparkles — transcribing (animated).
        let wandConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let wandImage = NSImage(systemSymbolName: "wand.and.sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(wandConfig)
        let wandView = NSImageView(image: wandImage ?? NSImage())
        wandView.contentTintColor = .white
        wandView.imageScaling = .scaleProportionallyDown
        wandView.isHidden = true
        contentView.addSubview(wandView)
        wandIconView = wandView

        let quillView = NSImageView(image: QuillIcon.image())
        quillView.contentTintColor = .white
        quillView.imageScaling = .scaleProportionallyDown
        quillView.isHidden = true
        contentView.addSubview(quillView)
        quillIconView = quillView

    }

    private func applyTintLayerGeometry(size: NSSize, radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer?.frame = CGRect(origin: .zero, size: size)
        tintLayer?.cornerRadius = radius
        tintLayer?.cornerCurve = .continuous
        CATransaction.commit()
    }

    static func defaultIndicatorCenter(in visibleFrame: NSRect, idleSize: NSSize = NSSize(width: 44, height: 28)) -> CGPoint {
        anchorCenter(.midTrailing, in: visibleFrame, size: idleSize)
    }

    static func idlePositionCenter(
        for frame: NSRect,
        collapsedSize: NSSize = NSSize(width: 44, height: 28)
    ) -> CGPoint {
        CGPoint(x: frame.minX + collapsedSize.width / 2, y: frame.midY)
    }

    static func positionCenter(
        for frame: NSRect,
        preservesCollapsedLeftEdge: Bool,
        collapsedSize: NSSize = NSSize(width: 44, height: 28)
    ) -> CGPoint {
        guard preservesCollapsedLeftEdge else {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        return idlePositionCenter(for: frame, collapsedSize: collapsedSize)
    }

    static func customIdleFrame(
        positionCenter: CGPoint,
        size: NSSize,
        in visibleFrame: NSRect,
        collapsedSize: NSSize = NSSize(width: 44, height: 28)
    ) -> NSRect {
        let leftEdge = positionCenter.x - collapsedSize.width / 2
        let x = min(max(leftEdge, visibleFrame.minX), visibleFrame.maxX - size.width)
        let y = min(max(positionCenter.y - size.height / 2, visibleFrame.minY), visibleFrame.maxY - size.height)
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func anchorCenter(_ anchor: IndicatorAnchor, in visibleFrame: NSRect, size: NSSize) -> CGPoint {
        let inset: CGFloat = 8
        let leadingX = visibleFrame.minX + size.width / 2 + inset
        let centerX = visibleFrame.midX
        let trailingX = visibleFrame.maxX - size.width / 2 - inset
        let topY = visibleFrame.maxY - size.height / 2 - inset
        let midY = visibleFrame.midY
        let bottomY = visibleFrame.minY + size.height / 2 + inset

        switch anchor {
        case .topLeading:
            return CGPoint(x: leadingX, y: topY)
        case .topCenter:
            return CGPoint(x: centerX, y: topY)
        case .topTrailing:
            return CGPoint(x: trailingX, y: topY)
        case .midLeading:
            return CGPoint(x: leadingX, y: midY)
        case .midTrailing:
            return CGPoint(x: trailingX, y: midY)
        case .bottomLeading:
            return CGPoint(x: leadingX, y: bottomY)
        case .bottomCenter:
            return CGPoint(x: centerX, y: bottomY)
        case .bottomTrailing:
            return CGPoint(x: trailingX, y: bottomY)
        case .custom:
            return defaultIndicatorCenter(in: visibleFrame, idleSize: size)
        }
    }

    static func isUsableIndicatorCenter(
        _ center: CGPoint,
        in visibleFrame: NSRect,
        size: NSSize
    ) -> Bool {
        let allowedRect = visibleFrame.insetBy(dx: size.width / 2, dy: size.height / 2)
        return allowedRect.contains(center)
    }

    static func visibleFrameForCustomIndicator(
        customPositionCenter: CGPoint?,
        indicatorFrame: NSRect?,
        savedPositionCenter: CGPoint?,
        availableVisibleFrames: [NSRect],
        fallback: NSRect
    ) -> NSRect {
        if let customPositionCenter,
           let matchingFrame = availableVisibleFrames.first(where: { $0.contains(customPositionCenter) }) {
            return matchingFrame
        }

        if let indicatorFrame, !indicatorFrame.isEmpty {
            let matchingFrame = availableVisibleFrames
                .compactMap { visibleFrame -> (frame: NSRect, overlap: CGFloat)? in
                    let intersection = visibleFrame.intersection(indicatorFrame)
                    guard !intersection.isNull, !intersection.isEmpty else { return nil }
                    return (visibleFrame, intersection.width * intersection.height)
                }
                .max(by: { $0.overlap < $1.overlap })?
                .frame
            if let matchingFrame {
                return matchingFrame
            }
        }

        if let savedPositionCenter,
           let matchingFrame = availableVisibleFrames.first(where: { $0.contains(savedPositionCenter) }) {
            return matchingFrame
        }

        return fallback
    }

    private func frameForState(
        _ state: DictationState,
        config: AppConfig,
        customPositionCenter: CGPoint? = nil
    ) -> NSRect {
        guard let mainVisibleFrame = NSScreen.main?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: 64, height: 28)
        }
        let screen: NSRect
        if config.indicatorAnchor == .custom {
            screen = Self.visibleFrameForCustomIndicator(
                customPositionCenter: customPositionCenter,
                indicatorFrame: indicatorScreenFrame,
                savedPositionCenter: config.indicatorOrigin.map { CGPoint(x: $0.x, y: $0.y) },
                availableVisibleFrames: NSScreen.screens.map(\.visibleFrame),
                fallback: mainVisibleFrame
            )
        } else {
            screen = mainVisibleFrame
        }
        let size: NSSize
        switch state {
        case .idle:
            if config.indicatorHoverStyle == .shortcutPill {
                // Fixed canvas sized to the unified hover pill: the window never
                // resizes on hover, only child visibility changes.
                let (pill, _, _, _) = shortcutPillHoverFrame(
                    placement: idleHoverPlacement(for: config.indicatorAnchor),
                    frameSize: .zero,
                    config: config
                )
                size = NSSize(width: pill.width + 4, height: 40)
            } else {
                size = isHovered
                    ? Self.idleHoverPillSize(hotkeyLabel: config.dictationHotkey.label, screenWidth: screen.width)
                    : NSSize(width: 44, height: 28)
            }
        case .preparing: size = NSSize(width: 76, height: 22)
        case .recording: size = NSSize(width: 76, height: 22)
        case .transcribing:
            hideShortcutPillChrome()
            if let transcript = instructionTranscriptText {
                size = Self.instructionTranscriptPillSize(
                    transcript: transcript,
                    screen: screen,
                    showsProgress: instructionTranscriptShowsProgress
                )
            } else {
                size = Self.transcribingPillSize(title: transcribingTitle, screenWidth: screen.width)
            }
        }

        // Idle hover expansion uses the saved collapsed position as its anchor,
        // so the left edge stays fixed instead of resizing around the midpoint.
        // The expanded pill remains draggable; savePosition converts its frame
        // back to the canonical collapsed center.
        if state == .idle, config.indicatorAnchor == .custom {
            let positionCenter: CGPoint
            if let saved = config.indicatorOrigin {
                positionCenter = CGPoint(x: saved.x, y: saved.y)
            } else if let currentFrame = indicatorScreenFrame, currentFrame.width > 0 {
                positionCenter = Self.idlePositionCenter(for: currentFrame)
            } else {
                positionCenter = Self.defaultIndicatorCenter(in: screen)
            }
            return Self.customIdleFrame(positionCenter: positionCenter, size: size, in: screen)
        }

        // Non-idle custom state transitions continue to resize around the
        // current on-screen center. Preset anchors always resolve from config.
        let center: CGPoint
        if config.indicatorAnchor == .custom, let customPositionCenter {
            // When dictation starts from the left-anchored hover pill, keep the
            // compact icon position rather than jumping to the hover midpoint.
            center = customPositionCenter
        } else if config.indicatorAnchor == .custom,
           let currentFrame = indicatorScreenFrame,
           currentFrame.width > 0 {
            center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        } else {
            switch config.indicatorAnchor {
            case .custom:
                if let saved = config.indicatorOrigin,
                   Self.isUsableIndicatorCenter(CGPoint(x: saved.x, y: saved.y), in: screen, size: size) {
                    center = CGPoint(x: saved.x, y: saved.y)
                } else {
                    center = Self.defaultIndicatorCenter(in: screen, idleSize: size)
                }
            default:
                center = Self.anchorCenter(config.indicatorAnchor, in: screen, size: size)
            }
        }

        let x = min(max(center.x - size.width / 2, screen.minX), screen.maxX - size.width)
        let y = min(max(center.y - size.height / 2, screen.minY), screen.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }


    // MARK: - Shortcut-pill hover (IndicatorHoverStyle.shortcutPill)

    private enum IdleHoverPlacement {
        case above, below, leading, trailing
    }

    private func idleHoverPlacement(for anchor: IndicatorAnchor) -> IdleHoverPlacement {
        switch anchor {
        case .topLeading, .topCenter, .topTrailing: return .below
        case .midLeading: return .trailing
        case .midTrailing: return .leading
        case .bottomLeading, .bottomCenter, .bottomTrailing, .custom: return .above
        }
    }

    private func idleRestingHandleFrame(
        placement: IdleHoverPlacement,
        frameSize: NSSize
    ) -> CGRect {
        let inset: CGFloat = 2
        switch placement {
        case .above: return CGRect(x: (frameSize.width - 30) / 2, y: inset, width: 30, height: 8)
        case .below: return CGRect(x: (frameSize.width - 30) / 2, y: frameSize.height - inset - 8, width: 30, height: 8)
        case .leading: return CGRect(x: frameSize.width - inset - 8, y: (frameSize.height - 30) / 2, width: 8, height: 30)
        case .trailing: return CGRect(x: inset, y: (frameSize.height - 30) / 2, width: 8, height: 30)
        }
    }

    private func animateIdleHoverPop() {
        let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounce.values = [0, 2, -0.5, 0]
        bounce.keyTimes = [0, 0.45, 0.75, 1]
        bounce.duration = 0.16
        bounce.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        idleIconBackgroundLayer?.add(bounce, forKey: "idle-hover-bounce")
        micIconView?.layer?.add(bounce, forKey: "idle-hover-bounce")
    }

    private func styleForState(_ state: DictationState, config: AppConfig) -> (background: NSColor, border: NSColor, icon: String, title: String, iconColor: NSColor, textColor: NSColor, alpha: CGFloat) {
        switch state {
        case .idle:
            return (
                .clear,
                .colorWith(hex: 0xFFFFFF, alpha: isHovered ? 0.14 : 0.22),
                "",
                isHovered ? "Hold \(config.dictationHotkey.label) to dictate" : "",
                .colorWith(hex: 0xFFFFFF, alpha: 0.75),
                .colorWith(hex: 0xFFFFFF, alpha: 0.75),
                isHovered ? 1.0 : 0.90
            )
        case .preparing:
            return (.clear, .colorWith(hex: 0xFFFFFF, alpha: 0.16), "", "", .white, .white, 1.0)
        case .recording:
            return (
                .clear, .colorWith(hex: 0xFFFFFF, alpha: 0.16),
                isMeetingRecording ? "⏹" : "",
                isMeetingRecording ? "" : "",
                .white, .white, 1.0
            )
        case .transcribing:
            return (
                .clear, .colorWith(hex: 0xFFFFFF, alpha: 0.16),
                "", transcribingTitle,
                .white, .colorWith(hex: 0xFFFFFF, alpha: 0.82), 1.0
            )
        }
    }

    private func transitionDuration(from oldState: DictationState, to newState: DictationState, wasHovered: Bool, isHovered: Bool) -> TimeInterval {
        if newState == .preparing {
            return 0
        }
        if oldState == .preparing, newState == .recording {
            return 0
        }
        if oldState == .idle, newState == .idle, wasHovered != isHovered {
            return isHovered ? 0.24 : 0.2
        }
        if oldState == .idle || newState == .idle {
            return 0.18
        }
        return 0.16
    }

    private func layoutLabels(iconLabel: NSTextField, textLabel: NSTextField, in size: NSSize, hasTitle: Bool, animated: Bool) {
        if !hasTitle {
            let iconSize = iconLabel.attributedStringValue.size()
            let iconWidth = max(26, ceil(iconSize.width) + 4)
            let iconHeight = max(18, ceil(iconSize.height))
            let iconFrame = NSRect(
                x: (size.width - iconWidth) / 2,
                y: (size.height - iconHeight) / 2,
                width: iconWidth,
                height: iconHeight
            )
            if animated {
                iconLabel.animator().frame = iconFrame
                textLabel.animator().alphaValue = 0
                textLabel.animator().frame = .zero
            } else {
                iconLabel.frame = iconFrame
                textLabel.alphaValue = 0
                textLabel.frame = .zero
            }
            return
        }

        let iconSize = iconLabel.attributedStringValue.size()
        let textSize = textLabel.attributedStringValue.size()
        let hasIcon = !iconLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let gap: CGFloat = hasIcon ? 4 : 0
        let horizontalPadding: CGFloat = 12

        let iconWidth = hasIcon ? max(24, ceil(iconSize.width) + 2) : 0
        let iconHeight = max(18, ceil(iconSize.height))
        let availableTextWidth = max(0, size.width - (horizontalPadding * 2) - iconWidth - gap)
        let textWidth = min(ceil(textSize.width) + 2, availableTextWidth)
        let textHeight = max(16, ceil(textSize.height))

        let totalWidth = iconWidth + gap + textWidth
        let originX = max((size.width - totalWidth) / 2, horizontalPadding)

        let iconFrame = NSRect(
            x: originX,
            y: (size.height - iconHeight) / 2,
            width: iconWidth,
            height: iconHeight
        )
        let textFrame = NSRect(
            x: originX + iconWidth + gap,
            y: (size.height - textHeight) / 2,
            width: textWidth,
            height: textHeight
        )
        if animated {
            iconLabel.animator().alphaValue = hasIcon ? 1 : 0
            iconLabel.animator().frame = iconFrame
            textLabel.animator().alphaValue = 1
            textLabel.animator().frame = textFrame
        } else {
            iconLabel.alphaValue = hasIcon ? 1 : 0
            iconLabel.frame = iconFrame
            textLabel.alphaValue = 1
            textLabel.frame = textFrame
        }
    }

    static func transcribingPillSizeForTesting(title: String, screenWidth: CGFloat) -> NSSize {
        transcribingPillSize(title: title, screenWidth: screenWidth)
    }

    static func idleHoverPillSize(hotkeyLabel: String, screenWidth: CGFloat) -> NSSize {
        let title = "Hold \(hotkeyLabel) to dictate"
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let preferredWidth = 42 + textWidth + 22
        let maxWidth = max(CGFloat(180), screenWidth - 32)
        return NSSize(width: min(max(220, preferredWidth), maxWidth), height: 36)
    }

    static func computerUseTranscriptPillSizeForTesting(
        transcript: String,
        screenWidth: CGFloat,
        screenHeight: CGFloat = 900
    ) -> NSSize {
        instructionTranscriptPillSize(
            transcript: transcript,
            screen: NSRect(x: 0, y: 0, width: screenWidth, height: screenHeight),
            showsProgress: false
        )
    }

    static func quillInstructionPillSizeForTesting(
        transcript: String,
        screenWidth: CGFloat,
        screenHeight: CGFloat = 900
    ) -> NSSize {
        instructionTranscriptPillSize(
            transcript: transcript,
            screen: NSRect(x: 0, y: 0, width: screenWidth, height: screenHeight),
            showsProgress: true
        )
    }

    static func quillInstructionTextHeightsForTesting(
        transcript: String,
        screenWidth: CGFloat,
        screenHeight: CGFloat = 900
    ) -> (allocated: CGFloat, required: CGFloat) {
        let normalized = normalizedInstructionTranscript(transcript)
        let size = quillInstructionPillSizeForTesting(
            transcript: normalized,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )
        let textWidth = max(40, size.width - 80)
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return (
            allocated: max(16, size.height - 24),
            required: transcriptTextFieldHeight(normalized, font: font, width: textWidth)
        )
    }

    private static func transcribingPillSize(title: String, screenWidth: CGFloat) -> NSSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let iconWidth: CGFloat = 18
        let gap: CGFloat = 6
        let horizontalPadding: CGFloat = 14
        let textWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 8
        let preferredWidth = horizontalPadding + iconWidth + gap + textWidth + horizontalPadding
        let minWidth = min(CGFloat(190), max(120, screenWidth - 32))
        let maxWidth = max(minWidth, min(420, screenWidth - 32))
        return NSSize(width: min(max(preferredWidth, minWidth), maxWidth), height: 32)
    }

    private static func instructionTranscriptPillSize(
        transcript: String,
        screen: NSRect,
        showsProgress: Bool
    ) -> NSSize {
        let normalized = normalizedInstructionTranscript(transcript)
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let iconWidth: CGFloat = 18
        let gap: CGFloat = 8
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 12
        let progressWidth: CGFloat = showsProgress ? 22 : 0
        let chromeWidth = horizontalPadding + iconWidth + gap + progressWidth + horizontalPadding
        let minWidth = min(CGFloat(280), max(160, screen.width - 48))
        let maxWidth = max(minWidth, min(720, screen.width - 48))
        // NSTextFieldCell reserves a little more horizontal drawing room than
        // NSString reports. Account for it in Quill before deciding that a
        // prompt fits on one line; otherwise the cell wraps the final word even
        // when the pill still has room available.
        let textFieldInsetAllowance: CGFloat = showsProgress ? 6 : 2
        let singleLineTextWidth = ceil(
            (normalized as NSString).size(withAttributes: [.font: font]).width
        ) + textFieldInsetAllowance
        let preferredWidth = min(maxWidth, max(minWidth, chromeWidth + singleLineTextWidth))
        let textWidth = max(40, preferredWidth - chromeWidth)
        // Quill keeps the spoken instruction on screen while the model works.
        // Measure that text through the same AppKit cell used to render it: the
        // NSString bounding box can disagree with NSTextField at word-wrap
        // boundaries and leave the final rendered line outside the label frame.
        // Keep CUA on its existing sizing path until its rendering is addressed
        // independently.
        let textHeight = showsProgress
            ? transcriptTextFieldHeight(normalized, font: font, width: textWidth)
            : transcriptTextHeight(normalized, font: font, width: textWidth)
        let maxHeight = max(CGFloat(56), screen.height - 48)
        let preferredHeight = max(CGFloat(44), ceil(textHeight) + (verticalPadding * 2))
        return NSSize(width: preferredWidth, height: min(preferredHeight, maxHeight))
    }

    private static func transcriptTextHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let bounding = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return max(16, ceil(bounding.height))
    }

    private static func transcriptTextFieldHeight(
        _ text: String,
        font: NSFont,
        width: CGFloat
    ) -> CGFloat {
        let cell = NSTextFieldCell(textCell: text)
        cell.font = font
        cell.lineBreakMode = .byWordWrapping
        cell.usesSingleLineMode = false
        cell.wraps = true
        cell.isScrollable = false
        let size = cell.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000)
        )
        return max(16, ceil(size.height))
    }

    private static func normalizedInstructionTranscript(_ transcript: String) -> String {
        transcript
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func pointerIsInsidePanel() -> Bool {
        indicatorScreenFrame?.contains(NSEvent.mouseLocation) == true
    }
}

private extension NSColor {
    static func colorWith(hex: Int, alpha: CGFloat) -> NSColor {
        NSColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    static func colorWith(hexString: String, alpha: CGFloat = 1.0) -> NSColor {
        var h = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        h = h.hasPrefix("#") ? String(h.dropFirst()) : h
        guard h.count == 6, let value = UInt64(h, radix: 16) else {
            return .colorWith(hex: 0x1e1e2e, alpha: alpha)
        }
        return .colorWith(hex: Int(value), alpha: alpha)
    }
}
