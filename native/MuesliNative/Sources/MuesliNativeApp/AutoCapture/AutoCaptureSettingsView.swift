import SwiftUI

// MARK: - AutoCaptureSettingsView

/// Settings pane for Auto-Capture v0. Master toggle defaults to off; the rest
/// of the controls are disabled while the master toggle is off so the pane
/// communicates a single clear opt-in step.
struct AutoCaptureSettingsView: View {

    let appState: AppState
    let controller: MuesliController

    private static let controlWidth: CGFloat = 275

    private var config: AutoCaptureConfig {
        appState.config.autoCapture
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            masterSection
            behaviourSection
            allowedAppsSection
            footerNotes
        }
    }

    // MARK: Master toggle

    private var masterSection: some View {
        sectionContainer("Auto-Capture") {
            settingsRow("Automatically start recordings") {
                Toggle("", isOn: Binding(
                    get: { config.enabled },
                    set: { newValue in update { $0.enabled = newValue } }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
            }
            Divider().background(MuesliTheme.surfaceBorder)
            descriptionText(
                "When Muesli detects a meeting in one of the apps below, recording starts after the configured delay. The first detection from each app asks for permission."
            )
        }
    }

    // MARK: Behaviour

    private var behaviourSection: some View {
        sectionContainer("Behaviour") {
            settingsRow("Start delay") {
                HStack(spacing: 12) {
                    Slider(
                        value: Binding(
                            get: { config.startDelaySeconds },
                            set: { newValue in
                                update { $0.startDelaySeconds = AutoCaptureConfig.clampedStartDelay(newValue) }
                            }
                        ),
                        in: AutoCaptureConfig.minStartDelaySeconds...AutoCaptureConfig.maxStartDelaySeconds,
                        step: 1
                    )
                    .disabled(!config.enabled)
                    Text("\(Int(config.startDelaySeconds))s")
                        .font(MuesliTheme.body())
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Require calendar match") {
                Toggle("", isOn: Binding(
                    get: { config.requireCalendarMatch },
                    set: { newValue in update { $0.requireCalendarMatch = newValue } }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
                .disabled(!config.enabled)
            }
            Divider().background(MuesliTheme.surfaceBorder)
            settingsRow("Pause during Focus / Do Not Disturb") {
                Toggle("", isOn: Binding(
                    get: { config.disableDuringFocus },
                    set: { newValue in update { $0.disableDuringFocus = newValue } }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
                .disabled(!config.enabled)
            }
        }
    }

    // MARK: Per-app list

    private var allowedAppsSection: some View {
        sectionContainer("Apps") {
            descriptionText("Auto-capture only runs for the apps you allow here.")
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
            ], alignment: .leading, spacing: 8) {
                ForEach(AutoCaptureAppCatalog.options) { option in
                    appToggleButton(option)
                }
            }
            .padding(.top, 4)
        }
    }

    private func appToggleButton(_ option: AutoCaptureAppCatalog.Option) -> some View {
        let enabled = config.allowedAppBundleIDs.contains(option.bundleID)
        return Button {
            update { current in
                if current.allowedAppBundleIDs.contains(option.bundleID) {
                    current.allowedAppBundleIDs.remove(option.bundleID)
                } else {
                    current.allowedAppBundleIDs.insert(option.bundleID)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: enabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(enabled ? MuesliTheme.accent : MuesliTheme.textTertiary)
                    .frame(width: 16)
                Image(systemName: option.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 14)
                Text(option.name)
                    .font(.system(size: 12))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(MuesliTheme.backgroundBase)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .disabled(!config.enabled)
    }

    private var footerNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Auto-capture is local-only. It calls the same start-recording path you use manually; no audio leaves this Mac for detection.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            if !config.acknowledgedAppBundleIDs.isEmpty {
                Text("Acknowledged apps: \(config.acknowledgedAppBundleIDs.sorted().joined(separator: ", "))")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                Button("Reset first-run prompts") {
                    update { $0.acknowledgedAppBundleIDs.removeAll() }
                }
                .buttonStyle(.link)
                .font(MuesliTheme.caption())
                .disabled(!config.enabled)
            }
        }
        .padding(.horizontal, MuesliTheme.spacing16)
    }

    // MARK: Layout helpers

    private func sectionContainer<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
                .textCase(.uppercase)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(MuesliTheme.spacing16)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    private func settingsRow<Control: View>(
        _ label: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
                .layoutPriority(1)
            Spacer(minLength: 20)
            ZStack(alignment: .trailing) {
                Color.clear.frame(width: Self.controlWidth, height: 1)
                control()
                    .frame(maxWidth: Self.controlWidth)
            }
        }
        .frame(minHeight: 32)
    }

    private func descriptionText(_ text: String) -> some View {
        Text(text)
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textTertiary)
            .padding(.top, 4)
    }

    // MARK: Mutation

    private func update(_ mutate: (inout AutoCaptureConfig) -> Void) {
        controller.updateConfig { config in
            var next = config.autoCapture
            mutate(&next)
            config.autoCapture = next
        }
    }
}

// MARK: - AutoCaptureAppCatalog

/// Static catalog of apps surfaced in the Auto-Capture per-app list. Mirrors
/// the bundle IDs that `MeetingDetector` recognises today. Kept local to the
/// AutoCapture module so adding a row here cannot accidentally change
/// detection behaviour.
enum AutoCaptureAppCatalog {
    struct Option: Identifiable {
        let bundleID: String
        let name: String
        let icon: String

        var id: String { bundleID }
    }

    static let options: [Option] = [
        Option(bundleID: "us.zoom.xos", name: "Zoom", icon: "video.fill"),
        Option(bundleID: "com.microsoft.teams2", name: "Teams", icon: "person.2.fill"),
        Option(bundleID: "com.apple.FaceTime", name: "FaceTime", icon: "video.fill"),
        Option(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", icon: "message.fill"),
        Option(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", icon: "phone.fill"),
        Option(bundleID: "com.webex.meetingmanager", name: "Webex", icon: "video.fill"),
        Option(bundleID: "com.google.Chrome", name: "Chrome", icon: "globe"),
        Option(bundleID: "company.thebrowser.Browser", name: "Arc", icon: "globe"),
        Option(bundleID: "com.apple.Safari", name: "Safari", icon: "globe"),
        Option(bundleID: "com.microsoft.edgemac", name: "Edge", icon: "globe"),
        Option(bundleID: "com.brave.Browser", name: "Brave", icon: "globe"),
    ]
}
