import AppKit
import ApplicationServices
import Foundation
import MuesliCore

enum HotkeyTriggerTiming {
    static let defaultThresholdMilliseconds = 250
    static let minThresholdMilliseconds = 50
    static let maxThresholdMilliseconds = 600
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
    var targetKeyCode: UInt16 = 55
    var doubleTapEnabled: Bool = true

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var prepareWorkItem: DispatchWorkItem?
    private var startWorkItem: DispatchWorkItem?
    private var armCancelWorkItem: DispatchWorkItem?
    private var targetKeyDown = false
    private var otherKeyPressed = false
    private var armed = false
    private var prepared = false
    private var active = false

    // Double-tap detection
    private var lastTapUpTime: Date?
    private var lastTapWasShort = false
    private var toggleActive = false

    private var prepareDelay: TimeInterval
    private var startDelay: TimeInterval
    private var doubleTapWindow: TimeInterval

    init(
        prepareDelay: TimeInterval = 0.15,
        startDelay: TimeInterval = 0.25,
        doubleTapWindow: TimeInterval = 0.35
    ) {
        self.prepareDelay = prepareDelay
        self.startDelay = startDelay
        self.doubleTapWindow = doubleTapWindow
    }

    func configureTriggerThreshold(milliseconds: Int) {
        finishActiveSessionBeforeReconfigure()
        prepareDelay = HotkeyTriggerTiming.prepareDelay(forThresholdMilliseconds: milliseconds)
        startDelay = HotkeyTriggerTiming.startDelay(forThresholdMilliseconds: milliseconds)
        if isRunning && !targetKeyDown && !armed && !prepared && !active && !toggleActive {
            restart()
        }
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        let hasListenAccess = CGPreflightListenEventAccess()
        fputs("[hotkey] listen event access: \(hasListenAccess)\n", stderr)
        if !hasListenAccess {
            let requested = CGRequestListenEventAccess()
            fputs("[hotkey] requested listen event access: \(requested)\n", stderr)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if self.shouldHandleLocalEvent(event) {
                self.handle(event)
            }
            return event
        }

        if globalMonitor != nil || localMonitor != nil {
            fputs("[hotkey] event monitors started\n", stderr)
        } else {
            fputs("[hotkey] failed to start event monitors\n", stderr)
        }
    }

    func stop() {
        finishActiveSessionBeforeReconfigure()
        cancelTimers()
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        targetKeyDown = false
        otherKeyPressed = false
        armed = false
        prepared = false
        active = false
        toggleActive = false
    }

    func configure(keyCode: UInt16) {
        finishActiveSessionBeforeReconfigure()
        targetKeyCode = keyCode
        if isRunning {
            restart()
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
        guard targetKeyDown || armed || prepared || active || toggleActive || armCancelWorkItem != nil else { return }

        let wasToggleActive = toggleActive
        let wasActive = active
        let shouldCancel = prepared || armed || armCancelWorkItem != nil

        targetKeyDown = false
        otherKeyPressed = false
        armed = false
        prepared = false
        active = false
        toggleActive = false
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
        globalMonitor != nil || localMonitor != nil
    }

    var isToggleRecording: Bool {
        toggleActive
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(keyCode: event.keyCode, flags: event.modifierFlags)
        case .keyDown:
            handleKeyDown(keyCode: event.keyCode)
        default:
            break
        }
    }

    private func shouldHandleLocalEvent(_ event: NSEvent) -> Bool {
        shouldHandleLocalEvent(
            type: event.type,
            keyCode: event.keyCode,
            firstResponder: NSApp.keyWindow?.firstResponder
        )
    }

    private func shouldHandleLocalEvent(
        type: NSEvent.EventType,
        keyCode: UInt16,
        firstResponder: NSResponder?
    ) -> Bool {
        let isTextEditing = firstResponder is NSTextView || firstResponder is NSTextField
        guard isTextEditing else { return true }

        // Text editing owns fresh hotkey starts, but an already-armed hotkey
        // session must still receive key-up/Escape cleanup events.
        if targetKeyDown || armed || prepared || active || toggleActive {
            return true
        }

        return type == .keyDown && keyCode == 53
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
                        cancelTimers()
                        onToggleStop?()
                        return
                    }

                    // Check for double-tap
                    if doubleTapEnabled,
                       lastTapWasShort,
                       let lastUp = lastTapUpTime,
                       Date().timeIntervalSince(lastUp) < doubleTapWindow {
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

                // Track tap timing for double-tap detection. Low trigger thresholds can
                // enter the prepared state quickly, but a release before recording starts
                // should still count as a tap.
                if wasDown && !active && !otherKeyPressed {
                    lastTapWasShort = true
                    lastTapUpTime = Date()
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

    func handleKeyDown(keyCode: UInt16) {
        // Escape cancels any active recording
        if keyCode == 53 {
            if toggleActive {
                fputs("[hotkey] escape → cancel toggle\n", stderr)
                toggleActive = false
                cancelTimers()
                onCancel?()
                return
            }
            if active {
                fputs("[hotkey] escape → cancel hold\n", stderr)
                active = false
                prepared = false
                targetKeyDown = false
                armed = false
                cancelTimers()
                onCancel?()
                return
            }
            if armed || prepared {
                fputs("[hotkey] escape → cancel armed hold\n", stderr)
                targetKeyDown = false
                armed = false
                prepared = false
                cancelTimers()
                onCancel?()
            }
            return
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
            }
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + delays.prepare, execute: prepare)
        DispatchQueue.main.asyncAfter(deadline: .now() + delays.start, execute: start)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: item)
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
        prepareWorkItem = nil
        startWorkItem = nil
        armCancelWorkItem = nil
    }

    func setHoldRecordingActiveForTests() {
        targetKeyDown = true
        active = true
    }

    func shouldHandleLocalEventForTests(
        type: NSEvent.EventType,
        keyCode: UInt16,
        firstResponder: NSResponder?
    ) -> Bool {
        shouldHandleLocalEvent(type: type, keyCode: keyCode, firstResponder: firstResponder)
    }
}
