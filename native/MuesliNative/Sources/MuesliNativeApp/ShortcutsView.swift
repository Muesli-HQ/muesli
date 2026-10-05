import SwiftUI
import AppKit
import MuesliCore

struct ShortcutsView: View {
    let appState: AppState
    let controller: MuesliController
    @State private var permissionMonitoringClientID = UUID()
    @State private var recorder = HotkeyShortcutRecorder()
    @State private var dictationShortcutMessage: String?
    @State private var computerUseShortcutMessage: String?
    @State private var quilShortcutMessage: String?
    @State private var meetingRecordingShortcutMessage: String?

    var body: some View {
        // Build once for this surface; Observation refreshes dynamic choices.
        let _ = appState.config
        return settingsContent.environment(\.muesliSettingDefinitions, controller.settingsDefinitions())
    }

    private var settingsContent: some View {
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

                quilShortcutSection

                meetingRecordingShortcutSection

                doubleTapSection

                resetButton
            }
            .padding(.horizontal, MuesliTheme.spacing32)
            .padding(.top, MuesliTheme.pageTop)
            .padding(.bottom, MuesliTheme.spacing32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            controller.beginInteractionPermissionMonitoring(clientID: permissionMonitoringClientID)
            reconcilePushToTalkState()
            reconcileIndependentShortcutState()
        }
        .onChange(of: appState.interactionPermissionSnapshot) { _, snapshot in
            guard let snapshot else { return }
            reconcilePushToTalkState(permissions: snapshot.onboardingSnapshot)
            reconcileIndependentShortcutState()
        }
        .onChange(of: appState.config.enablePushToTalk) { _, enabled in
            if !enabled, recordingTarget == .dictation { stopRecording() }
        }
        .onChange(of: appState.config.enableComputerUseHotkey) { _, enabled in
            reconcileIndependentShortcutState()
            if !enabled, recordingTarget == .computerUse { stopRecording() }
        }
        .onChange(of: appState.config.enableQuilMode) { _, enabled in
            reconcileIndependentShortcutState()
            if !enabled, recordingTarget == .quil { stopRecording() }
        }
        .onChange(of: appState.config.enableMeetingRecordingHotkey) { _, enabled in
            reconcileIndependentShortcutState()
            if !enabled, recordingTarget == .meetingRecording { stopRecording() }
        }
        .onDisappear {
            controller.endInteractionPermissionMonitoring(clientID: permissionMonitoringClientID)
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            recorder.windowDidResignKey(notification.object as? NSWindow)
        }
    }

    private var recordingTarget: ShortcutTarget? { recorder.target }

    private var isDictationCombinationToggle: Bool {
        appState.config.dictationHotkey.isCombination
            && appState.config.dictationCombinationActivation == .toggle
    }

    private var dictationCombinationActivationControl: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Text("Activation")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
            Spacer(minLength: MuesliTheme.spacing16)
            Picker("Activation", selection: Binding(
                get: { appState.config.dictationCombinationActivation },
                set: { controller.updateDictationCombinationActivation($0) }
            )) {
                Text("Hold to talk").tag(HotkeyMonitor.CombinationActivation.pushToTalk)
                Text("Toggle").tag(HotkeyMonitor.CombinationActivation.toggle)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
        .disabled(!isPushToTalkEnabled || recordingTarget != nil)
        .opacity(isPushToTalkEnabled ? 1 : 0.55)
    }

    private var isPushToTalkEnabled: Bool {
        appState.config.enablePushToTalk
    }

    private var pushToTalkPermissionMessage: String {
        PushToTalkEnablementPolicy.PermissionProfile.resolved(
            for: appState.config.resolvedOnboardingUseCase
        ).missingPermissionsMessage
    }

    private typealias ShortcutTarget = ShortcutAssignment

    private var dictationShortcutSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Push to Talk")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(isDictationCombinationToggle
                        ? "Hold to start recording, hold again to transcribe"
                        : "Hold to record, release to transcribe")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                HStack(spacing: MuesliTheme.spacing8) {
                    Text(isPushToTalkEnabled ? "On" : "Off")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                    MuesliSettingControl(controller: controller, id: "push_to_talk")
                    .toggleStyle(.switch)
                    .tint(MuesliTheme.accent)
                    .labelsHidden()
                }
            }

            Divider()
                .background(MuesliTheme.surfaceBorder)

            pushToTalkControls

            if appState.config.dictationHotkey.isCombination {
                dictationCombinationActivationControl
            }

            if !isPushToTalkEnabled {
                pushToTalkDisabledMessage
            }

            if recordingTarget == .dictation, recorder.rejectedChord {
                shortcutMessage(ShortcutHotkeyPolicy.dictationShortcutMessage)
            } else if let dictationShortcutMessage {
                shortcutMessage(dictationShortcutMessage)
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
                MuesliSettingControl(controller: controller, id: "cua_shortcut")
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
            }

            Divider()
                .background(MuesliTheme.surfaceBorder)

            shortcutControls(
                target: .computerUse,
                threshold: appState.config.computerUseHotkeyTriggerThresholdMS,
                isEnabled: appState.config.enableComputerUseHotkey
            ) { value in
                controller.updateConfig { $0.computerUseHotkeyTriggerThresholdMS = value }
            }

            if appState.config.enableComputerUseHotkey,
               ShortcutHotkeyPolicy.hotkeysConflict(appState.config.computerUseHotkey, appState.config.dictationHotkey) {
                shortcutMessage(ShortcutHotkeyPolicy.conflictMessage)
            } else if let computerUseShortcutMessage {
                shortcutMessage(computerUseShortcutMessage)
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

    private var meetingRecordingShortcutSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Meeting Recording")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Toggle meeting recording on/off")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                MuesliSettingControl(controller: controller, id: "meeting_shortcut")
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
            }

            Divider()
                .background(MuesliTheme.surfaceBorder)

            shortcutControls(
                target: .meetingRecording,
                threshold: appState.config.meetingRecordingHotkeyTriggerThresholdMS,
                isEnabled: appState.config.enableMeetingRecordingHotkey
            ) { value in
                controller.updateConfig { $0.meetingRecordingHotkeyTriggerThresholdMS = value }
            }

            if let meetingRecordingShortcutMessage {
                shortcutMessage(meetingRecordingShortcutMessage)
            } else if appState.config.enableMeetingRecordingHotkey,
                      let warning = ShortcutHotkeyPolicy.commonGlobalShortcutWarning(for: appState.config.meetingRecordingHotkey) {
                shortcutMessage(warning)
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

    private var quilShortcutSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Image(nsImage: QuillIcon.image())
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .foregroundStyle(MuesliTheme.accent)
                        Text("Quill")
                            .font(MuesliTheme.headline())
                            .foregroundStyle(MuesliTheme.textPrimary)
                    }
                    Text("Highlight text, hold to speak an editing instruction, then release to replace")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                MuesliSettingControl(controller: controller, id: "quill")
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
            }

            Divider().background(MuesliTheme.surfaceBorder)

            shortcutControls(
                target: .quil,
                threshold: appState.config.quilHotkeyTriggerThresholdMS,
                isEnabled: appState.config.enableQuilMode
            ) { value in
                controller.updateConfig { $0.quilHotkeyTriggerThresholdMS = value }
            }

            if let quilShortcutMessage { shortcutMessage(quilShortcutMessage) }
        }
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private func hotkeyBadge(_ hotkey: HotkeyConfig) -> some View {
        Text(hotkey.displayLabel)
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
            .help(hotkey.label)
    }

    private func shortcutControls(
        target: ShortcutTarget,
        threshold: Int,
        isEnabled: Bool = true,
        onThresholdChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: MuesliTheme.spacing12) {
            hotkeyBadge(hotkey(for: target))
            compactChangeButton(for: target)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.55)
            Spacer(minLength: MuesliTheme.spacing16)
            if isEnabled {
                thresholdInput(
                    value: threshold,
                    onChange: onThresholdChange
                )
            }
        }
    }

    private var pushToTalkControls: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Text("Shortcut")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
            hotkeyBadge(appState.config.dictationHotkey)
            compactChangeButton(for: .dictation)
            Spacer(minLength: MuesliTheme.spacing16)
            thresholdInput(
                value: appState.config.hotkeyTriggerThresholdMS,
                label: "Hold duration"
            ) { value in
                controller.updateConfig { $0.hotkeyTriggerThresholdMS = value }
            }
        }
        .disabled(!isPushToTalkEnabled)
        .opacity(isPushToTalkEnabled ? 1 : 0.55)
    }

    private func hotkey(for target: ShortcutTarget) -> HotkeyConfig {
        appState.config[keyPath: target.keyPath]
    }

    private func thresholdInput(
        value: Int,
        label: String = "Hold",
        onChange: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Text(label)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)

            TextField(
                "",
                value: Binding(
                    get: { HotkeyTriggerTiming.clampedMilliseconds(value) },
                    set: { onChange(HotkeyTriggerTiming.clampedMilliseconds($0)) }
                ),
                format: .number
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(MuesliTheme.textPrimary)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, MuesliTheme.spacing4)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )

            Text("ms")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .help("Hold threshold: \(HotkeyTriggerTiming.minThresholdMilliseconds)-\(HotkeyTriggerTiming.maxThresholdMilliseconds) ms")
    }

    private var pushToTalkDisabledMessage: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "info.circle")
                .foregroundStyle(MuesliTheme.accent)
            Text(pushToTalkDisabledMessageText)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
    }

    private var pushToTalkDisabledMessageText: String {
        appState.config.resolvedOnboardingUseCase.includesPushToTalk
            ? "Push to Talk is turned off."
            : "Dictation wasn’t enabled during setup."
    }

    private func shortcutMessage(_ message: String) -> some View {
        Text(message)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.transcribing)
    }

    private func compactChangeButton(for target: ShortcutTarget) -> some View {
        Button {
            if recordingTarget == target {
                stopRecording()
            } else {
                startRecording(target)
            }
        } label: {
            Text(recordingTarget == target ? recordingPrompt(for: target) : "Change…")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.accent)
        }
        .buttonStyle(.plain)
    }



    private func reconcilePushToTalkState(
        permissions: OnboardingPermissionSnapshot? = nil
    ) {
        if let result = controller.reconcilePendingPushToTalkEnableIfReady(permissions: permissions) {
            switch result {
            case .alreadyEnabled, .enabled, .disabled:
                dictationShortcutMessage = nil
            case .needsPermissions:
                dictationShortcutMessage = pushToTalkPermissionMessage
            }
            return
        }

        guard isPushToTalkEnabled, let permissions else { return }
        let profile = PushToTalkEnablementPolicy.PermissionProfile.resolved(
            for: appState.config.resolvedOnboardingUseCase
        )
        if profile.hasRequiredPermissions(permissions) {
            if dictationShortcutMessage == profile.missingPermissionsMessage {
                dictationShortcutMessage = nil
            }
        } else if dictationShortcutMessage == nil
                    || dictationShortcutMessage == profile.missingPermissionsMessage {
            dictationShortcutMessage = profile.missingPermissionsMessage
        }
    }

    private func reconcileIndependentShortcutState() {
        let meetingMessage = controller.independentShortcutPermissionMessageIfNeeded(
            isEnabled: appState.config.enableMeetingRecordingHotkey)
        if let meetingMessage { meetingRecordingShortcutMessage = meetingMessage }
        else if meetingRecordingShortcutMessage == ShortcutFeatureEnablementPolicy.missingPermissionsMessage {
            meetingRecordingShortcutMessage = nil
        }
        let permissionMessage = ShortcutFeatureEnablementPolicy.missingPermissionsMessage
        let computerUsePermissionMessage = controller.independentShortcutPermissionMessageIfNeeded(
            isEnabled: appState.config.enableComputerUseHotkey
        )
        if let computerUsePermissionMessage {
            computerUseShortcutMessage = computerUsePermissionMessage
        } else if computerUseShortcutMessage == permissionMessage {
            computerUseShortcutMessage = nil
        }

        let quilPermissionMessage = controller.independentShortcutPermissionMessageIfNeeded(
            isEnabled: appState.config.enableQuilMode
        )
        if let quilPermissionMessage {
            quilShortcutMessage = quilPermissionMessage
        } else if quilShortcutMessage == permissionMessage {
            quilShortcutMessage = nil
        }
    }

    private func recordingPrompt(for target: ShortcutTarget) -> String {
        switch target {
        case .meetingRecording:
            return "Press a key or modifier..."
        case .quil:
            return "Press one key or a two-key shortcut..."
        case .dictation:
            return "Press a modifier or a shortcut..."
        case .computerUse:
            return "Press a modifier key..."
        }
    }

    private var doubleTapSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Hands-Free Mode")
                        .font(MuesliTheme.headline())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Double-tap dictation, Quill, or CUA to start; tap again to stop")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
                Spacer()
                MuesliSettingControl(controller: controller, id: "double_tap_dictation")
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
            controller.resetShortcutDefaults()
            dictationShortcutMessage = nil
            computerUseShortcutMessage = nil
            meetingRecordingShortcutMessage = nil
            quilShortcutMessage = nil
        } label: {
            Text("Reset to Defaults")
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(
            appState.config.dictationHotkey == .default
                && appState.config.dictationCombinationActivation == .pushToTalk
                && appState.config.computerUseHotkey == .computerUseDefault
                && !appState.config.enableComputerUseHotkey
                && appState.config.quilHotkey == .quilDefault
                && !appState.config.enableQuilMode
                && appState.config.meetingRecordingHotkey == .meetingRecordingDefault
                && !appState.config.enableMeetingRecordingHotkey
                && appState.config.hotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds
                && appState.config.computerUseHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds
                && appState.config.quilHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultThresholdMilliseconds
                && appState.config.meetingRecordingHotkeyTriggerThresholdMS == HotkeyTriggerTiming.defaultMeetingThresholdMilliseconds
        )
    }

    private func startRecording(_ target: ShortcutTarget) {
        stopRecording()
        clearShortcutMessage(for: target)
        let failure = recorder.start(
            target,
            acquire: { controller.beginShortcutCapture() },
            release: { controller.endShortcutCapture() },
            commit: { commitShortcut($0, for: target) }
        )
        if let failure {
            setShortcutMessage(failure, for: target)
        }
    }

    private func commitShortcut(_ config: HotkeyConfig, for target: ShortcutTarget) {
        Task { @MainActor in
            do {
                try await controller.applySetting(target.settingID, value: ShortcutAssignment.value(for: config))
                setShortcutMessage(ShortcutHotkeyPolicy.commonGlobalShortcutWarning(for: config), for: target)
            } catch {
                setShortcutMessage(error.localizedDescription, for: target)
            }
        }
    }

    private func clearShortcutMessage(for target: ShortcutTarget) {
        setShortcutMessage(nil, for: target)
    }

    private func setShortcutMessage(_ message: String?, for target: ShortcutTarget) {
        switch target {
        case .dictation:
            dictationShortcutMessage = message
            if message == nil { computerUseShortcutMessage = nil; meetingRecordingShortcutMessage = nil; quilShortcutMessage = nil }
        case .computerUse:
            computerUseShortcutMessage = message
            if message == nil { dictationShortcutMessage = nil; meetingRecordingShortcutMessage = nil; quilShortcutMessage = nil }
        case .quil:
            quilShortcutMessage = message
            if message == nil { dictationShortcutMessage = nil; computerUseShortcutMessage = nil; meetingRecordingShortcutMessage = nil }
        case .meetingRecording:
            meetingRecordingShortcutMessage = message
            if message == nil { dictationShortcutMessage = nil; computerUseShortcutMessage = nil; quilShortcutMessage = nil }
        }
    }

    private func stopRecording() {
        recorder.cancel()
    }
}
