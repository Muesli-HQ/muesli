import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TelemetryDeck

enum ICloudBridgeWorkingCopy {
    static func title(isActivationPending: Bool) -> String {
        isActivationPending
            ? "Setting up sync"
            : "Syncing"
    }

    static func subtitle(isActivationPending: Bool) -> String {
        isActivationPending
            ? "Connecting to iCloud…"
            : "Uploading and downloading changes…"
    }

    static func buttonHelp(isActivationPending: Bool) -> String {
        isActivationPending
            ? "Sync setup is in progress"
            : "Text sync is in progress"
    }
}

enum ICloudSyncEnableAction: Equatable {
    case beginActivation
    case performSync
    case ignore
}

enum ICloudSyncActivationPolicy {
    static func action(isEnabled: Bool, isActivationPending: Bool) -> ICloudSyncEnableAction {
        if isActivationPending {
            return .ignore
        }
        return isEnabled ? .performSync : .beginActivation
    }
}

enum ICloudSyncRecoveryAction: Equatable {
    case reconnectLegacyLibrary
    case resetAccountLink
}

enum ICloudSyncRecoveryPolicy {
    static func action(
        for state: ICloudBridgeState,
        supportsLegacyReconnect: Bool = MuesliICloudSyncEngine.cloudKitEnvironmentKeyComponent == "production"
    ) -> ICloudSyncRecoveryAction? {
        switch state {
        case .needsReconnection:
            return supportsLegacyReconnect ? .reconnectLegacyLibrary : .resetAccountLink
        case .needsAccountReplacement:
            return .resetAccountLink
        default:
            return nil
        }
    }
}

enum ICloudSyncFlowAction: Equatable {
    case setUp
    case continueSetup
    case connectDevice
    case waitingForDevice
    case syncNow
    case reconnect
    case reset
    case retry
    case working
}

enum ICloudSyncFlowPolicy {
    static func action(
        for state: ICloudBridgeState,
        isEnabled: Bool,
        hasCompanionDevice: Bool,
        companionDiscoveryState: ICloudBridgeCompanionDiscoveryState = .idle
    ) -> ICloudSyncFlowAction {
        switch ICloudSyncRecoveryPolicy.action(for: state) {
        case .reconnectLegacyLibrary:
            return .reconnect
        case .resetAccountLink:
            return .reset
        case nil:
            break
        }

        switch state {
        case .checkingICloud, .syncing:
            return .working
        case .notConfigured:
            return .setUp
        case .active:
            guard isEnabled else { return .setUp }
            if hasCompanionDevice { return .syncNow }
            return companionDiscoveryState == .waiting ? .waitingForDevice : .connectDevice
        case .needsICloud:
            return .retry
        case .error:
            return hasCompanionDevice ? .retry : .continueSetup
        case .needsReconnection, .needsAccountReplacement:
            return .reset
        }
    }
}

enum ICloudBridgeActivationSyncAction: Equatable {
    case waitForCompanion
    case startSync
}

enum ICloudBridgeActivationSyncPolicy {
    static func action(
        isActivationPending: Bool,
        hasCompanionDevice: Bool
    ) -> ICloudBridgeActivationSyncAction {
        isActivationPending && !hasCompanionDevice
            ? .waitForCompanion
            : .startSync
    }

    static func shouldStartAfterCompanionDiscovery(
        foundCompanion: Bool,
        previousDiscoveryState: ICloudBridgeCompanionDiscoveryState,
        isActivationPending: Bool,
        isSyncEnabled: Bool
    ) -> Bool {
        foundCompanion
            && previousDiscoveryState == .waiting
            && isActivationPending
            && isSyncEnabled
    }
}

enum ICloudSyncQRCodePresentationPhase: Equatable {
    case hidden
    case readyToScan
    case syncing
    case dismiss
}

enum ICloudSyncQRCodePresentationPolicy {
    static func phase(
        isPresented: Bool,
        hasCompanionDevice: Bool,
        isSyncInProgress: Bool
    ) -> ICloudSyncQRCodePresentationPhase {
        guard isPresented else { return .hidden }
        guard hasCompanionDevice else { return .readyToScan }
        return isSyncInProgress ? .syncing : .dismiss
    }
}

struct IPhoneBridgeCard: View {
    let appState: AppState
    let controller: MuesliController

    @State private var promptSeen = false
    @State private var isQRCodePresented = false
    @State private var isReconnectConfirmationPresented = false
    @State private var isResetConfirmationPresented = false

    var body: some View {
        HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
            RotatingSyncIcon(
                systemName: bridgeIcon,
                isAnimating: bridgeSyncIconIsAnimating,
                font: .system(size: 18, weight: .semibold)
            )
            .foregroundStyle(bridgeIconColor)
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(bridgeTitle)
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(bridgeSubtitle)
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: MuesliTheme.spacing12)

            Button(action: primaryAction) {
                HStack(spacing: 6) {
                    Text(buttonTitle)
                    RotatingSyncIcon(
                        systemName: buttonIcon,
                        isAnimating: buttonIconIsAnimating,
                        font: .system(size: 12, weight: .semibold)
                    )
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(MuesliTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .disabled(actionDisabled)
            .help(buttonHelp)

            Button {
                controller.updateConfig { $0.showIOSCompanionPrompt = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .frame(width: 28, height: 28)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            }
            .buttonStyle(.plain)
            .help("Hide iOS companion prompt")
        }
        .padding(MuesliTheme.spacing12)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .onAppear {
            guard !promptSeen else { return }
            promptSeen = true
            TelemetryDeck.signal("bridge_prompt_seen", parameters: ["platform": "macos"])
        }
        .sheet(isPresented: $isQRCodePresented, onDismiss: {
            controller.cancelIPhoneBridgeDeviceDiscovery()
        }) {
            IPhoneBridgeQRCodeSheet(
                deepLinkURL: IPhoneBridgeLinks.iOSSyncDeepLinkURL,
                installURL: IPhoneBridgeLinks.installURL,
                isWaitingForDevice: appState.iCloudBridgeCompanionDiscoveryState == .waiting,
                presentationPhase: qrCodePresentationPhase
            )
        }
        .onChange(of: qrCodePresentationPhase) { _, phase in
            guard phase == .dismiss else { return }
            isQRCodePresented = false
            TelemetryDeck.signal("bridge_qr_auto_dismissed", parameters: ["platform": "macos_timeline"])
        }
        .alert("Reconnect iCloud sync?", isPresented: $isReconnectConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Reconnect iCloud sync") {
                controller.reconnectICloudSyncToCurrentAccount()
            }
        } message: {
            Text("Muesli will reconnect this Mac to the currently signed-in iCloud account and resync eligible text. Local history and audio stay on this Mac.")
        }
        .alert("Reset iCloud sync?", isPresented: $isResetConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Reset iCloud sync", role: .destructive) {
                controller.resetICloudSync()
            }
        } message: {
            Text("Muesli will turn off sync and clear this Mac's local iCloud sync state. Local history and audio stay on this Mac, and CloudKit data is not deleted. Turn sync on afterward to set up the currently signed-in iCloud account.")
        }
    }

    private var bridgeState: ICloudBridgeState {
        appState.iCloudBridgeState
    }

    private var qrCodePresentationPhase: ICloudSyncQRCodePresentationPhase {
        ICloudSyncQRCodePresentationPolicy.phase(
            isPresented: isQRCodePresented,
            hasCompanionDevice: appState.iCloudBridgeCompanionDeviceName != nil,
            isSyncInProgress: appState.isICloudSyncInProgress
                || appState.isICloudBridgeActivationPending
        )
    }

    private var flowAction: ICloudSyncFlowAction {
        ICloudSyncFlowPolicy.action(
            for: bridgeState,
            isEnabled: appState.config.iCloudSyncEnabled,
            hasCompanionDevice: appState.iCloudBridgeCompanionDeviceName != nil,
            companionDiscoveryState: appState.iCloudBridgeCompanionDiscoveryState
        )
    }

    private var bridgeSyncIconIsAnimating: Bool {
        isSyncWorking && bridgeIcon == "arrow.triangle.2.circlepath"
    }

    private var buttonIconIsAnimating: Bool {
        isSyncWorking && buttonIcon == "arrow.triangle.2.circlepath"
    }

    private var isSyncWorking: Bool {
        bridgeState == .checkingICloud
            || bridgeState == .syncing
            || flowAction == .waitingForDevice
    }

    private var bridgeIcon: String {
        if flowAction == .waitingForDevice {
            return "arrow.triangle.2.circlepath"
        }
        switch bridgeState {
        case .active: return "checkmark.icloud"
        case .checkingICloud, .syncing: return "arrow.triangle.2.circlepath"
        case .needsICloud, .needsReconnection, .needsAccountReplacement, .error:
            return "exclamationmark.icloud"
        case .notConfigured: return "iphone.gen3"
        }
    }

    private var bridgeIconColor: Color {
        switch bridgeState {
        case .active: return MuesliTheme.success
        case .needsICloud, .needsReconnection, .needsAccountReplacement, .error:
            return MuesliTheme.transcribing
        default: return MuesliTheme.accent
        }
    }

    private var bridgeTitle: String {
        switch bridgeState {
        case .active:
            guard let deviceName = appState.iCloudBridgeCompanionDeviceName else {
                if appState.iCloudBridgeCompanionDiscoveryState == .waiting {
                    return "Finishing device setup"
                }
                if let lastSyncedAt = appState.iCloudLastSyncedAt {
                    return "iCloud sync active · \(relativeSyncTime(lastSyncedAt))"
                }
                return "iCloud sync active"
            }
            if let lastSyncedAt = appState.iCloudLastSyncedAt {
                return "Synced with \(deviceName) · \(relativeSyncTime(lastSyncedAt))"
            }
            return "Synced with \(deviceName)"
        case .checkingICloud:
            return "Setting up sync"
        case .syncing:
            return ICloudBridgeWorkingCopy.title(
                isActivationPending: appState.isICloudBridgeActivationPending
            )
        case .needsICloud:
            return "Sign in to iCloud"
        case .needsReconnection:
            switch ICloudSyncRecoveryPolicy.action(for: bridgeState) {
            case .reconnectLegacyLibrary:
                return "Reconnect iCloud sync"
            case .resetAccountLink:
                return "Reset iCloud sync"
            case nil:
                return "Sync needs attention"
            }
        case .needsAccountReplacement:
            return "Reset iCloud sync"
        case .error:
            return "Sync couldn't finish"
        case .notConfigured:
            return "Sync with iPhone or iPad"
        }
    }

    private var bridgeSubtitle: String {
        switch bridgeState {
        case .active:
            if let deviceName = appState.iCloudBridgeCompanionDeviceName {
                return "Connected to \(deviceName)."
            }
            if appState.iCloudBridgeCompanionDiscoveryState == .waiting {
                return "Waiting for your iPhone or iPad…"
            }
            if appState.iCloudBridgeCompanionDiscoveryState == .timedOut {
                return "Couldn't find your device. Open Muesli there, then try again."
            }
            return "Connect another device to sync text."
        case .checkingICloud:
            return "Checking iCloud…"
        case .syncing:
            return ICloudBridgeWorkingCopy.subtitle(
                isActivationPending: appState.isICloudBridgeActivationPending
            )
        case .needsICloud:
            return "Sign in on this Mac, then try again."
        case .needsReconnection:
            switch ICloudSyncRecoveryPolicy.action(for: bridgeState) {
            case .reconnectLegacyLibrary:
                return "Reconnect to keep syncing."
            case .resetAccountLink:
                return "Reset sync to start again."
            case nil:
                return "Try again from Sync settings."
            }
        case .needsAccountReplacement:
            return "Reset sync to use this iCloud account."
        case .error:
            return "Try again."
        case .notConfigured:
            return "Turn on iCloud sync to get started."
        }
    }

    private var buttonTitle: String {
        switch flowAction {
        case .setUp: return "Set up sync"
        case .continueSetup: return "Continue setup"
        case .connectDevice: return "Connect device"
        case .waitingForDevice: return "Checking…"
        case .syncNow: return "Sync now"
        case .reconnect: return "Reconnect"
        case .reset: return "Reset"
        case .retry: return "Try again"
        case .working: return "Working…"
        }
    }

    private var buttonIcon: String {
        switch flowAction {
        case .setUp: return "icloud"
        case .continueSetup, .connectDevice: return "qrcode"
        case .reset: return "arrow.counterclockwise.icloud"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var actionDisabled: Bool {
        flowAction == .working || flowAction == .waitingForDevice
    }

    private var buttonHelp: String {
        switch ICloudSyncRecoveryPolicy.action(for: bridgeState) {
        case .reconnectLegacyLibrary:
            return "Reconnect this legacy library to the current iCloud account"
        case .resetAccountLink:
            return "Reset local iCloud sync state, then set up the current account"
        case nil:
            break
        }
        if flowAction == .waitingForDevice {
            return "Waiting for Muesli on your other device"
        }
        switch bridgeState {
        case .active:
            return "Sync text with iCloud"
        case .checkingICloud:
            return "Sync setup is in progress"
        case .syncing:
            return ICloudBridgeWorkingCopy.buttonHelp(
                isActivationPending: appState.isICloudBridgeActivationPending
            )
        case .needsReconnection, .needsAccountReplacement:
            return "Repair private iCloud text sync"
        default:
            return "Set up private iCloud text sync"
        }
    }

    private func primaryAction() {
        switch flowAction {
        case .setUp, .continueSetup:
            isQRCodePresented = true
            TelemetryDeck.signal("bridge_qr_shown", parameters: ["platform": "macos_setup"])
            controller.beginIPhoneBridgeDeviceDiscovery()
            controller.enableIPhoneBridgeSync()
        case .connectDevice:
            isQRCodePresented = true
            TelemetryDeck.signal("bridge_qr_shown", parameters: ["platform": "macos"])
            controller.beginIPhoneBridgeDeviceDiscovery()
        case .waitingForDevice:
            break
        case .syncNow:
            controller.performICloudSync()
        case .reconnect:
            isReconnectConfirmationPresented = true
        case .reset:
            isResetConfirmationPresented = true
        case .retry:
            controller.enableIPhoneBridgeSync()
        case .working:
            break
        }
    }

    private func relativeSyncTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct IPhoneBridgeQRCodeSheet: View {
    let deepLinkURL: URL
    let installURL: URL
    let isWaitingForDevice: Bool
    let presentationPhase: ICloudSyncQRCodePresentationPhase
    @Environment(\.dismiss) private var dismiss
    @State private var didCopySetupLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Connect iPhone or iPad")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text(presentationPhase == .syncing
                        ? "Device connected. Finishing sync…"
                        : "Scan once. This window closes when sync is ready.")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .center, spacing: MuesliTheme.spacing16) {
                QRCodeImage(payload: deepLinkURL.absoluteString)
                    .frame(width: 148, height: 148)
                    .padding(MuesliTheme.spacing8)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay {
                        if presentationPhase == .syncing {
                            ZStack {
                                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                    .fill(MuesliTheme.backgroundRaised.opacity(0.98))
                                VStack(spacing: MuesliTheme.spacing8) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Device connected")
                                        .font(MuesliTheme.body())
                                        .foregroundStyle(MuesliTheme.textPrimary)
                                    Text("Syncing…")
                                        .font(MuesliTheme.caption())
                                        .foregroundStyle(MuesliTheme.textTertiary)
                                }
                            }
                        }
                    }

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    Label("Same iCloud account", systemImage: "icloud")
                    Label("Text sync only", systemImage: "text.badge.checkmark")
                    Label("Audio stays local", systemImage: "lock")
                }
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
            }

            if isWaitingForDevice && presentationPhase == .readyToScan {
                Divider().background(MuesliTheme.surfaceBorder)
                HStack(spacing: MuesliTheme.spacing8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for iPhone or iPad…")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textSecondary)
                }
            }

            HStack(spacing: MuesliTheme.spacing8) {
                Button("Open iPhone app page") { NSWorkspace.shared.open(installURL) }
                    .buttonStyle(.bordered)

                Button(didCopySetupLink ? "Copied!" : "Copy setup link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(deepLinkURL.absoluteString, forType: .string)
                    didCopySetupLink = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1500))
                        didCopySetupLink = false
                    }
                }
                .buttonStyle(.bordered)
            }
            .disabled(presentationPhase == .syncing)
        }
        .padding(MuesliTheme.spacing20)
        .frame(width: 430)
        .background(MuesliTheme.backgroundBase)
    }
}

private struct QRCodeImage: View {
    let payload: String
    @State private var cachedImage: NSImage?

    var body: some View {
        Group {
            if let cachedImage {
                Image(nsImage: cachedImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 96, weight: .regular))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
        }
        .accessibilityLabel("iPhone sync setup QR code")
        .onAppear {
            if cachedImage == nil {
                cachedImage = makeQRCodeImage(payload: payload)
            }
        }
    }

    private func makeQRCodeImage(payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }

        let representation = NSCIImageRep(ciImage: outputImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
