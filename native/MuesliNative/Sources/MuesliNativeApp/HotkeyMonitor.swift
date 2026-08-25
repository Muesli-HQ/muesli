import AppKit
import ApplicationServices
import Foundation
import MuesliCore

/// How the dictation hotkey triggers recording.
enum DictationTriggerMode: String, CaseIterable, Codable, Sendable {
    /// Hold the hotkey to record; release to stop and transcribe.
    case holdToRecord
    /// Tap the hotkey to start recording; tap again to stop and transcribe.
    case tapToToggle

    var displayName: String {
        switch self {
        case .holdToRecord: "Hold to Record"
        case .tapToToggle: "Tap to Toggle"
        }
    }
}

enum HotkeyTriggerTiming {
    static let defaultThresholdMilliseconds = 250
    static let defaultMeetingThresholdMilliseconds = 600
    static let minThresholdMilliseconds = 50
    static let maxThresholdMilliseconds = 2_000
    static let doubleTapTapGuardDelay: TimeInterval = 0.18

    static func clampedMilliseconds(_ value: Int) -> Int {
        min(max(value, minThresholdMilliseconds), maxThresholdMilliseconds)
    }

    static func startDelay(forThresholdMilliseconds value: Int) -> TimeInterval {
        TimeInterval(clampedMilliseconds(value)) / 1000
    }

    static func prepareDelay(forThresholdMilliseconds value: Int) -> TimeInterval {
        let startDelay = startDelay(forThresholdMilliseconds: value)
        return min(0.15, max(0, startDelay - 0.10))
    }
}

final class HotkeyMonitor {
    var onArm: (() -> Void)?
    var onPrepare: (() -> Void)?
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onCancel: (() -> Void)?
    var onToggleStart: (() -> Void)?
    var onToggleStop: (() -> Void)?
    var onToggleStopAndSubmit: (() -> Void)?
    var targetKeyCode: UInt16 = 55
    var doubleTapEnabled: Bool = true
    var tapToToggleEnabled: Bool = false
    /// When false, Enter during toggle mode stops recording without submitting
    /// (no synthetic Return). The physical Enter is NOT consumed, so it passes
    /// through to the frontmost app normally.
    var submitOnEnterEnabled: Bool = false

    // Combination mode (e.g. Cmd+Shift+R)
    var combinationModifiers: NSEvent.ModifierFlags?
    var combinationKeyCode: UInt16?

    var isCombinationMode: Bool {
        combinationModifiers != nil && combinationKeyCode != nil
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var prepareWorkItem: DispatchWorkItem?
    private var startWorkItem: DispatchWorkItem?
    private var armCancelWorkItem: DispatchWorkItem?
    private var combinationWorkItem: DispatchWorkItem?
    private var targetKeyDown = false
    private var otherKeyPressed = false
    private var armed = false
    private var prepared = false
    private var active = false
    private var combinationKeyDown = false
    private var combinationTriggered = false

    // Double-tap detection
    private var lastTapUpTime: Date?
    private var lastTapWasShort = false
    private var toggleActive = false
    // Set when a key-down stops an active toggle. Prevents the matching
    // key-up from immediately re-starting the toggle in tap-to-toggle mode.
    private var toggleStoppedViaKeyPress = false

    private var prepareDelay: TimeInterval
    private var startDelay: TimeInterval
    private var doubleTapWindow: TimeInterval
    private let scheduleAfter: (TimeInterval, DispatchWorkItem) -> Void
    private let now: () -> Date

    init(
        prepareDelay: TimeInterval = 0.15,
        startDelay: TimeInterval = 0.25,
        doubleTapWindow: TimeInterval = 0.35,
        scheduleAfter: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, item in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.prepareDelay = prepareDelay
        self.startDelay = startDelay
        self.doubleTapWindow = doubleTapWindow
        self.scheduleAfter = scheduleAfter
        self.now = now
    }

    func configureTriggerThreshold(milliseconds: Int) {
        finishActiveSessionBeforeReconfigure()
        prepareDelay = HotkeyTriggerTiming.prepareDelay(forThresholdMilliseconds: milliseconds)
        startDelay = HotkeyTriggerTiming.startDelay(forThresholdMilliseconds: milliseconds)
        if isRunning
            && !targetKeyDown
            && !armed
            && !prepared
            && !active
            && !toggleActive
            && !combinationKeyDown {
            restart()
        }
    }

    func start(requestPermissionIfNeeded: Bool = true) {
        guard eventTap == nil else { return }

        // CGEventTap with .defaultTap can both observe AND consume events.
        // This replaces the previous dual NSEvent monitor approach (global
        // observe-only + local consume) with a single tap that handles all
        // apps uniformly. Requires Accessibility permission.
        let hasListenAccess = CGPreflightListenEventAccess()
        fputs("[hotkey] listen event access: \(hasListenAccess)\n", stderr)
        if !hasListenAccess && requestPermissionIfNeeded {
            let requested = CGRequestListenEventAccess()
            fputs("[hotkey] requested listen event access: \(requested)\n", stderr)
        }

        // .defaultTap (consume) requires Accessibility, not just Input Monitoring.
        // Request it if not already granted so the tap can initialize.
        let hasAxAccess = AXIsProcessTrusted()
        fputs("[hotkey] accessibility access: \(hasAxAccess)\n", stderr)
        if !hasAxAccess && requestPermissionIfNeeded {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options)
            fputs("[hotkey] requested accessibility access\n", stderr)
        }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                
                // The system can disable the tap if the app becomes unresponsive
                // or after a timeout. Re-enable it automatically.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                        fputs("[hotkey] CGEventTap re-enabled after timeout\n", stderr)
                    }
                    return Unmanaged.passUnretained(event)
                }
                
                // Convert CGEvent to NSEvent for the existing handling logic.
                guard let nsEvent = NSEvent(cgEvent: event) else {
                    return Unmanaged.passUnretained(event)
                }
                
                // Preserve the text-editor guard from the old local monitor:
                // when Muesli's own text field has focus, ignore fresh hotkey
                // starts so the modifier key works normally for text input.
                // An already-armed session still receives cleanup events.
                if !monitor.shouldHandleEvent(nsEvent) {
                    return Unmanaged.passUnretained(event)
                }
                
                let consumed = monitor.handle(nsEvent)
                if consumed && type != .flagsChanged {
                    // Returning nil consumes the event — it never reaches
                    // the frontmost app. This is the key capability that
                    // NSEvent.addGlobalMonitorForEvents cannot provide.
                    return nil
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            fputs("[hotkey] failed to create CGEventTap\n", stderr)
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        fputs("[hotkey] CGEventTap started\n", stderr)
    }

    func stop() {
        finishActiveSessionBeforeReconfigure()
        cancelTimers()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        targetKeyDown = false
        otherKeyPressed = false
        armed = false
        prepared = false
        active = false
        toggleActive = false
        toggleStoppedViaKeyPress = false
        combinationKeyDown = false
        combinationTriggered = false
    }

    func configure(keyCode: UInt16) {
        finishActiveSessionBeforeReconfigure()
        combinationModifiers = nil
        combinationKeyCode = nil
        targetKeyCode = keyCode
        if isRunning { restart() }
    }

    func configure(combination config: HotkeyConfig) {
        guard config.isCombination,
              let mods = config.resolvedCombinationModifiers,
              let kc = config.combinationKeyCode else { return }
        finishActiveSessionBeforeReconfigure()
        targetKeyCode = UInt16.max
        combinationModifiers = mods
        combinationKeyCode = kc
        if isRunning { restart() }
    }

    func configure(_ config: HotkeyConfig) {
        if config.isCombination {
            configure(combination: config)
        } else {
            configure(keyCode: config.keyCode)
        }
    }

    func restart() {
        stop()
        start()
    }

    private func restartIfRunning() {
        if isRunning {
            restart()
        }
    }

    private func finishActiveSessionBeforeReconfigure() {
        guard targetKeyDown
            || armed
            || prepared
            || active
            || toggleActive
            || armCancelWorkItem != nil
            || combinationKeyDown
            || combinationWorkItem != nil else { return }

        let wasToggleActive = toggleActive
        let wasActive = active
        let shouldCancel = prepared || armed || armCancelWorkItem != nil

        targetKeyDown = false
        otherKeyPressed = false
        armed = false
        prepared = false
        active = false
        toggleActive = false
        toggleStoppedViaKeyPress = false
        combinationKeyDown = false
        combinationTriggered = false
        lastTapWasShort = false
        lastTapUpTime = nil
        cancelTimers()

        if wasToggleActive {
            onToggleStop?()
        } else if wasActive {
            onStop?()
        } else if shouldCancel {
            onCancel?()
        }
    }

    /// Call externally to stop toggle mode (e.g., from floating indicator click)
    func stopToggleMode() {
        if toggleActive {
            toggleActive = false
            fputs("[hotkey] toggle stopped externally\n", stderr)
            onToggleStop?()
        }
    }

    /// Cancel toggle mode without triggering onToggleStop (discard path)
    func cancelToggleMode() {
        if toggleActive {
            toggleActive = false
            fputs("[hotkey] toggle cancelled externally\n", stderr)
        }
    }

    var isRunning: Bool {
        eventTap != nil
    }

    var isToggleRecording: Bool {
        toggleActive
    }

    /// When Muesli's own text field has focus, ignore fresh hotkey starts so the
    /// modifier key works normally for text input. An already-armed session still
    /// receives key-up/Escape cleanup events. This preserves the guard that the
    /// old NSEvent local monitor provided.
    private func shouldHandleEvent(_ event: NSEvent) -> Bool {
        let firstResponder = NSApp.keyWindow?.firstResponder
        let isTextEditing = firstResponder is NSTextView || firstResponder is NSTextField
        guard isTextEditing else { return true }

        // Text editing owns fresh hotkey starts, but an already-armed hotkey
        // session must still receive key-up/Escape cleanup events.
        if targetKeyDown || armed || prepared || active || toggleActive || combinationKeyDown {
            return true
        }

        return event.type == .keyDown && event.keyCode == 53
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        if isCombinationMode {
            return handleCombination(event)
        }
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(keyCode: event.keyCode, flags: event.modifierFlags)
            // Flags changes are never consumed — the modifier key should still
            // reach the frontmost app so the OS maintains correct modifier state.
            return false
        case .keyDown:
            return handleKeyDown(keyCode: event.keyCode)
        default:
            break
        }
        return false
    }

    @discardableResult
    private func handleCombination(_ event: NSEvent) -> Bool {
        handleCombination(
            type: event.type,
            keyCode: event.keyCode,
            flags: event.modifierFlags,
            isRepeat: event.isARepeat
        )
    }

    @discardableResult
    private func handleCombination(
        type: NSEvent.EventType,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) -> Bool {
        if type == .keyDown && keyCode == 53 {
            if toggleActive {
                toggleActive = false
                fputs("[hotkey] escape → cancel combination toggle\n", stderr)
                onCancel?()
                return true
            }
            if combinationKeyDown {
                cancelCombinationPending(notify: true)
                return true
            }
            return false
        }

        // Enter during toggle mode: stop dictation and submit (paste + Enter).
        // Only the dictation monitor has onToggleStopAndSubmit wired — gate on
        // it so Enter doesn't interfere with computer-use or meeting toggles.
        if type == .keyDown && keyCode == 36 && toggleActive, onToggleStopAndSubmit != nil, submitOnEnterEnabled {
            fputs("[hotkey] enter → toggle stop and submit (combination)\n", stderr)
            toggleActive = false
            cancelTimers()
            onToggleStopAndSubmit?()
            return true
        }

        guard let targetMods = combinationModifiers,
              let targetKey = combinationKeyCode else { return false }

        if type == .flagsChanged, combinationKeyDown,
           HotkeyConfig.supportedCombinationModifiers(from: flags) != targetMods {
            cancelCombinationPending(notify: false)
            return true
        }

        if type == .keyUp, combinationKeyDown, keyCode == targetKey {
            cancelCombinationPending(notify: false)
            return true
        }

        guard type == .keyDown,
              !isRepeat,
              keyCode == targetKey,
              HotkeyConfig.supportedCombinationModifiers(from: flags) == targetMods
        else { return false }

        combinationKeyDown = true
        combinationTriggered = false
        combinationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.combinationKeyDown, !self.combinationTriggered else { return }
            self.combinationTriggered = true
            self.combinationWorkItem = nil
            self.fireCombinationToggle()
        }
        combinationWorkItem = item
        scheduleAfter(startDelay, item)
        fputs("[hotkey] combination armed\n", stderr)
        return true
    }

    private func fireCombinationToggle() {
        combinationKeyDown = false

        if toggleActive {
            fputs("[hotkey] combination → toggle stop\n", stderr)
            toggleActive = false
            onToggleStop?()
        } else {
            fputs("[hotkey] combination → toggle start\n", stderr)
            toggleActive = true
            onToggleStart?()
        }
    }

    private func cancelCombinationPending(notify: Bool) {
        let wasPending = combinationKeyDown && !combinationTriggered
        combinationWorkItem?.cancel()
        combinationWorkItem = nil
        combinationKeyDown = false
        combinationTriggered = false
        if notify && wasPending {
            onCancel?()
        }
    }


    func handleFlagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        if keyCode == targetKeyCode {
            let isDown = isModifierDown(keyCode: targetKeyCode, flags: flags)
            if isDown {
                if !targetKeyDown {
                    armCancelWorkItem?.cancel()
                    armCancelWorkItem = nil
                    targetKeyDown = true
                    otherKeyPressed = false
                    prepared = false

                    // If in toggle mode, stop it on next key press
                    if toggleActive {
                        fputs("[hotkey] toggle stop via keypress\n", stderr)
                        toggleActive = false
                        toggleStoppedViaKeyPress = true
                        cancelTimers()
                        onToggleStop?()
                        return
                    }

                    // Tap-to-toggle: defer the toggle-start decision to key-up.
                    // We arm on key-down but only fire on release if no other key
                    // was pressed while the modifier was held. This filters out
                    // incidental modifier presses during keyboard shortcuts like
                    // Cmd+C / Cmd+V — the maintainer's phantom-press concern.
                    if tapToToggleEnabled {
                        fputs("[hotkey] tap-to-toggle armed (waiting for release)\n", stderr)
                        lastTapWasShort = false
                        lastTapUpTime = nil
                        // Don't arm or schedule timers — just track the press.
                        // The toggle fires on key-up if no other key intervened.
                        return
                    }

                    // Check for double-tap
                    if doubleTapEnabled,
                       lastTapWasShort,
                       let lastUp = lastTapUpTime,
                       now().timeIntervalSince(lastUp) < doubleTapWindow {
                        // Double-tap detected!
                        fputs("[hotkey] double-tap → toggle start\n", stderr)
                        lastTapWasShort = false
                        lastTapUpTime = nil
                        toggleActive = true
                        cancelTimers()
                        onToggleStart?()
                        return
                    }

                    if let onArm {
                        armed = true
                        onArm()
                    }
                    fputs("[hotkey] target key \(targetKeyCode) down\n", stderr)
                    scheduleTimers()
                }
            } else {
                fputs("[hotkey] target key \(targetKeyCode) up\n", stderr)
                let wasDown = targetKeyDown
                let wasArmed = armed
                targetKeyDown = false
                armed = false
                cancelTimers()

                if toggleActive {
                    // Don't stop toggle on key-up — only on next key-down
                    return
                }

                // Tap-to-toggle: fire on key-up only if no other key was pressed
                // while the modifier was held. This is the phantom-press filter:
                // Cmd+C produces Cmd-down → C-down → C-up → Cmd-up, and
                // otherKeyPressed is true by the time Cmd releases, so the
                // toggle doesn't fire. A deliberate tap has no intervening keys.
                //
                // Also skip if this key-up is the release of a press that
                // stopped a toggle — otherwise the stop press would immediately
                // re-start the toggle.
                if tapToToggleEnabled && wasDown && !otherKeyPressed && !toggleStoppedViaKeyPress {
                    fputs("[hotkey] tap-to-toggle → toggle start (release)\n", stderr)
                    toggleActive = true
                    onToggleStart?()
                    return
                }
                // Clear the stop-press flag now that the matching key-up has
                // been processed. The next key-down/key-up cycle starts fresh.
                toggleStoppedViaKeyPress = false

                // Track tap timing for double-tap detection. Low trigger thresholds can
                // enter the prepared state quickly, but a release before recording starts
                // should still count as a tap.
                if wasDown && !active && !otherKeyPressed {
                    lastTapWasShort = true
                    lastTapUpTime = now()
                } else {
                    lastTapWasShort = false
                }

                if active {
                    active = false
                    prepared = false
                    onStop?()
                } else if prepared {
                    prepared = false
                    onCancel?()
                } else if wasArmed {
                    if doubleTapEnabled, lastTapWasShort {
                        scheduleArmCancel()
                    } else {
                        onCancel?()
                    }
                }
            }
        } else if targetKeyDown && !toggleActive {
            fputs("[hotkey] canceled by other modifier key \(keyCode)\n", stderr)
            otherKeyPressed = true
            lastTapWasShort = false
            let wasArmed = armed
            armed = false
            cancelTimers()
            if active {
                active = false
                prepared = false
                onStop?()
            } else if prepared {
                prepared = false
                onCancel?()
            } else if wasArmed {
                onCancel?()
            }
        } else if toggleActive && !tapToToggleEnabled {
            // In double-tap toggle mode, another modifier key cancels the toggle.
            // In tap-to-toggle mode, only the target key or Escape stops recording —
            // unrelated modifier releases (e.g. releasing Shift after Cmd+Tab) must
            // not cancel an active toggle session.
            fputs("[hotkey] canceled by other modifier key \(keyCode) during toggle\n", stderr)
            toggleActive = false
            cancelTimers()
            onCancel?()
        }
    }

    private func isModifierDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 55, 54: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 63:     return flags.contains(.function)
        default:     return false
        }
    }

    @discardableResult
    func handleKeyDown(keyCode: UInt16) -> Bool {
        // Escape cancels any active recording
        if keyCode == 53 {
            if toggleActive {
                fputs("[hotkey] escape → cancel toggle\n", stderr)
                toggleActive = false
                cancelTimers()
                onCancel?()
                return true
            }
            if active {
                fputs("[hotkey] escape → cancel hold\n", stderr)
                active = false
                prepared = false
                targetKeyDown = false
                armed = false
                cancelTimers()
                onCancel?()
                return true
            }
            if armed || prepared {
                fputs("[hotkey] escape → cancel armed hold\n", stderr)
                targetKeyDown = false
                armed = false
                prepared = false
                cancelTimers()
                onCancel?()
                return true
            }
            return false
        }

        // Enter during toggle mode: stop dictation and submit (paste + Enter).
        // Only the dictation monitor has onToggleStopAndSubmit wired — gate on
        // it so Enter doesn't interfere with computer-use or meeting toggles.
        // The CGEventTap consumes this event so the physical Enter never
        // reaches the frontmost app.
        if keyCode == 36 && toggleActive, onToggleStopAndSubmit != nil, submitOnEnterEnabled {
            fputs("[hotkey] enter → toggle stop and submit\n", stderr)
            toggleActive = false
            cancelTimers()
            onToggleStopAndSubmit?()
            return true
        }

        if targetKeyDown && !toggleActive {
            if keyCode != targetKeyCode {
                fputs("[hotkey] canceled by other key\n", stderr)
                otherKeyPressed = true
                lastTapWasShort = false
                let wasArmed = armed
                armed = false
                cancelTimers()
                if active {
                    active = false
                    prepared = false
                    onStop?()
                } else if prepared {
                    prepared = false
                    onCancel?()
                } else if wasArmed {
                    onCancel?()
                }
                return true
            }
        }
        return false
    }

    private func scheduleTimers() {
        let delays = timerDelays()
        let prepare = DispatchWorkItem { [weak self] in
            guard let self, self.targetKeyDown, !self.otherKeyPressed, !self.prepared, !self.active else { return }
            self.armCancelWorkItem?.cancel()
            self.armCancelWorkItem = nil
            self.prepared = true
            self.armed = false
            self.lastTapWasShort = false // Held long enough — not a tap
            fputs("[hotkey] prepared\n", stderr)
            self.onPrepare?()
        }
        let start = DispatchWorkItem { [weak self] in
            guard let self, self.targetKeyDown, !self.otherKeyPressed, !self.active else { return }
            self.armCancelWorkItem?.cancel()
            self.armCancelWorkItem = nil
            if !self.prepared {
                self.prepared = true
                self.armed = false
                self.lastTapWasShort = false
                fputs("[hotkey] prepared\n", stderr)
                self.onPrepare?()
            }
            self.active = true
            fputs("[hotkey] start\n", stderr)
            self.onStart?()
        }
        prepareWorkItem = prepare
        startWorkItem = start
        scheduleAfter(delays.prepare, prepare)
        scheduleAfter(delays.start, start)
    }

    private func scheduleArmCancel() {
        armCancelWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  !self.targetKeyDown,
                  !self.toggleActive,
                  !self.prepared,
                  !self.active
            else { return }
            self.armCancelWorkItem = nil
            self.onCancel?()
        }
        armCancelWorkItem = item
        scheduleAfter(doubleTapWindow, item)
    }

    private func timerDelays() -> (prepare: TimeInterval, start: TimeInterval) {
        guard doubleTapEnabled else {
            return (prepareDelay, startDelay)
        }
        let guardedStartDelay = max(startDelay, HotkeyTriggerTiming.doubleTapTapGuardDelay)
        let guardedPrepareDelay = max(
            HotkeyTriggerTiming.doubleTapTapGuardDelay,
            min(0.15, max(0, guardedStartDelay - 0.10))
        )
        return (min(guardedPrepareDelay, guardedStartDelay), guardedStartDelay)
    }

    private func cancelTimers() {
        prepareWorkItem?.cancel()
        startWorkItem?.cancel()
        armCancelWorkItem?.cancel()
        combinationWorkItem?.cancel()
        prepareWorkItem = nil
        startWorkItem = nil
        armCancelWorkItem = nil
        combinationWorkItem = nil
    }

    func setHoldRecordingActiveForTests() {
        targetKeyDown = true
        active = true
    }

    @discardableResult
    func handleCombinationForTests(
        type: NSEvent.EventType,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        isRepeat: Bool = false
    ) -> Bool {
        handleCombination(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
    }
}
