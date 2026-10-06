import AppKit
import EventKit
import Observation
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

/// Shared by onboarding, Meetings, and the General permissions row. Refresh only
/// at lifecycle boundaries or after a user request; reading status never prompts.
@MainActor
@Observable
final class CalendarPermissionState {
    private(set) var status: EKAuthorizationStatus
    private(set) var requesting = false
    private(set) var errorMessage: String?
    private let readStatus: () -> EKAuthorizationStatus
    private let requestFullAccess: () async throws -> Bool

    init(
        readStatus: @escaping () -> EKAuthorizationStatus = {
            EKEventStore.authorizationStatus(for: .event)
        },
        requestFullAccess: @escaping () async throws -> Bool = {
            try await EKEventStore().requestFullAccessToEvents()
        }
    ) {
        self.readStatus = readStatus
        self.requestFullAccess = requestFullAccess
        status = readStatus()
    }

    var granted: Bool { status == .fullAccess || status == .authorized }
    var canRequest: Bool { status == .notDetermined }

    func refresh() {
        status = readStatus()
        if granted { errorMessage = nil }
    }

    func requestAccess() async {
        refresh()
        guard canRequest, !requesting else { return }
        requesting = true
        errorMessage = nil
        defer {
            refresh()
            requesting = false
        }
        do {
            _ = try await requestFullAccess()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Distinguishes an empty result from a read that has not completed yet.
/// Track overlapping Settings refreshes so one completion cannot hide another.
struct CalendarSourceRefreshState {
    private(set) var pendingCount = 0
    private(set) var hasLoaded = false

    var isLoading: Bool { !hasLoaded || pendingCount > 0 }
    var needsInitialRefresh: Bool { !hasLoaded && pendingCount == 0 }

    mutating func begin() { pendingCount += 1 }

    mutating func finish(completed: Bool) {
        precondition(pendingCount > 0)
        pendingCount -= 1
        if completed { hasLoaded = true }
    }
}

struct CalendarAccessControl: View {
    // Settings owns activation refreshes for the whole pane, including existing calendars.
    // Onboarding uses this control's handler because it has no equivalent parent refresh.
    var refreshOnActivation = true
    var onGranted: () async -> Void
    @State private var permission = CalendarPermissionState()

    var body: some View {
        VStack(spacing: 8) {
            if permission.granted {
                Label("Calendar access allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(MuesliTheme.success)
            } else {
                Button(permission.requesting ? "Requesting access…" : (permission.canRequest ? "Allow Calendar Access" : "Open Calendar Privacy Settings…")) {
                    permission.refresh()
                    guard permission.canRequest else {
                        CalendarIntegration.openPrivacy()
                        return
                    }
                    Task { @MainActor in
                        await permission.requestAccess()
                        if permission.granted { await onGranted() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(permission.requesting)
                if !permission.canRequest {
                    Text("Allow Muesli full Calendar access in Privacy & Security to show your meetings.")
                        .font(.caption)
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }
            if let errorMessage = permission.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(MuesliTheme.recording)
            }
        }
        .onAppear { permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission.refresh()
            if permission.granted && refreshOnActivation && !permission.requesting { Task { await onGranted() } }
        }
    }
}
