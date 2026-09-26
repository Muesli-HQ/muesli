import AppKit
import SwiftUI

enum NotchOutcome: Equatable {
    case success, needsInput, failure

    var color: NSColor {
        switch self {
        case .success: return .systemGreen
        case .needsInput: return .systemYellow
        case .failure: return .systemRed
        }
    }
    var title: String {
        switch self {
        case .success: return "Done"
        case .needsInput: return "Needs input"
        case .failure: return "Failed"
        }
    }
    var duration: TimeInterval? {
        switch self {
        case .success: return 2
        case .needsInput: return nil
        case .failure: return 5
        }
    }

    static func quillFailure(_ error: Error) -> Self {
        guard let error = error as? QuilTransformationError else { return .failure }
        switch error {
        case .noTextTarget, .accessibilityPermissionRequired, .selectionTooLong,
             .emptyInstruction, .selectionChanged, .unsupportedModel, .modelUnavailable:
            return .needsInput
        case .emptyResponse, .responseTooLong, .nonReplacementResponse:
            return .failure
        }
    }

    static func computerUse(_ status: ComputerUsePlannerRuntimeResult.Status) -> Self? {
        switch status {
        case .done: return .success
        case .needsConfirmation: return .needsInput
        case .failed, .timedOut: return .failure
        case .cancelled: return nil
        }
    }
}

/// Visual noise gate only; never changes captured audio or transcription.
enum NotchWaveformLevel {
    static func amplitude(decibels: Float) -> CGFloat {
        guard decibels.isFinite, decibels > -50 else { return 0 }
        let normalized = CGFloat(min(1, (decibels + 50) / 30))
        return normalized * normalized
    }
}

struct NotchActivityVisibility {
    private(set) var active = false
    private(set) var dismissAt: Date?

    mutating func update(active: Bool, now: Date) -> Bool {
        let wasActive = self.active
        if active {
            dismissAt = nil
        } else if self.active {
            // Defer only to the next UI turn so the synchronous successful-paste
            // callback can request its completion pulse. No idle grace period.
            dismissAt = now
        }
        self.active = active
        return active || wasActive || (dismissAt.map { now < $0 } ?? false)
    }

    mutating func complete(now: Date) {
        guard !active else { return }
        dismissAt = now.addingTimeInterval(NotchCompletionTiming.duration)
    }
}

/// Screen coordinates come from AppKit, in points, including nonzero display origins.
struct NotchIndicatorGeometry: Equatable {
    let cutout: CGRect
    let wingWidth: CGFloat

    static func resolve(screen: CGRect, topInset: CGFloat, left: CGRect?, right: CGRect?) -> Self? {
        guard topInset.isFinite, topInset > 0, topInset < screen.height / 4,
              let left, let right,
              left.width > 0, right.width > 0,
              left.maxX < right.minX,
              left.minX >= screen.minX, right.maxX <= screen.maxX,
              abs(left.maxY - screen.maxY) < 1,
              abs(right.maxY - screen.maxY) < 1 else { return nil }
        let width = right.minX - left.maxX
        guard width < screen.width / 2 else { return nil }
        let wing = min(110, left.width, right.width)
        guard wing >= 80 else { return nil }
        return Self(cutout: CGRect(x: left.maxX, y: screen.maxY - topInset,
                                  width: width, height: topInset), wingWidth: wing)
    }

    func frame() -> CGRect {
        let height = cutout.height
        return CGRect(x: cutout.minX - wingWidth, y: cutout.maxY - height,
                      width: cutout.width + 2 * wingWidth, height: height)
    }

    func instructionFrame(in screen: CGRect, requiresReview: Bool = false) -> CGRect {
        let width = min(440, screen.width)
        let height: CGFloat = requiresReview ? 180 : 115
        return CGRect(x: min(max(cutout.midX - width / 2, screen.minX), screen.maxX - width),
                      y: cutout.minY - height, width: width, height: height)
    }
}

@MainActor
private final class NotchIndicatorPanel: NSPanel {
    var acceptsKeyboardInput = false
    override var canBecomeKey: Bool { acceptsKeyboardInput }
    override var canBecomeMain: Bool { false }
}

/// Owns only presentation; recording and meeting state remain in the existing controller.
@MainActor
final class NotchIndicatorController {
    private var panel: NSPanel?
    private var geometry: NotchIndicatorGeometry?
    private var title = "Ready"
    private var detail = ""
    private var recording = false
    private var paused = false
    private var meeting = false
    private var handsFree = false
    private var activationID = 0
    private var completionID = 0
    private var dismissActivity: DispatchWorkItem?
    private var visibility = NotchActivityVisibility()
    private var icon = NSImage()
    private var accent = RecordingIndicatorPalette.accent(hex: "")
    private var instructionPanel: NSPanel?
    private var question: ComputerUseQuestionSession?
    private var instruction: String?
    private var instructionStatus = ""
    private var appName = ""
    private var appIcon: NSImage?
    private var expanded = true
    private var screenBounds = CGRect.zero
    private var requiresReview = false
    private(set) var outcome: NotchOutcome?
    private let resolveGeometry: (NSScreen) -> NotchIndicatorGeometry?

    init(resolveGeometry: @escaping (NSScreen) -> NotchIndicatorGeometry? = NotchIndicatorController.geometry) {
        self.resolveGeometry = resolveGeometry
    }
    var onReview: (() -> Void)?
    var onOpenHome: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleMeetingPause: (() -> Void)?
    var onStopMeeting: (() -> Void)?
    var onStopRecording: (() -> Void)?
    var powerProvider: (() -> Float)?

    var isVisible: Bool { panel?.isVisible == true }
    var screenFrame: CGRect? { isVisible ? panel?.frame : nil }

    static func geometry(for screen: NSScreen) -> NotchIndicatorGeometry? {
        // These APIs predate Muesli's macOS 14.2 deployment target. Hardware
        // capability is still checked for every display; Apple Silicon is not enough.
        NotchIndicatorGeometry.resolve(screen: screen.frame, topInset: screen.safeAreaInsets.top,
                                       left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
    }

    @discardableResult
    func show(on screen: NSScreen, title: String, detail: String,
              recording: Bool, paused: Bool, meeting: Bool, handsFree: Bool, active: Bool, icon: NSImage,
              accent: NSColor, instruction: String? = nil, instructionStatus: String = "",
              appName: String = "", appIcon: NSImage? = nil, question: ComputerUseQuestionSession? = nil) -> Bool {
        guard let geometry = resolveGeometry(screen) else { hide(); return false }
        requiresReview = false
        outcome = nil
        dismissActivity?.cancel()
        dismissActivity = nil
        let now = Date()
        if active && !visibility.active {
            expanded = true
            activationID += 1
            completionID = 0
        }
        guard visibility.update(active: active, now: now) else {
            hide()
            // Supported but intentionally hidden: do not show the floating fallback.
            return true
        }
        self.icon = icon
        if self.question?.id != question?.id { expanded = true }
        self.question = question
        self.instruction = instruction
        self.instructionStatus = instructionStatus
        self.appName = appName
        self.appIcon = appIcon
        self.screenBounds = screen.visibleFrame
        self.accent = accent
        self.geometry = geometry
        self.title = title
        self.detail = detail
        self.recording = recording
        self.paused = paused
        self.meeting = meeting
        self.handsFree = handsFree
        if panel == nil {
            let panel = NotchIndicatorPanel(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            self.panel = panel
        }
        render()
        panel?.orderFrontRegardless()
        scheduleDismissal()
        return true
    }

    private func scheduleDismissal() {
        dismissActivity?.cancel()
        dismissActivity = nil
        if let deadline = visibility.dismissAt {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.visibility.active,
                      self.visibility.dismissAt == deadline else { return }
                self.hide()
            }
            dismissActivity = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: work)
        }
    }

    func hide() {
        outcome = nil
        requiresReview = false
        instructionPanel?.orderOut(nil)
        instructionPanel?.contentView = nil
        instruction = nil
        question = nil
        dismissActivity?.cancel()
        dismissActivity = nil
        visibility = NotchActivityVisibility()
        completionID = 0
        panel?.orderOut(nil)
        // Releasing the hosted view cancels waveform/activation tasks while hidden.
        panel?.contentView = nil
    }

    /// Geometry-only update: retain the result, disclosure state, callbacks and
    /// original dismissal task. A detached built-in display must not lose a
    /// pending review; show that existing result below the external menu bar.
    @discardableResult
    func refreshOutcomePlacement(on screen: NSScreen?) -> Bool {
        guard outcome != nil else { return false }
        guard let screen else { return true }
        screenBounds = screen.visibleFrame
        geometry = resolveGeometry(screen) ?? NotchIndicatorGeometry(
            cutout: CGRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY - 32,
                           width: 0, height: 32), wingWidth: 110)
        render()
        panel?.orderFrontRegardless()
        return true
    }

    func showCompletion() {
        guard outcome == nil else { return }
        guard isVisible, !visibility.active else { return }
        visibility.complete(now: Date())
        completionID += 1
        render()
        scheduleDismissal()
    }

    @discardableResult
    func showOutcome(on screen: NSScreen, outcome: NotchOutcome, instruction: String?, message: String, icon: NSImage) -> Bool {
        guard show(on: screen, title: outcome.title, detail: message, recording: false, paused: false,
                   meeting: false, handsFree: false, active: true,
                   icon: icon, accent: outcome.color,
                   instruction: outcome == .success ? nil : (instruction ?? message), instructionStatus: message) else { return false }
        self.outcome = outcome
        requiresReview = outcome == .needsInput
        expanded = true
        render()
        if let duration = outcome.duration {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            dismissActivity = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
        return true
    }

    private func render() {
        guard let geometry, let panel else { return }
        let frame = geometry.frame()
        panel.setFrame(frame, display: true)
        let view = NotchIndicatorView(geometry: geometry, active: visibility.active, activationID: activationID,
            completionID: completionID, handsFree: handsFree, accent: accent,
            title: title, detail: detail, recording: recording, paused: paused, meeting: meeting, icon: icon,
            onCancel: { [weak self] in self?.cancelOrDismiss() },
            onToggleMeetingPause: { [weak self] in self?.onToggleMeetingPause?() },
            onStopMeeting: { [weak self] in self?.onStopMeeting?() },
            onStopRecording: { [weak self] in self?.onStopRecording?() },
            onOpenHome: { [weak self] in self?.onOpenHome?() },
            hasInstruction: instruction != nil || question != nil, expanded: expanded, requiresReview: requiresReview, outcome: outcome,
            onToggleInstruction: { [weak self] in
                guard let self else { return }
                self.expanded.toggle()
                self.render()
            },
            power: { [weak self] in self?.powerProvider?() ?? -160 })
        if let hosting = panel.contentView as? NSHostingView<NotchIndicatorView> {
            hosting.rootView = view
        } else {
            panel.contentView = NSHostingView(rootView: view)
        }
        renderInstruction()
    }

    private func renderInstruction() {
        guard let geometry, expanded, visibility.active,
              question != nil || instruction?.isEmpty == false else {
            instructionPanel?.orderOut(nil)
            instructionPanel?.contentView = nil
            return
        }
        if instructionPanel == nil {
            let panel = NotchIndicatorPanel(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            instructionPanel = panel
        }
        (instructionPanel as? NotchIndicatorPanel)?.acceptsKeyboardInput = question != nil
        if let question {
            let size = ComputerUseQuestionLayout.size(in: screenBounds)
            let frame = CGRect(x: min(max(geometry.cutout.midX - size.width / 2, screenBounds.minX), screenBounds.maxX - size.width),
                y: max(screenBounds.minY, geometry.cutout.minY - size.height), width: size.width, height: size.height)
            let view = ComputerUseQuestionView(session: question, notch: true,
                onCollapse: { [weak self] in self?.expanded = false; self?.render() }, accent: Color(nsColor: accent))
            if let hosting = instructionPanel?.contentView as? NSHostingView<ComputerUseQuestionView> {
                hosting.rootView = view
            } else { instructionPanel?.contentView = NSHostingView(rootView: view) }
            instructionPanel?.setFrame(frame, display: true)
            instructionPanel?.orderFrontRegardless()
            return
        }
        if instructionPanel?.isKeyWindow == true { instructionPanel?.resignKey() }
        let frame = geometry.instructionFrame(in: screenBounds, requiresReview: requiresReview)
        let view = NotchLiveInstructionView(instruction: instruction ?? "", status: instructionStatus,
            appName: appName, appIcon: appIcon, accent: Color(nsColor: accent),
            requiresReview: requiresReview, outcome: outcome,
            onReview: { [weak self] in self?.onReview?(); self?.hide() },
            onCollapse: { [weak self] in self?.expanded = false; self?.render() },
            onCancel: { [weak self] in self?.cancelOrDismiss() })
        if let hosting = instructionPanel?.contentView as? NSHostingView<NotchLiveInstructionView> {
            hosting.rootView = view
        } else { instructionPanel?.contentView = NSHostingView(rootView: view) }
        instructionPanel?.setFrame(frame, display: true)
        instructionPanel?.orderFrontRegardless()
    }

    private func cancelOrDismiss() {
        if outcome != nil { hide() } else { onCancel?() }
    }
}

struct NotchLiveInstructionView: View {
    let instruction: String
    let status: String
    let appName: String
    let appIcon: NSImage?
    let accent: Color
    var requiresReview = false
    var outcome: NotchOutcome? = nil
    var onReview: () -> Void = {}
    let onCollapse: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let appIcon { Image(nsImage: appIcon).resizable().frame(width: 18, height: 18) }
                Text(appName.isEmpty ? "Instruction" : appName).font(.caption).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Button(action: onCollapse) { Image(systemName: "chevron.up") }
                    .accessibilityLabel("Collapse instruction")
            }
            ScrollView {
                Text(instruction).font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if outcome != nil || requiresReview {
                    Image(systemName: "exclamationmark.bubble").foregroundStyle(accent)
                } else { ProgressView().controlSize(.small).tint(accent) }
                Text(status).font(.caption).lineLimit(2)
                Spacer()
                Button(outcome != nil || requiresReview ? "Dismiss" : "Cancel", action: onCancel).buttonStyle(.bordered)
            }
            if requiresReview {
                Text("Your attention is needed. Review the details in Muesli.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.65))
                Button("Review in app", action: onReview).buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.055))
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
        .overlay {
            UnevenRoundedRectangle(bottomLeadingRadius: 18, bottomTrailingRadius: 18)
                .strokeBorder(accent.opacity(0.5), lineWidth: 0.75).allowsHitTesting(false)
        }
        .foregroundStyle(.white).tint(accent).preferredColorScheme(.dark)
    }
}

private struct NotchIndicatorView: View {
    let geometry: NotchIndicatorGeometry
    let active: Bool
    let activationID: Int
    let completionID: Int
    let handsFree: Bool
    let accent: NSColor
    let title: String
    let detail: String
    let recording: Bool
    let paused: Bool
    let meeting: Bool
    let icon: NSImage
    let onCancel: () -> Void
    let onToggleMeetingPause: () -> Void
    let onStopMeeting: () -> Void
    let onStopRecording: () -> Void
    let onOpenHome: () -> Void
    let hasInstruction: Bool
    let expanded: Bool
    let requiresReview: Bool
    let outcome: NotchOutcome?
    let onToggleInstruction: () -> Void
    let power: () -> Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var edgeIntensity = 0.18

    private var silhouette: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if active && meeting {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Discard meeting")
                    .help("Discard meeting…")
                }
                Button(action: onOpenHome) {
                    HStack(spacing: 5) {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 16, height: 16)
                        Text(title).font(.system(size: 10, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.cutout.height)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("\(title). Open Muesli home")
                .help("Open Muesli home")
            }
            .padding(.horizontal, 7)
            .frame(width: geometry.wingWidth)

            // The physical camera region must stay black and noninteractive.
            Color.black.frame(width: geometry.cutout.width).allowsHitTesting(false)
                .accessibilityHidden(true)

            HStack(spacing: meeting ? 4 : 7) {
                if hasInstruction {
                    Button(action: onToggleInstruction) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .frame(width: 20, height: 22)
                    }.accessibilityLabel(expanded ? "Collapse instruction" : "Expand instruction")
                }
                Group {
                    if recording && !paused {
                        NotchWaveform(power: power, scrolling: handsFree, reduceMotion: reduceMotion, accent: accent)
                            .frame(width: (meeting || handsFree) ? min(42, geometry.wingWidth - 64) : 58,
                                   height: min(20, geometry.cutout.height - 8))
                    } else if paused {
                        Image(systemName: "pause.fill")
                    } else if let outcome {
                        Image(systemName: outcome == .success ? "circle.fill" : "exclamationmark.triangle.fill")
                    } else if active {
                        ProgressView().controlSize(.mini).tint(Color(nsColor: accent))
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
                if active && meeting {
                    Button(action: onToggleMeetingPause) {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(paused ? "Resume meeting" : "Pause meeting")
                    .help(paused ? "Resume meeting" : "Pause meeting")
                    Button(action: onStopMeeting) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 22)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Stop meeting recording")
                    .help("Stop and save meeting")
                } else if active {
                    if recording && handsFree {
                        Button(action: onStopRecording) {
                            Image(systemName: "stop.fill").font(.system(size: 10))
                                .frame(width: 20, height: 22)
                        }.accessibilityLabel("Finish instruction recording")
                    }
                    Button(action: onCancel) {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .background {
                                Circle().fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.06)],
                                                             startPoint: .top, endPoint: .bottom))
                            }
                            .overlay { Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
                            .contentShape(Circle())
                    }
                    .accessibilityLabel(outcome != nil ? "Dismiss result" : (meeting ? "Discard meeting" : "Cancel activity"))
                    .help(outcome != nil ? "Dismiss result" : (meeting ? "Discard meeting…" : "Cancel · Esc"))
                }
            }
            .padding(.horizontal, 8)
            .frame(width: geometry.wingWidth)
        }
        .buttonStyle(.plain)
        .foregroundStyle(outcome == .needsInput || outcome == .success ? .black : .white)
        .frame(width: geometry.frame().width, height: geometry.frame().height)
        .background(outcome.map { Color(nsColor: $0.color) } ?? .black)
        .overlay {
            silhouette.strokeBorder(
                LinearGradient(colors: [Color(nsColor: accent).opacity(edgeIntensity), .white.opacity(0.07),
                                        Color(nsColor: accent).opacity(edgeIntensity * 0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 0.75
            ).allowsHitTesting(false)
        }
        // Clip after lighting so neither the waveform glow nor the edge spills
        // below the menu bar. The AppKit panel itself has no shadow.
        .overlay {
            NotchCompletionAnimation(completionID: completionID, reduceMotion: reduceMotion, accent: accent)
                .allowsHitTesting(false)
        }
        .clipShape(silhouette)
        .task(id: activationID) {
            edgeIntensity = reduceMotion ? 0.25 : 0.7
            guard !reduceMotion else { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            withAnimation(.easeOut(duration: 1.2)) { edgeIntensity = 0.18 }
        }
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }
}

/// Keep per-frame work out of SwiftUI layout, matching the floating pill's
/// common-mode timer + fixed CALayer bars. The representable owns its timer.
private struct NotchWaveform: NSViewRepresentable {
    let power: () -> Float
    let scrolling: Bool
    let reduceMotion: Bool
    let accent: NSColor

    func makeNSView(context: Context) -> NotchWaveformView { NotchWaveformView() }
    func updateNSView(_ view: NotchWaveformView, context: Context) {
        view.configure(power: power, scrolling: scrolling, reduceMotion: reduceMotion, accent: accent)
    }
    static func dismantleNSView(_ view: NotchWaveformView, coordinator: ()) { view.stop() }
}

@MainActor
private final class NotchWaveformView: NSView {
    private var bars: [CALayer] = []
    private var timer: Timer?
    private var power: () -> Float = { -160 }
    private var scrolling = false
    private var reduceMotion = false
    private var smoothed: CGFloat = 0
    private var samples = Array(repeating: CGFloat(0), count: 15)
    private var nextSample = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Keep both bars and their glow inside the space reserved beside controls.
        layer?.masksToBounds = true
        for _ in 0..<15 {
            let bar = CALayer()
            bar.cornerRadius = 1
            bar.shadowRadius = 3
            bar.shadowOffset = .zero
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(power: @escaping () -> Float, scrolling: Bool, reduceMotion: Bool, accent: NSColor) {
        self.power = power
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.backgroundColor = accent.cgColor
            bar.shadowColor = accent.cgColor
        }
        CATransaction.commit()
        let changed = self.scrolling != scrolling
        self.scrolling = scrolling
        if changed {
            samples = Array(repeating: smoothed, count: 15)
            nextSample = 0
        }
        if self.reduceMotion != reduceMotion { stop() }
        self.reduceMotion = reduceMotion
        startIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { startIfNeeded() }
    }

    override func layout() {
        super.layout()
        drawBars()
    }

    private func startIfNeeded() {
        guard window != nil, timer == nil else { return }
        tick()
        let timer = Timer(timeInterval: reduceMotion ? 0.1 : 1.0 / 30.0,
                          target: self, selector: #selector(timerFired(_:)),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func timerFired(_ timer: Timer) { tick() }

    private func tick() {
        let level = NotchWaveformLevel.amplitude(decibels: power())
        smoothed = IndicatorWaveformDynamics.smooth(level, previous: smoothed)
        if level == 0 {
            for index in samples.indices { samples[index] *= 0.55 }
        }
        samples[nextSample] = smoothed
        nextSample = (nextSample + 1) % samples.count
        drawBars()
    }

    private func drawBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let isStanding = !scrolling || reduceMotion
        let count = isStanding ? 7 : bars.count
        for (index, bar) in bars.enumerated() {
            bar.isHidden = index >= count
            guard index < count else { continue }
            let amplitude = scrolling && !reduceMotion
                ? samples[(nextSample + index) % samples.count]
                : smoothed * IndicatorWaveformDynamics.standingWeight(index: index, count: count)
            if isStanding {
                bar.frame = IndicatorWaveformDynamics.standingBarFrame(
                    index: index, count: count, amplitude: amplitude, bounds: bounds)
            } else {
                let height = 0.75 + amplitude * max(0, min(14, bounds.height) - 0.75)
                let stride = bounds.width / CGFloat(count)
                let width = min(1.25, stride * 0.5)
                bar.frame = CGRect(x: CGFloat(index) * stride + (stride - width) / 2,
                                   y: (bounds.height - height) / 2, width: width, height: height)
            }
            bar.cornerRadius = min(bar.frame.width, bar.frame.height) / 2
            bar.shadowOpacity = Float(amplitude * 0.2)
            bar.shadowPath = CGPath(roundedRect: bar.bounds, cornerWidth: bar.cornerRadius,
                                   cornerHeight: bar.cornerRadius, transform: nil)
        }
        CATransaction.commit()
    }
}
