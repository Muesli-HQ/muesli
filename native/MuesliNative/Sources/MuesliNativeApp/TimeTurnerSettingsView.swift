import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import MuesliCore

/// Shared by the dashboard sheet and Experimental settings.
struct TimeTurnerSettingsView: View {
    let controller: MuesliController
    let appState: AppState
    @State private var presentationCatalog = SettingsPresentationCatalog()
    @State private var exclusionNames: [String: String] = [:]
    @State private var setup = false
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var accessibility = AXIsProcessTrusted()
    private var memory: VisualMemoryController { controller.visualMemory }
    private var exclusions: [String] {
        appState.config.timeTurnerExcludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
            section("Time Turner", icon: TimeTurnerIcon.image()) {
                SettingsRow(label: "Screen history", description: "Searchable snapshots stored on this Mac.", controlWidth: nil) {
                    if appState.config.timeTurnerEnabled {
                        MuesliSettingControl(controller: controller, id: "time_turner_enabled")
                    } else {
                        Button("Set up…") { setup = true }
                    }
                }
                if appState.config.timeTurnerEnabled && (!screen || !accessibility) {
                    SettingsRow(label: "Capture needs permission", controlWidth: nil) {
                        Button("Review access…") { setup = true }
                    }
                }
                subsection("Capture")
                SettingsRow(label: "Pause on inactivity", description: "Pause after 1 minute without keyboard or mouse input. Resume when you return.", controlWidth: nil) {
                    MuesliSettingControl(controller: controller, id: "time_turner_pause_on_inactivity")
                }
                SettingsRow(label: "Check screen every") {
                    MuesliSettingControl(controller: controller, id: "time_turner_interval")
                }
                SettingsNote("Saves changed screens only. Automatically resumes after lock or sleep; pauses during meeting screen recording.")
                    .padding(.top, MuesliTheme.spacing8)
                subsection("Excluded apps")
                SettingsRow(label: "App exclusions", controlWidth: nil) {
                    Button("Add app…") { chooseExcludedApp() }
                }
                ForEach(exclusions, id: \.self) { bundle in
                    HStack(spacing: MuesliTheme.spacing8) {
                        TargetApplicationIconView(appName: bundle, bundleIdentifier: bundle).accessibilityLabel(bundle)
                        Text(exclusionNames[bundle] ?? bundle).font(MuesliTheme.body()).lineLimit(1)
                        Spacer()
                        Button("Remove") { saveExclusions(exclusions.filter { $0 != bundle }) }
                            .accessibilityLabel("Remove \(exclusionNames[bundle] ?? bundle) exclusion")
                    }
                    .padding(.vertical, MuesliTheme.spacing4)
                }
                SettingsNote("Sensitive apps and private windows are skipped where detected. Pause before opening private content.")
                    .padding(.top, MuesliTheme.spacing8)
                subsection("Storage & retention")
                SettingsRow(label: "Keep screenshots for") {
                    MuesliSettingControl(controller: controller, id: "time_turner_screenshot_retention")
                }
                SettingsRow(label: "Keep searchable history for") {
                    MuesliSettingControl(controller: controller, id: "time_turner_history_retention")
                }
                SettingsRow(label: "Screenshot storage budget") {
                    MuesliSettingControl(controller: controller, id: "time_turner_budget")
                }
                SettingsRow(label: "Screenshot storage", controlWidth: nil) {
                    Text(ByteCountFormatter.string(fromByteCount: memory.usedBytes, countStyle: .file))
                        .font(MuesliTheme.body()).foregroundStyle(MuesliTheme.textSecondary)
                }
                SettingsRow(label: "Available disk space", controlWidth: nil) {
                    Text(ByteCountFormatter.string(fromByteCount: memory.freeBytes, countStyle: .file))
                        .font(MuesliTheme.body()).foregroundStyle(MuesliTheme.textSecondary)
                }
                SettingsNote(estimate).padding(.top, MuesliTheme.spacing8)
                DisclosureGroup("How retention works") {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                        SettingsNote("Screenshots expire sooner if the budget fills. Searchable text uses separate storage.")
                        SettingsNote("Retention starts at capture, even while paused or off. Shorter limits apply to existing history.")
                        SettingsNote("Deleting history also deletes its screenshots and recaps.")
                    }
                    .padding(.top, MuesliTheme.spacing8)
                }
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .padding(.top, MuesliTheme.spacing8)
                if let message = memory.message {
                    SettingsNote(message, tone: .warning).padding(.top, MuesliTheme.spacing8)
                }
            }
        }
        .environment(\.muesliSettingDefinitions, presentationCatalog.definitions(for: controller))
        .task(id: exclusions) {
            exclusionNames = Dictionary(exclusions.map { ($0, appName($0)) }, uniquingKeysWith: { first, _ in first })
        }
        .onAppear { refresh(); consumeSetupRequest() }
        .onChange(of: appState.requestsTimeTurnerSetup) { _, _ in consumeSetupRequest() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .sheet(isPresented: $setup, onDismiss: refresh) { TimeTurnerSetupView(controller: controller, appState: appState) }
    }

    private func subsection(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            Divider()
            Text(title)
                .font(MuesliTheme.captionMedium())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(.top, MuesliTheme.spacing16)
        .padding(.bottom, MuesliTheme.spacing8)
    }

    private func section(_ title: String, icon: NSImage? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            SettingsSectionHeading(title: title, icon: icon)
            VStack(alignment: .leading, spacing: 0, content: content)
                .padding(MuesliTheme.spacing16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
                .overlay {
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
    private func consumeSetupRequest() {
        guard appState.requestsTimeTurnerSetup else { return }
        appState.requestsTimeTurnerSetup = false
        setup = true
    }
    private func refresh() { screen = CGPreflightScreenCaptureAccess(); accessibility = AXIsProcessTrusted(); memory.updateSpace() }
    private func appName(_ bundle: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return bundle }
        return url.deletingPathExtension().lastPathComponent
    }
    private func saveExclusions(_ bundles: [String]) { controller.updateConfig { $0.timeTurnerExcludedApps = bundles.joined(separator: ",") } }
    private func chooseExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        let selected = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
        saveExclusions(Array(Set(exclusions + selected)).sorted())
    }
    private var estimate: String {
        let images = memory.items.filter { $0.kind == .moment && $0.frameIndex == nil && $0.mediaDeletedAt == nil }
        guard !images.isEmpty else { return "Storage estimate available after capture." }
        let average = images.reduce(Int64(0)) { $0 + $1.bytes } / Int64(images.count)
        let interval = max(2, Int64(appState.config.timeTurnerInterval) ?? 10)
        let size = ByteCountFormatter.string(fromByteCount: average * 28_800 / interval, countStyle: .file)
        return "Estimated \(size) per 8 active hours, before compression."
    }
}

struct TimeTurnerSetupView: View {
    let controller: MuesliController
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var presentationCatalog = SettingsPresentationCatalog()
    @State private var step = 0
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var accessibility = AXIsProcessTrusted()
    @State private var enabling = false
    @State private var error: String?
    private var ready: Bool { screen && accessibility }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label { Text("Time Turner") } icon: { Image(nsImage: TimeTurnerIcon.image()) }.font(MuesliTheme.font(.title2).bold())
                Spacer()
                Text("\(step + 1) of 3").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(step + 1), total: 3)
            if step == 0 {
                Text("Your first turn through time").font(MuesliTheme.font(.largeTitle).bold())
                Text("Find the page, conversation or idea you saw earlier—without remembering where it was.").font(MuesliTheme.font(.title3)).foregroundStyle(.secondary)
                Label("Snapshots of your focused window, with searchable text", systemImage: "macwindow")
                Label("Stored on this Mac, with a storage limit", systemImage: "internaldrive")
                Label("Pause anytime and choose apps to exclude", systemImage: "hand.raised")
                Text("This enables ongoing screen history, separate from dictation context or meeting recordings. Nothing is captured until you choose Start Time Turner.").font(MuesliTheme.font(.callout)).foregroundStyle(.secondary)
            } else if step == 1 {
                Text(ready ? "You're already set" : "A couple of permissions").font(MuesliTheme.font(.title).bold())
                Text(ready ? "Muesli already has the permissions Time Turner needs. No need to grant them again." : "Allow the missing permissions below, then return here. We'll check again automatically.").foregroundStyle(.secondary)
                permissionRow("Screen Recording", detail: "Save an image of the focused window.", granted: screen) {
                    if !CGRequestScreenCaptureAccess() { openPrivacy("Privacy_ScreenCapture") }
                    refresh()
                }
                permissionRow("Accessibility", detail: "Identify the focused window and help detect secure fields.", granted: accessibility) {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                    if !AXIsProcessTrustedWithOptions(options) { openPrivacy("Privacy_Accessibility") }
                    refresh()
                }
                Text("If macOS asks you to quit and reopen Muesli, do that, then return to setup. Your choices are saved. OCR needs no separate permission.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                Button("Check again", action: refresh)
            } else {
                Text("Make room for your day").font(MuesliTheme.font(.title).bold())
                VStack(spacing: MuesliTheme.spacing8) {
                    SettingsRow(label: "Check screen every") {
                        MuesliSettingControl(controller: controller, id: "time_turner_interval")
                    }
                    SettingsRow(label: "Screenshot storage budget") {
                        MuesliSettingControl(controller: controller, id: "time_turner_budget")
                    }
                    SettingsRow(label: "Keep screenshots for") {
                        MuesliSettingControl(controller: controller, id: "time_turner_screenshot_retention")
                    }
                    SettingsRow(label: "Keep searchable history for") {
                        MuesliSettingControl(controller: controller, id: "time_turner_history_retention")
                    }
                }
                SettingsNote("Searchable text can outlive screenshots. Retention continues while paused.")
                SettingsNote("Pause before viewing sensitive content. Agents you authorize can read saved history.")
                if !ready { Text("A required permission is missing. Go back to review permissions.").foregroundStyle(.orange) }
            }
            if let error { Text(error).font(MuesliTheme.font(.caption)).foregroundStyle(.red) }
            Spacer(minLength: 0)
            HStack {
                Button("Not now") { dismiss() }.keyboardShortcut(.cancelAction)
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 2 {
                    Button("Continue") { refresh(); step += 1 }.buttonStyle(.borderedProminent).disabled(step == 1 && !ready)
                } else {
                    Button(appState.config.timeTurnerEnabled ? "Finish" : "Start Time Turner") { enable() }
                        .buttonStyle(.borderedProminent).disabled(!ready || enabling)
                }
            }
        }.padding(28).frame(width: 560, height: 490)
        .environment(\.muesliSettingDefinitions, presentationCatalog.definitions(for: controller))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }
    private func refresh() { screen = CGPreflightScreenCaptureAccess(); accessibility = AXIsProcessTrusted() }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    private func permissionRow(_ title: String, detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading) { Text(title).bold(); Text(detail).font(MuesliTheme.font(.caption)).foregroundStyle(.secondary) }
            Spacer()
            if granted { Text("Allowed").font(MuesliTheme.font(.caption)) } else { Button("Allow…", action: request) }
        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
    private func enable() {
        refresh(); guard ready else { step = 1; return }
        enabling = true
        Task { @MainActor in
            defer { enabling = false }
            do {
                try await controller.applySetting("time_turner_enabled", value: "on")
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
