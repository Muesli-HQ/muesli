import SwiftUI
import AppKit
import MuesliCore

struct ShortcutsView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var recordingTarget: ShortcutTarget?
    @State private var eventMonitor: Any?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                Text("Shortcuts")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                Text("Choose your preferred shortcuts for dictation and computer use commands.")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textSecondary)

                dictationShortcutSection

                computerUseShortcutSection

                doubleTapSection

                resetButton
            }
            .padding(MuesliTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private enum ShortcutTarget {
        case dictation
        case computerUse
    }

    private var dictationShortcutSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Push to Talk")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Hold to record, release to transcribe")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                hotkeyBadge(appState.config.dictationHotkey.label)
            }

            Divider()
                .background(MuesliTheme.surfaceBorder)

            changeButton(for: .dictation)
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var computerUseShortcutSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Computer Use Command")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Hold to record a command, release to plan and run it")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.config.enableComputerUseHotkey },
                    set: { newValue in
                        controller.updateComputerUseHotkeyEnabled(newValue)
                    }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
            }

            Divider()
                .background(MuesliTheme.surfaceBorder)

            HStack(spacing: MuesliTheme.spacing12) {
                hotkeyBadge(appState.config.computerUseHotkey.label)
                changeButton(for: .computerUse)
                    .disabled(!appState.config.enableComputerUseHotkey)
                    .opacity(appState.config.enableComputerUseHotkey ? 1 : 0.55)
            }

            if appState.config.enableComputerUseHotkey,
               appState.config.computerUseHotkey.keyCode == appState.config.dictationHotkey.keyCode {
                Text("Choose a different key than dictation.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.transcribing)
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func hotkeyBadge(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, MuesliTheme.spacing4)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
    }

    private func changeButton(for target: ShortcutTarget) -> some View {
        Button {
            if recordingTarget == target {
                stopRecording()
            } else {
                startRecording(target)
            }
        } label: {
            Text(recordingTarget == target ? "Press a modifier key..." : "Change Shortcut")
                .font(MuesliTheme.body())
                .foregroundStyle(recordingTarget == target ? MuesliTheme.accent : MuesliTheme.textPrimary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MuesliTheme.spacing12)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(recordingTarget == target ? MuesliTheme.accentSubtle : MuesliTheme.surfacePrimary)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(recordingTarget == target ? MuesliTheme.accent.opacity(0.3) : MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var doubleTapSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Hands-Free Mode")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Double-tap to start, tap again to stop")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.config.enableDoubleTapDictation },
                    set: { newValue in
                        controller.updateConfig { $0.enableDoubleTapDictation = newValue }
                    }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var resetButton: some View {
        Button {
            controller.updateDictationHotkey(.default)
            controller.updateComputerUseHotkey(.computerUseDefault)
            controller.updateComputerUseHotkeyEnabled(true)
        } label: {
            Text("Reset to Defaults")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(
            appState.config.dictationHotkey == .default
                && appState.config.computerUseHotkey == .computerUseDefault
                && appState.config.enableComputerUseHotkey
        )
    }

    private func startRecording(_ target: ShortcutTarget) {
        stopRecording()
        recordingTarget = target
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [self] event in
            let keyCode = event.keyCode
            if let label = HotkeyConfig.label(for: keyCode) {
                let newConfig = HotkeyConfig(keyCode: keyCode, label: label)
                switch target {
                case .dictation:
                    controller.updateDictationHotkey(newConfig)
                case .computerUse:
                    controller.updateComputerUseHotkey(newConfig)
                }
                stopRecording()
            }
            return event
        }
    }

    private func stopRecording() {
        recordingTarget = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
