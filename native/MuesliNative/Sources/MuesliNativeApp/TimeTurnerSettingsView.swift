import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import MuesliCore

/// Shared by the dashboard sheet and Experimental settings.
struct TimeTurnerSettingsView: View {
    let controller: MuesliController
    let appState: AppState
    @State private var setup = false
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var accessibility = AXIsProcessTrusted()
    private var memory: VisualMemoryController { controller.visualMemory }
    private var exclusions: [String] {
        appState.config.timeTurnerExcludedApps.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Label { Text("Time Turner") } icon: { Image(nsImage: TimeTurnerIcon.image()) }
                        .font(MuesliTheme.font(.title2).bold())
                    Text("Experimental")
                        .font(MuesliTheme.font(.caption).weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
                Text("Search and revisit your screen history. Stored on this Mac.").foregroundStyle(.secondary)
                HStack {
                    Label(appState.config.timeTurnerEnabled ? memory.ambientStatus : "Screen history is off", systemImage: appState.config.timeTurnerEnabled ? "record.circle" : "pause.circle")
                    Spacer()
                    if appState.config.timeTurnerEnabled {
                        Button("Turn off") { controller.setSettingFromUI("time_turner_enabled", value: "off") }
                    } else {
                        Button("Set up Time Turner") { setup = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            GroupBox("Capture") {
                VStack(spacing: 14) {
                    MuesliSettingControl(controller: controller, id: "time_turner_pause_on_inactivity")
                    Text("Pause after 1 minute without keyboard or mouse input. Resume when you return.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                    HStack { Text("Check screen every"); Spacer(); MuesliSettingControl(controller: controller, id: "time_turner_interval") }
                    HStack { Text("Storage budget"); Spacer(); MuesliSettingControl(controller: controller, id: "time_turner_budget") }
                    Text("Saves changed screens only. Pauses during lock, sleep and meeting screen recording.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(12)
            }
            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(screen ? "Screen Recording allowed" : "Screen Recording needed", systemImage: screen ? "checkmark.circle.fill" : "circle")
                    Label(accessibility ? "Accessibility allowed" : "Accessibility needed", systemImage: accessibility ? "checkmark.circle.fill" : "circle")
                    Text("Screen Recording saves images; Accessibility identifies the focused window.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                    if !screen || !accessibility { Button("Review permissions") { setup = true } }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Privacy & excluded apps") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Private windows and sensitive apps are skipped where detected. Pause before opening private content.").font(MuesliTheme.font(.callout)).foregroundStyle(.secondary)
                    ForEach(exclusions, id: \.self) { bundle in
                        HStack {
                            TargetApplicationIconView(appName: bundle, bundleIdentifier: bundle).accessibilityLabel(bundle)
                            Text(appName(bundle)).lineLimit(1)
                            Spacer()
                            Button("Remove") { saveExclusions(exclusions.filter { $0 != bundle }) }
                        }
                    }
                    Button("Exclude an app…") { chooseExcludedApp() }
                    Text("Built-in sensitive-app exclusions remain active in addition to this list.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Storage & retention") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Local media", value: ByteCountFormatter.string(fromByteCount: memory.usedBytes, countStyle: .file))
                    LabeledContent("Available disk space", value: ByteCountFormatter.string(fromByteCount: memory.freeBytes, countStyle: .file))
                    Text(estimate).font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                    Text("Keeps up to 7 days within your budget. Reserves 2 GB of free disk space.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                    if memory.incompleteMomentCount > 0 {
                        Text("\(memory.incompleteMomentCount) older incomplete captures are hidden from the viewer.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
                    }
                    if let message = memory.message { Text(message).font(MuesliTheme.font(.caption)).foregroundStyle(.orange) }
                }.padding(12)
            }

        }
        .environment(\.muesliSettingDefinitions, controller.settingsDefinitions())
        .onAppear { refresh(); consumeSetupRequest() }
        .onChange(of: appState.requestsTimeTurnerSetup) { _, _ in consumeSetupRequest() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .sheet(isPresented: $setup, onDismiss: refresh) { TimeTurnerSetupView(controller: controller, appState: appState) }
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
        let images = memory.items.filter { $0.kind == .moment && $0.frameIndex == nil }
        guard !images.isEmpty else { return "Daily storage estimate appears after your first captures." }
        let average = images.reduce(Int64(0)) { $0 + $1.bytes } / Int64(images.count)
        let interval = max(2, Int64(appState.config.timeTurnerInterval) ?? 10)
        let size = ByteCountFormatter.string(fromByteCount: average * 28_800 / interval, countStyle: .file)
        return "Up to \(size) per 8 active hours before compression, estimated from recent captures."
    }
}

struct TimeTurnerSetupView: View {
    let controller: MuesliController
    let appState: AppState
    @Environment(\.dismiss) private var dismiss
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
                HStack { Text("Check screen every"); Spacer(); MuesliSettingControl(controller: controller, id: "time_turner_interval") }
                HStack { Text("Storage budget"); Spacer(); MuesliSettingControl(controller: controller, id: "time_turner_budget") }
                Text("Changed screens and recognized text stay on this Mac. History is kept for up to seven days, within your budget. You can adjust exclusions and storage in Settings → Time Turner.").foregroundStyle(.secondary)
                Text("Private-content detection is not exhaustive. Pause before opening sensitive content. Local agents can read saved history when you give them access.").font(MuesliTheme.font(.caption)).foregroundStyle(.secondary)
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
        .environment(\.muesliSettingDefinitions, controller.settingsDefinitions())
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
