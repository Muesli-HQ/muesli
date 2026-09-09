import AppKit
import EventKit
import SwiftUI

/// Calendar accounts remain owned by macOS; Muesli only selects which calendars to use.
@MainActor
enum CalendarIntegration {
    static let calendarIcon: NSImage = {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal")
        return NSWorkspace.shared.icon(forFile: url?.path ?? "/System/Applications/Calendar.app")
    }()

    static func openAccounts() {
        openSettings("com.apple.Internet-Accounts-Settings.extension")
    }

    static func openPrivacy() {
        openSettings("com.apple.preference.security?Privacy_Calendars")
    }

    private static func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:\(pane)") else { return }
        if !NSWorkspace.shared.open(url),
           let fallback = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") {
            NSWorkspace.shared.open(fallback)
        }
    }

    static func openCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.open(url)
    }
}

struct CalendarAccessControl: View {
    var onGranted: () async -> Void
    @State private var status = EKEventStore.authorizationStatus(for: .event)
    @State private var requesting = false
    @State private var errorMessage: String?

    private var granted: Bool { status == .fullAccess || status == .authorized }

    var body: some View {
        VStack(spacing: 8) {
            if granted {
                Label("Calendar access allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(MuesliTheme.success)
            } else {
                Button(requesting ? "Requesting access…" : (status == .notDetermined ? "Allow Calendar Access" : "Open Calendar Privacy Settings…")) {
                    guard status == .notDetermined else {
                        CalendarIntegration.openPrivacy()
                        return
                    }
                    requesting = true
                    errorMessage = nil
                    Task { @MainActor in
                        do {
                            let store = EKEventStore()
                            _ = try await store.requestFullAccessToEvents()
                            status = EKEventStore.authorizationStatus(for: .event)
                            if granted { await onGranted() }
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                        requesting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(requesting)
                if status != .notDetermined {
                    Text("Allow Muesli full Calendar access in Privacy & Security to show your meetings.")
                        .font(.caption)
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(MuesliTheme.recording)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = EKEventStore.authorizationStatus(for: .event)
            if granted { Task { await onGranted() } }
        }
    }
}
