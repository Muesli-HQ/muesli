import AppKit
import SwiftUI

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
}

@MainActor
private final class NotchIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
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
    var onOpenHome: (() -> Void)?
    var onCancel: (() -> Void)?
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
              recording: Bool, paused: Bool, meeting: Bool, handsFree: Bool, active: Bool, icon: NSImage) -> Bool {
        guard let geometry = Self.geometry(for: screen) else { hide(); return false }
        dismissActivity?.cancel()
        dismissActivity = nil
        let now = Date()
        if active && !visibility.active {
            activationID += 1
            completionID = 0
        }
        guard visibility.update(active: active, now: now) else {
            hide()
            // Supported but intentionally hidden: do not show the floating fallback.
            return true
        }
        self.icon = icon
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
        dismissActivity?.cancel()
        dismissActivity = nil
        visibility = NotchActivityVisibility()
        completionID = 0
        panel?.orderOut(nil)
        // Releasing the hosted view cancels waveform/activation tasks while hidden.
        panel?.contentView = nil
    }

    func showCompletion() {
        guard isVisible, !visibility.active else { return }
        visibility.complete(now: Date())
        completionID += 1
        render()
        scheduleDismissal()
    }

    private func render() {
        guard let geometry, let panel else { return }
        let frame = geometry.frame()
        panel.setFrame(frame, display: true)
        let view = NotchIndicatorView(geometry: geometry, active: visibility.active, activationID: activationID,
            completionID: completionID, handsFree: handsFree,
            title: title, detail: detail, recording: recording, paused: paused, meeting: meeting, icon: icon,
            onCancel: { [weak self] in self?.onCancel?() },
            onOpenHome: { [weak self] in self?.onOpenHome?() },
            power: { [weak self] in self?.powerProvider?() ?? -160 })
        if let hosting = panel.contentView as? NSHostingView<NotchIndicatorView> {
            hosting.rootView = view
        } else {
            panel.contentView = NSHostingView(rootView: view)
        }
    }
}

private struct NotchIndicatorView: View {
    let geometry: NotchIndicatorGeometry
    let active: Bool
    let activationID: Int
    let completionID: Int
    let handsFree: Bool
    let title: String
    let detail: String
    let recording: Bool
    let paused: Bool
    let meeting: Bool
    let icon: NSImage
    let onCancel: () -> Void
    let onOpenHome: () -> Void
    let power: () -> Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var edgeIntensity = 0.18

    private var silhouette: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
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
            Color.clear.frame(width: geometry.cutout.width).allowsHitTesting(false)
                .accessibilityHidden(true)

            HStack(spacing: 7) {
                Group {
                    if recording && !paused {
                        NotchWaveform(power: power, scrolling: handsFree, reduceMotion: reduceMotion)
                            .frame(width: 58, height: min(20, geometry.cutout.height - 8))
                    } else if paused {
                        Image(systemName: "pause.fill")
                    } else if active {
                        ProgressView().controlSize(.mini).tint(.orange)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
                if active {
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
                    .accessibilityLabel(meeting ? "Discard meeting" : "Cancel dictation")
                    .help(meeting ? "Discard meeting…" : "Cancel · Esc")
                }
            }
            .padding(.horizontal, 8)
            .frame(width: geometry.wingWidth)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(width: geometry.frame().width, height: geometry.frame().height)
        .background(.black)
        .overlay {
            silhouette.strokeBorder(
                LinearGradient(colors: [.orange.opacity(edgeIntensity), .white.opacity(0.07),
                                        .orange.opacity(edgeIntensity * 0.6)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 0.75
            ).allowsHitTesting(false)
        }
        // Clip after lighting so neither the waveform glow nor the edge spills
        // below the menu bar. The AppKit panel itself has no shadow.
        .overlay {
            NotchCompletionAnimation(completionID: completionID, reduceMotion: reduceMotion)
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

    func makeNSView(context: Context) -> NotchWaveformView { NotchWaveformView() }
    func updateNSView(_ view: NotchWaveformView, context: Context) {
        view.configure(power: power, scrolling: scrolling, reduceMotion: reduceMotion)
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
        for _ in 0..<15 {
            let bar = CALayer()
            bar.backgroundColor = NSColor.systemOrange.cgColor
            bar.cornerRadius = 1
            bar.shadowColor = NSColor.systemOrange.cgColor
            bar.shadowRadius = 3
            bar.shadowOffset = .zero
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(power: @escaping () -> Float, scrolling: Bool, reduceMotion: Bool) {
        self.power = power
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
        for (index, bar) in bars.enumerated() {
            let amplitude = scrolling && !reduceMotion
                ? samples[(nextSample + index) % samples.count]
                : smoothed * IndicatorWaveformDynamics.standingWeight(index: index, count: bars.count)
            let height = 1 + amplitude * max(0, bounds.height - 1)
            bar.frame = CGRect(x: CGFloat(index) * 4, y: (bounds.height - height) / 2,
                               width: 2, height: height)
            bar.shadowOpacity = Float(amplitude * 0.45)
            bar.shadowPath = CGPath(roundedRect: bar.bounds, cornerWidth: 1, cornerHeight: 1, transform: nil)
        }
        CATransaction.commit()
    }
}
