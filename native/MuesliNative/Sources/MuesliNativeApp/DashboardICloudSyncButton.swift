import SwiftUI

/// Shared dashboard heading for surfaces that display CloudKit-backed history.
struct DashboardPageHeader: View {
    let title: String
    let appState: AppState
    let controller: MuesliController

    var body: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            PageTitle(title)

            DashboardICloudSyncButton(
                isEnabled: appState.config.iCloudSyncEnabled,
                isSyncing: appState.isICloudSyncInProgress,
                hasError: appState.iCloudBridgeState == .error,
                onSync: { controller.performICloudSync() },
                onSetUp: {
                    appState.selectedSettingsPane = .sync
                    controller.openSettingsTab()
                }
            )
        }
    }
}

struct DashboardICloudSyncButton: View {
    let isEnabled: Bool
    let isSyncing: Bool
    let hasError: Bool
    let onSync: () -> Void
    let onSetUp: () -> Void

    private var tint: Color {
        if hasError {
            return MuesliTheme.transcribing
        }
        if isEnabled {
            return MuesliTheme.accent
        }
        return MuesliTheme.textTertiary
    }

    private var label: String {
        if isSyncing {
            return "Syncing with iCloud"
        }
        if hasError {
            return "Retry iCloud sync"
        }
        if isEnabled {
            return "Sync now"
        }
        return "Set up iCloud sync"
    }

    var body: some View {
        Button {
            if isEnabled {
                onSync()
            } else {
                onSetUp()
            }
        } label: {
            ZStack {
                Image(systemName: hasError ? "icloud.slash" : "icloud")
                    .font(.system(size: 20, weight: .semibold))

                RotatingSyncIcon(
                    systemName: "arrow.triangle.2.circlepath",
                    isAnimating: isSyncing,
                    font: .system(size: 8, weight: .bold)
                )
                    .offset(y: 1)
                    .opacity(hasError ? 0 : 1)
            }
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(Circle())
            .overlay {
                Circle()
                    .strokeBorder(tint.opacity(isEnabled || hasError ? 0.28 : 0.14), lineWidth: 1)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isSyncing)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityHint("Sync text with your iPhone or iPad through private iCloud.")
    }
}

struct RotatingSyncIcon: View {
    let systemName: String
    let isAnimating: Bool
    let font: Font
    @State private var rotationDegrees = 0.0

    var body: some View {
        Image(systemName: systemName)
            .font(font)
            .symbolRenderingMode(.hierarchical)
            .rotationEffect(.degrees(rotationDegrees))
            .onAppear { updateRotation(animated: false) }
            .onChange(of: isAnimating) { _, _ in updateRotation(animated: true) }
    }

    private func updateRotation(animated: Bool) {
        guard isAnimating else {
            if animated {
                withAnimation(.easeOut(duration: 0.15)) { rotationDegrees = 0 }
            } else {
                rotationDegrees = 0
            }
            return
        }

        rotationDegrees = 0
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
            rotationDegrees = 360
        }
    }
}
