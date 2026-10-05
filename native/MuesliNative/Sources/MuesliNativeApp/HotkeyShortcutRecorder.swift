import AppKit
import Observation

/// Records either one bare modifier or a modifier chord, and completes only after
/// every recorded key is released so resumed global monitors never see its tail.
struct HotkeyShortcutCaptureState {
    let target: ShortcutAssignment
    private(set) var completed: HotkeyConfig?
    private(set) var rejectedChord = false
    private var bareModifierKeyCode: UInt16?
    private var pendingCombination: HotkeyConfig?
    private var combinationKeyIsDown = false

    init(target: ShortcutAssignment) {
        self.target = target
    }

    private static let heldModifierFlags: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]

    mutating func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool) {
        bareModifierKeyCode = nil
        guard pendingCombination == nil, !isRepeat else { return }
        let modifiers = HotkeyConfig.supportedCombinationModifiers(from: flags)
        guard !modifiers.isEmpty else { return }
        let candidate = HotkeyConfig.combination(modifiers: modifiers, keyCode: keyCode)
        guard Self.accepts(candidate, for: target) else {
            rejectedChord = true
            return
        }
        rejectedChord = false
        pendingCombination = candidate
        combinationKeyIsDown = true
    }

    mutating func keyUp(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        if pendingCombination?.combinationKeyCode == keyCode {
            combinationKeyIsDown = false
        }
        completeCombinationIfReleased(flags: flags)
    }

    mutating func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        defer { completeCombinationIfReleased(flags: flags) }
        guard pendingCombination == nil, let label = HotkeyConfig.label(for: keyCode) else { return }
        let otherModifiers = flags.intersection(Self.heldModifierFlags)
            .subtracting(Self.modifierFlag(for: keyCode))
        if Self.isModifierDown(keyCode: keyCode, flags: flags) {
            // Only a modifier pressed on its own can become a bare-modifier shortcut.
            bareModifierKeyCode = otherModifiers.isEmpty ? keyCode : nil
        } else if bareModifierKeyCode == keyCode {
            bareModifierKeyCode = nil
            if otherModifiers.isEmpty {
                completed = HotkeyConfig(keyCode: keyCode, label: label)
            }
        } else {
            bareModifierKeyCode = nil
        }
    }

    private mutating func completeCombinationIfReleased(flags: NSEvent.ModifierFlags) {
        guard let pendingCombination, !combinationKeyIsDown,
              HotkeyConfig.supportedCombinationModifiers(from: flags).isEmpty else { return }
        completed = pendingCombination
    }

    static func accepts(_ hotkey: HotkeyConfig, for target: ShortcutAssignment) -> Bool {
        switch target {
        case .dictation:
            return hotkey.isValidDictationShortcut
        case .quil:
            return ShortcutHotkeyPolicy.isValidQuilShortcut(hotkey)
        case .meetingRecording:
            return hotkey.combinationKeyCode.flatMap(HotkeyConfig.letterLabel(for:)) != nil
        case .computerUse:
            return false
        }
    }

    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 55, 54: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return []
        }
    }

    private static func isModifierDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        let flag = modifierFlag(for: keyCode)
        return !flag.isEmpty && flags.contains(flag)
    }
}

/// Owns one Shortcuts-page capture: global hotkey monitors stay suspended from
/// start until commit, Escape, or teardown, and are resumed before saving.
@MainActor @Observable
final class HotkeyShortcutRecorder {
    static let busyMessage = "Finish recording or processing before changing shortcuts."
    static let installFailedMessage = "Could not start shortcut recording. Try again."

    private(set) var target: ShortcutAssignment?
    private(set) var rejectedChord = false
    /// The window that was key when capture started; only its resignation ends capture.
    private(set) weak var window: NSWindow?
    private var state: HotkeyShortcutCaptureState?
    private var monitor: Any?
    private var timeoutTask: Task<Void, Never>?
    private var release: (() -> Void)?
    private let addMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeMonitor: (Any) -> Void
    private let keyWindow: () -> NSWindow?
    private let timeout: Duration

    init(
        addMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = {
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: $0)
        },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) },
        keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
        timeout: Duration = .seconds(30)
    ) {
        self.addMonitor = addMonitor
        self.removeMonitor = removeMonitor
        self.keyWindow = keyWindow
        self.timeout = timeout
    }

    /// Returns a message when capture could not start.
    func start(
        _ target: ShortcutAssignment,
        acquire: () -> Bool,
        release: @escaping () -> Void,
        commit: @escaping (HotkeyConfig) -> Void
    ) -> String? {
        cancel()
        guard acquire() else { return Self.busyMessage }
        self.release = release
        self.target = target
        window = keyWindow()
        state = HotkeyShortcutCaptureState(target: target)
        monitor = addMonitor { [weak self] event in
            guard let self else { return event }
            return self.handle(event, commit: commit) ? nil : event
        }
        guard monitor != nil else {
            cancel()
            return Self.installFailedMessage
        }
        // Every global shortcut stays paused while capture is open.
        timeoutTask = Task { [weak self, timeout] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.cancel()
        }
        return nil
    }

    func windowDidResignKey(_ resigned: NSWindow?) {
        guard let window, resigned === window else { return }
        cancel()
    }

    func cancel() {
        if let monitor { removeMonitor(monitor) }
        monitor = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        target = nil
        window = nil
        state = nil
        rejectedChord = false
        let finish = release
        release = nil
        finish?()
    }

    /// Returns true when the event belongs to the recorder and must not reach the app.
    private func handle(_ event: NSEvent, commit: (HotkeyConfig) -> Void) -> Bool {
        guard var state else { return false }
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 {
                cancel()
                return true
            }
            state.keyDown(keyCode: event.keyCode, flags: event.modifierFlags, isRepeat: event.isARepeat)
        case .keyUp:
            state.keyUp(keyCode: event.keyCode, flags: event.modifierFlags)
        case .flagsChanged:
            state.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags)
        default:
            return false
        }
        self.state = state
        rejectedChord = state.rejectedChord
        if let hotkey = state.completed {
            // Resume monitors before saving; saving may reconfigure and start them.
            cancel()
            commit(hotkey)
        }
        return event.type != .flagsChanged
    }
}
