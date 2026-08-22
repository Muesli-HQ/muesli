import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TelemetryDeck

enum ICloudBridgeWorkingCopy {
    static func title(isActivationPending: Bool) -> String {
        isActivationPending
            ? "Setting up private iCloud sync"
            : "Syncing with private iCloud"
    }

    static func subtitle(isActivationPending: Bool) -> String {
        isActivationPending
            ? "Creating the sync channel and pulling your latest text records."
            : "Checking for new text and uploading local changes."
    }

    static func buttonHelp(isActivationPending: Bool) -> String {
        isActivationPending
            ? "Sync setup is in progress"
            : "Text sync is in progress"
    }
}
struct IPhoneBridgeCard: View {
    let appState: AppState
    let controller: MuesliController

    @State private var promptSeen = false
    @State private var isQRCodePresented = false
    @State private var isReconnectConfirmationPresented = false
    @State private var isRemoveLinkConfirmationPresented = false

    var body: some View {
        HStack(alignment: .center, spacing: MuesliTheme.spacing12) {
            BridgeSyncIcon(
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

            if shouldShowHandoffButton {
                Button {
                    isQRCodePresented = true
                    TelemetryDeck.signal("bridge_qr_shown", parameters: ["platform": "macos"])
                } label: {
                    Image(systemName: "qrcode")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textPrimary)
                        .frame(width: 28, height: 28)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .help("Show iPhone setup QR")
            }

            Button(action: primaryAction) {
                HStack(spacing: 6) {
                    Text(buttonTitle)
                    BridgeSyncIcon(
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
        .sheet(isPresented: $isQRCodePresented) {
            IPhoneBridgeQRCodeSheet(
                deepLinkURL: IPhoneBridgeLinks.iOSSyncDeepLinkURL,
                installURL: IPhoneBridgeLinks.installURL
            )
        }
        .alert("Reconnect this Mac?", isPresented: $isReconnectConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Reconnect this Mac") {
                controller.reconnectICloudSyncToCurrentAccount()
            }
        } message: {
            Text("Muesli will keep your local history and audio, then sync eligible existing text with the iCloud account currently signed in on this Mac. Audio always stays local.")
        }
        .alert("Remove linked device?", isPresented: $isRemoveLinkConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Remove linked device", role: .destructive) {
                controller.removeLinkedICloudDevice()
            }
        } message: {
            Text("Muesli will turn off sync and remove this Mac's previous account link. Local history and audio stay on this Mac, and data in the previous iCloud account is not deleted. You can then set up sync with the current iCloud account.")
        }
    }

    private var bridgeState: ICloudBridgeState {
        appState.iCloudBridgeState
    }

    private var shouldShowHandoffButton: Bool {
        guard appState.config.iCloudSyncEnabled else { return false }
        switch bridgeState {
        case .needsICloud, .needsReconnection, .needsAccountReplacement, .error:
            return false
        case .active:
            return appState.iCloudBridgeCompanionDeviceName == nil
        case .notConfigured, .checkingICloud, .syncing:
            return false
        }
    }

    private var bridgeSyncIconIsAnimating: Bool {
        isSyncWorking && bridgeIcon == "arrow.triangle.2.circlepath"
    }

    private var buttonIconIsAnimating: Bool {
        isSyncWorking && buttonIcon == "arrow.triangle.2.circlepath"
    }

    private var isSyncWorking: Bool {
        bridgeState == .checkingICloud || bridgeState == .syncing
    }

    private var bridgeIcon: String {
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
            return "Setting up private iCloud sync"
        case .syncing:
            return ICloudBridgeWorkingCopy.title(
                isActivationPending: appState.isICloudBridgeActivationPending
            )
        case .needsICloud:
            return "Sign in to iCloud to sync"
        case .needsReconnection:
            return "Reconnect iPhone sync"
        case .needsAccountReplacement:
            return "iCloud account changed"
        case .error:
            return "iPhone sync needs attention"
        case .notConfigured:
            return "Use Muesli on iPhone"
        }
    }

    private var bridgeSubtitle: String {
        switch bridgeState {
        case .active:
            if let deviceName = appState.iCloudBridgeCompanionDeviceName {
                return "Private iCloud text sync is on with \(deviceName). Audio stays local."
            }
            return "Scan the QR code to connect your iPhone. Audio stays local."
        case .checkingICloud:
            return "Checking this Mac's iCloud account..."
        case .syncing:
            return ICloudBridgeWorkingCopy.subtitle(
                isActivationPending: appState.isICloudBridgeActivationPending
            )
        case .needsICloud, .needsReconnection, .needsAccountReplacement, .error:
            return appState.iCloudBridgeMessage ?? "Open iCloud settings, then try again."
        case .notConfigured:
            return "Your Muesli history follows you through private iCloud. Audio stays local."
        }
    }

    private var buttonTitle: String {
        switch bridgeState {
        case .active: return "Sync"
        case .checkingICloud, .syncing: return "Syncing"
        case .needsReconnection: return "Reconnect"
        case .needsAccountReplacement: return "Remove link"
        case .needsICloud, .error: return "Try again"
        case .notConfigured: return "Set up private iCloud sync"
        }
    }

    private var buttonIcon: String {
        bridgeState == .notConfigured ? "icloud" : "arrow.triangle.2.circlepath"
    }

    private var actionDisabled: Bool {
        bridgeState == .checkingICloud || bridgeState == .syncing
    }

    private var buttonHelp: String {
        switch bridgeState {
        case .active:
            return "Sync text with iCloud"
        case .checkingICloud:
            return "Sync setup is in progress"
        case .syncing:
            return ICloudBridgeWorkingCopy.buttonHelp(
                isActivationPending: appState.isICloudBridgeActivationPending
            )
        case .needsReconnection:
            return "Confirm this Mac's current iCloud account and reconnect text sync"
        case .needsAccountReplacement:
            return "Remove the previous account link before setting up sync again"
        default:
            return "Set up private iCloud text sync"
        }
    }

    private func primaryAction() {
        switch bridgeState {
        case .active:
            controller.performICloudSync()
        case .needsReconnection:
            isReconnectConfirmationPresented = true
        case .needsAccountReplacement:
            isRemoveLinkConfirmationPresented = true
        case .checkingICloud, .syncing:
            break
        default:
            controller.enableIPhoneBridgeSync()
        }
    }

    private func relativeSyncTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct BridgeSyncIcon: View {
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

private struct IPhoneBridgeQRCodeSheet: View {
    let deepLinkURL: URL
    let installURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var didCopySetupLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                    Text("Open Muesli on iPhone")
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)
                    Text("Scan this after installing the iPhone app. The QR only opens setup; private iCloud does the actual sync.")
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

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    Label("Same iCloud account", systemImage: "icloud")
                    Label("Text sync only", systemImage: "text.badge.checkmark")
                    Label("Audio stays local", systemImage: "lock")
                }
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
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
