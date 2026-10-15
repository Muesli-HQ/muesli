import Foundation

/// Dictation shortcuts share one recording lifecycle, even when several keys can start it.
final class DictationHotkeyGroup {
    private struct Entry {
        let hotkey: HotkeyConfig
        let monitor: HotkeyMonitor
    }

    var onArm: (() -> Void)?
    var onPrepare: (() -> Void)?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleStart: (() -> Void)?
    var onToggleStop: (() -> Void)?

    var doubleTapEnabled = true { didSet { applySettings() } }
    var combinationActivation: HotkeyMonitor.CombinationActivation = .toggle { didSet { applySettings() } }
    var combinationToggleRequiresHold = true { didSet { applySettings() } }
    var registersCombinationGlobally = false { didSet { applySettings() } }

    private let monitorFactory: () -> HotkeyMonitor
    private var entries: [Entry] = []
    private weak var owner: HotkeyMonitor?
    private var thresholdMilliseconds = HotkeyTriggerTiming.defaultThresholdMilliseconds
    private var captureSuspension = HotkeyCaptureSuspension()

    init(monitorFactory: @escaping () -> HotkeyMonitor = { HotkeyMonitor() }) {
        self.monitorFactory = monitorFactory
        configure([.default])
    }

    func configure(_ hotkeys: [HotkeyConfig]) {
        let wasRunning = isRunning
        let previous = entries
        let retained = previous.filter { old in hotkeys.contains(old.hotkey) }
        previous.filter { old in !hotkeys.contains(old.hotkey) }.forEach { $0.monitor.stop() }
        entries = hotkeys.map { hotkey in
            if let existing = retained.first(where: { $0.hotkey == hotkey }) { return existing }
            let monitor = monitorFactory()
            monitor.configure(hotkey)
            monitor.configureTriggerThreshold(milliseconds: thresholdMilliseconds)
            connect(monitor)
            applySettings(to: monitor)
            if wasRunning { monitor.start() }
            return Entry(hotkey: hotkey, monitor: monitor)
        }
    }

    func configureTriggerThreshold(milliseconds: Int) {
        thresholdMilliseconds = HotkeyTriggerTiming.clampedMilliseconds(milliseconds)
        entries.forEach { $0.monitor.configureTriggerThreshold(milliseconds: thresholdMilliseconds) }
    }

    func start() {
        guard !captureSuspension.isSuspended else { return }
        entries.forEach { $0.monitor.start() }
    }

    func stop() {
        captureSuspension.stopped()
        entries.forEach { $0.monitor.stop() }
        owner = nil
    }

    func stopToggleMode() { owner?.stopToggleMode() }
    func cancelToggleMode() { owner?.cancelToggleMode() }
    func cancelCurrentSession() {
        owner?.cancelCurrentSession()
        owner?.notifyIfSettled()
    }

    func suspendForShortcutCapture() {
        guard !captureSuspension.isSuspended else { return }
        let wasRunning = isRunning
        entries.forEach { $0.monitor.suspendForShortcutCapture() }
        captureSuspension.begin(wasRunning: wasRunning)
    }

    func resumeAfterShortcutCapture() {
        let shouldResume = captureSuspension.end()
        entries.forEach { $0.monitor.resumeAfterShortcutCapture() }
        if shouldResume { start() }
    }

    var isRunning: Bool { entries.contains { $0.monitor.isRunning } }
    var hasPendingOrActiveSession: Bool { owner?.hasPendingOrActiveSession ?? false }
    var isToggleRecording: Bool { owner?.isToggleRecording ?? false }

    private func applySettings() { entries.forEach { applySettings(to: $0.monitor) } }

    private func applySettings(to monitor: HotkeyMonitor) {
        monitor.doubleTapEnabled = doubleTapEnabled
        monitor.combinationActivation = combinationActivation
        monitor.combinationToggleRequiresHold = combinationToggleRequiresHold
        monitor.registersCombinationGlobally = registersCombinationGlobally
    }

    private func connect(_ monitor: HotkeyMonitor) {
        monitor.admitInteraction = { [weak self, weak monitor] in
            guard let self, let monitor else { return false }
            if let owner = self.owner { return owner === monitor }
            self.owner = monitor
            return true
        }
        monitor.onInteractionSettled = { [weak self, weak monitor] in
            guard let self, let monitor, self.owner === monitor else { return }
            self.owner = nil
        }
        monitor.onArm = { [weak self, weak monitor] in
            guard let self, self.owner === monitor else { return }
            self.onArm?()
        }
        monitor.onPrepare = { [weak self, weak monitor] in
            guard let self, self.owner === monitor else { return }
            self.onPrepare?()
        }
        monitor.onStart = { [weak self, weak monitor] in
            guard let self, self.owner === monitor else { return }
            self.onStart?()
        }
        monitor.onStop = { [weak self, weak monitor] in
            guard let self, self.owner === monitor else { return }
            self.onStop?()
        }
        monitor.onCancel = { [weak self, weak monitor] in
            guard let self, self.owner === monitor else { return }
            self.onCancel?()
        }
        monitor.onToggleStart = { [weak self, weak monitor] in
            guard let self, self.owner === monitor else { return }
            self.onToggleStart?()
        }
        monitor.onToggleStop = { [weak self, weak monitor] in
            guard let self, self.owner === monitor else { return }
            self.onToggleStop?()
        }
    }
}
