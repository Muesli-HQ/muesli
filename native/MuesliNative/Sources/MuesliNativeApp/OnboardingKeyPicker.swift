import AppKit
import SwiftUI

struct OnboardingKeycap: View {
    let shortcut: HotkeyConfig
    let selected: Bool
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let legend = shortcut.displayLabel.components(separatedBy: " ").last ?? shortcut.displayLabel
        ZStack(alignment: .top) {
            shape.fill(MuesliTheme.surfaceBorder)
            VStack(spacing: 1) {
                if shortcut.keyCode == 63 && !shortcut.isCombination {
                    Image(systemName: "globe")
                        .font(.system(size: 18))
                    Text("fn").font(MuesliTheme.caption())
                } else {
                    Text(shortcut.isCombination ? shortcut.displayLabel : legend)
                        .font(.system(size: 21, weight: .medium))
                    if !shortcut.isCombination {
                        Text(shortcut.label.hasPrefix("Right") ? "Right" : "Left")
                            .font(MuesliTheme.caption())
                    }
                }
            }
            .foregroundStyle(selected ? MuesliTheme.accentText : MuesliTheme.textPrimary)
            .padding(.horizontal, 10)
            .frame(minWidth: 52, minHeight: 49)
            .background(shape.fill(selected ? MuesliTheme.surfaceSelected : MuesliTheme.backgroundRaised))
            .overlay(shape.strokeBorder(selected ? MuesliTheme.accent : MuesliTheme.surfaceBorder,
                                       lineWidth: selected ? 2 : 1))
            .offset(y: pressed ? 4 : 0)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 54)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut.spokenKeycapName)
    }
}

private extension HotkeyConfig {
    var spokenKeycapName: String {
        label.replacingOccurrences(of: "Cmd", with: "Command")
            .replacingOccurrences(of: "Ctrl", with: "Control")
    }
}

private struct KeycapButtonStyle: ButtonStyle {
    let shortcut: HotkeyConfig
    let selected: Bool
    let held: Bool

    func makeBody(configuration: Configuration) -> some View {
        OnboardingKeycap(shortcut: shortcut, selected: selected, pressed: held || configuration.isPressed)
    }
}

struct OnboardingKeyPicker: View {
    @Binding var selection: HotkeyConfig
    let soundEnabled: Bool
    @State private var held: UInt16?

    var body: some View {
        VStack(spacing: MuesliTheme.spacing24) {
            Text("Dictation shortcut").font(MuesliTheme.title1())
            Text("Press and release a modifier key, or click a key below.")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
            VStack(spacing: MuesliTheme.spacing8) {
                HStack {
                    keys([56])
                    Spacer()
                    keys([60])
                }
                HStack(spacing: 5) {
                    keys([63, 59, 58, 55])
                    Spacer(minLength: 12)
                    keys([54, 61])
                    // Extended keyboards can supply Right Control. Show its cap
                    // while pressed or selected, including restored shortcuts.
                    if held == 62 || (!selection.isCombination && selection.keyCode == 62) {
                        keys([62])
                    }
                }
            }
            .frame(maxWidth: 450)
            HStack(spacing: MuesliTheme.spacing8) {
                if selection.isCombination {
                    OnboardingKeycap(shortcut: selection, selected: true, pressed: false)
                }
                Text("Selected: " + selection.spokenKeycapName)
                    .font(MuesliTheme.body())
            }
        }
        .foregroundStyle(MuesliTheme.textPrimary)
        .padding(.horizontal, MuesliTheme.spacing16)
        .background(ModifierKeyListener(held: $held, select: select))
    }

    @ViewBuilder
    private func keys(_ codes: [UInt16]) -> some View {
        ForEach(codes, id: \.self) { code in
            if let label = HotkeyConfig.label(for: code) {
                let shortcut = HotkeyConfig(keyCode: code, label: label)
                let selected = !selection.isCombination && selection.keyCode == code
                Button(shortcut.spokenKeycapName) { select(code) }
                    .buttonStyle(KeycapButtonStyle(shortcut: shortcut, selected: selected, held: held == code))
                    .accessibilityLabel(shortcut.spokenKeycapName)
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func select(_ code: UInt16) {
        guard let label = HotkeyConfig.label(for: code) else { return }
        selection = HotkeyConfig(keyCode: code, label: label)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        if soundEnabled { Self.click?.play() }
    }

    private static let click: NSSound? = {
        guard let url = SoundController.bundledLifecycleSoundURL(named: "keycap-click") else { return nil }
        let sound = NSSound(contentsOf: url, byReference: false)
        sound?.volume = 0.16
        return sound
    }()
}

/// Observe bare modifier gestures only inside the picker window. Leave normal
/// shortcuts and keyboard navigation to AppKit and discard interrupted gestures.
private struct ModifierKeyListener: NSViewRepresentable {
    @Binding var held: UInt16?
    let select: (UInt16) -> Void

    func makeNSView(context: Context) -> Listener {
        let view = Listener()
        view.update = { held = $0 }
        view.select = select
        return view
    }

    func updateNSView(_ view: Listener, context: Context) {
        view.update = { held = $0 }
        view.select = select
    }

    static func dismantleNSView(_ view: Listener, coordinator: ()) {
        view.stop()
    }

    final class Listener: NSView {
        var update: ((UInt16?) -> Void)?
        var select: ((UInt16) -> Void)?
        private var gesture = ModifierKeyGesture()
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(resetGesture),
                name: NSWindow.didResignKeyNotification, object: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown]) { [weak self, weak window] event in
                guard let self, let window, window.isKeyWindow, (event.window == nil || event.window === window) else { return event }
                self.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            let previous = gesture.held
            let selection = gesture.receive(event.type, keyCode: event.type == .leftMouseDown ? 0 : event.keyCode,
                                            flags: event.modifierFlags)
            if previous != gesture.held { update?(gesture.held) }
            if let selection { select?(selection) }
        }

        @objc private func resetGesture() {
            let wasHeld = gesture.held != nil
            gesture = ModifierKeyGesture()
            if wasHeld { update?(nil) }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            resetGesture()
        }
    }
}

/// A selection is committed on the matching release. Once a second key or a
/// click interrupts a gesture, wait for all modifiers to rise before rearming.
struct ModifierKeyGesture {
    private(set) var held: UInt16?
    private var awaitingRelease = false

    mutating func receive(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> UInt16? {
        let modifiers = flags.intersection([.command, .option, .control, .shift, .function])
        guard type == .flagsChanged else {
            if !modifiers.isEmpty {
                awaitingRelease = true
                held = nil
            }
            return nil
        }
        if modifiers.isEmpty {
            let selection = held == keyCode ? held : nil
            self = Self()
            return selection
        }
        if !awaitingRelease && modifiers.rawValue.nonzeroBitCount == 1 && HotkeyConfig.label(for: keyCode) != nil {
            held = keyCode
        } else {
            held = nil
        }
        awaitingRelease = true
        return nil
    }
}
