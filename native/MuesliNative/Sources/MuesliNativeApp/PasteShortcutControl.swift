import AppKit
import SwiftUI

/// Commit only after the chord's key AND modifiers are released, before resuming
/// global listeners. Caps Lock / Fn device flags aren't part of a saved chord.
struct PasteShortcutCaptureState {
    private(set) var pending: PasteKeyChord?
    private var keyIsDown = false

    mutating func keyDown(keyCode: UInt16, flags: CGEventFlags, isRepeat: Bool) {
        guard pending == nil, !isRepeat else { return }
        pending = PasteKeyChord(keyCode: keyCode, modifiers: flags.intersection(PasteKeyChord.supportedModifiers))
        keyIsDown = pending != nil
    }

    mutating func keyUp(keyCode: UInt16) {
        if pending?.keyCode == keyCode { keyIsDown = false }
    }

    func completedChord(flags: CGEventFlags) -> PasteKeyChord? {
        guard !keyIsDown, flags.intersection(PasteKeyChord.supportedModifiers).isEmpty else { return nil }
        return pending
    }
}

@MainActor @Observable
final class PasteShortcutRecorder {
    private(set) var isRecording = false
    private(set) var message: String?
    private var state = PasteShortcutCaptureState()
    private var monitor: Any?
    private var timeout: Task<Void, Never>?
    private var release: (() -> Void)?
    private let addMonitor: (@escaping (NSEvent) -> NSEvent?) -> Any?
    private let removeMonitor: (Any) -> Void

    init(
        addMonitor: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = {
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: $0)
        },
        removeMonitor: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
    ) {
        self.addMonitor = addMonitor
        self.removeMonitor = removeMonitor
    }

    func start(controller: MuesliController) {
        start(acquire: { controller.beginShortcutCapture() },
              release: { controller.endShortcutCapture() },
              conflicts: { controller.pasteShortcutConflict($0) },
              commit: { chord in controller.updateConfig { $0.pasteShortcut = .custom(chord) } })
    }

    func start(acquire: () -> Bool, release: @escaping () -> Void,
               conflicts: @escaping (PasteKeyChord) -> Bool, commit: @escaping (PasteKeyChord) -> Void) {
        cancel()
        guard acquire() else {
            message = "Finish recording or processing before changing the paste shortcut."
            return
        }
        self.release = release
        state = PasteShortcutCaptureState()
        isRecording = true
        message = "Press a modifier + key. Escape cancels."
        monitor = addMonitor { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.cancel()
                return nil
            }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            if event.type == .keyDown {
                self.state.keyDown(keyCode: event.keyCode, flags: flags, isRepeat: event.isARepeat)
                self.message = self.state.pending == nil
                    ? "Include Command, Control, Option, or Shift with a key."
                    : "Release the keys to save."
            } else if event.type == .keyUp {
                self.state.keyUp(keyCode: event.keyCode)
            }
            if let chord = self.state.completedChord(flags: flags) {
                if conflicts(chord) {
                    self.cancel()
                    self.message = "That shortcut activates another Muesli feature. Choose a different chord."
                } else {
                    // End the capture before updating config (which may refresh monitors).
                    self.cancel()
                    commit(chord)
                }
            }
            return nil
        }
        guard monitor != nil else {
            cancel()
            message = "Could not start shortcut recording. Try again."
            return
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.cancel()
        }
    }

    func cancel() {
        if let monitor { removeMonitor(monitor) }
        monitor = nil
        timeout?.cancel()
        timeout = nil
        isRecording = false
        message = nil
        state = PasteShortcutCaptureState()
        let finish = release
        release = nil
        finish?()
    }
}

struct PasteShortcutControl: View {
    let controller: MuesliController
    let appState: AppState
    @State private var recorder = PasteShortcutRecorder()

    private var shortcutOptions: [String] {
        var options = [PasteShortcut.automatic.displayLabel]
        if case .custom = appState.config.pasteShortcut {
            options.append(appState.config.pasteShortcut.displayLabel)
        }
        options.append("Record custom shortcut…")
        return options
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            FixedWidthPopUp(
                selection: appState.config.pasteShortcut.displayLabel,
                options: shortcutOptions
            ) { option in
                if option == PasteShortcut.automatic.displayLabel {
                    recorder.cancel()
                    controller.updateConfig { $0.pasteShortcut = .automatic }
                } else if option == "Record custom shortcut…" {
                    recorder.start(controller: controller)
                }
            }
            .frame(height: 24)
            .disabled(recorder.isRecording)
            .accessibilityLabel("Paste shortcut")
            if recorder.isRecording {
                Button("Cancel") { recorder.cancel() }
            }
            if let message = recorder.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(message)
            }
        }
        .onDisappear { recorder.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in recorder.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in recorder.cancel() }
        .onChange(of: appState.dictationState) { _, value in if value != .idle { recorder.cancel() } }
        .onChange(of: appState.isMeetingStarting) { _, value in if value { recorder.cancel() } }
        .onChange(of: appState.isMeetingRecording) { _, value in if value { recorder.cancel() } }
    }
}
