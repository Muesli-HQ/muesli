import SwiftUI
import MuesliCore

struct AboutView: View {
    let appState: AppState
    let controller: MuesliController

    private let githubURL = "https://github.com/pHequals7/muesli"
    private let donateURL = "https://buymeacoffee.com/phequals7"

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        return "v\(v)"
    }

    private var appDataPath: String {
        AppIdentity.supportDirectoryURL.path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing32) {
                Text("About")
                    .font(MuesliTheme.title1())
                    .foregroundStyle(MuesliTheme.textPrimary)

                if let banner = updateBanner {
                    updateBannerView(banner)
                }

                // MARK: - App Info
                sectionHeader("App Info")
                aboutCard {
                    aboutRow("Version") {
                        Text(version)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MuesliTheme.textPrimary)
                    }

                    if showsManualUpdateCheckRow {
                        Divider().background(MuesliTheme.surfaceBorder)

                        aboutRow("Check for Updates") {
                            let action = updatePrimaryAction
                            actionButton(action.title, icon: action.icon) {
                                performUpdateAction(action)
                            }
                        }
                    }
                }

                // MARK: - Support
                sectionHeader("Support")
                aboutCard {
                    aboutRow("Support Development") {
                        Button {
                            if let url = URL(string: donateURL) { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 12))
                                Text("Donate")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, MuesliTheme.spacing20)
                            .padding(.vertical, MuesliTheme.spacing8)
                            .background(MuesliTheme.success)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        }
                        .buttonStyle(.plain)
                    }

                    Divider().background(MuesliTheme.surfaceBorder)

                    aboutRow("Source Code") {
                        actionButton("View on GitHub", icon: "arrow.up.right.square") {
                            if let url = URL(string: githubURL) { NSWorkspace.shared.open(url) }
                        }
                    }
                }

                // MARK: - Data
                sectionHeader("Data")
                aboutCard {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                        Text("App Data Directory")
                            .font(MuesliTheme.body())
                            .foregroundStyle(MuesliTheme.textPrimary)

                        HStack {
                            Text(appDataPath)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(MuesliTheme.textTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            actionButton("Open", icon: "folder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appDataPath)
                            }
                        }
                    }
                }

                // MARK: - Acknowledgements
                sectionHeader("Acknowledgements")
                aboutCard {
                    acknowledgement(
                        name: "FluidAudio by FluidInference",
                        description: "CoreML speech stack powering Parakeet, Qwen3 ASR, Silero VAD, and speaker diarization on Apple Silicon."
                    )
                    Divider().background(MuesliTheme.surfaceBorder)
                    acknowledgement(
                        name: "LocalVQE by localai-org",
                        description: "On-device acoustic echo cancellation powering cleaner meeting transcription."
                    )
                    Divider().background(MuesliTheme.surfaceBorder)
                    acknowledgement(
                        name: "WhisperKit by Argmax",
                        description: "Swift Whisper inference on CoreML/ANE powering the app's Whisper Small, Medium, and Large Turbo backends."
                    )
                }

                Spacer(minLength: MuesliTheme.spacing32)
            }
            .padding(MuesliTheme.spacing32)
        }
        .background(MuesliTheme.backgroundBase)
    }

    // MARK: - Components

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MuesliTheme.textTertiary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }

    @ViewBuilder
    private func aboutCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(MuesliTheme.spacing20)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private struct UpdateBanner {
        let icon: String
        let title: String
        let message: String
        let tint: Color
        let action: UpdateBannerAction?
    }

    private enum UpdateBannerAction {
        case check
        case install
        case restartInstall
        case retry

        var title: String {
            switch self {
            case .check:
                return "Check Now"
            case .install:
                return "Install Update"
            case .restartInstall:
                return "Restart & Install"
            case .retry:
                return "Try Again"
            }
        }

        var icon: String {
            switch self {
            case .check:
                return "arrow.triangle.2.circlepath"
            case .install:
                return "arrow.down.circle"
            case .restartInstall:
                return "arrow.clockwise.circle"
            case .retry:
                return "arrow.triangle.2.circlepath"
            }
        }
    }

    private var updatePrimaryAction: UpdateBannerAction {
        switch appState.sparkleUpdateStatus {
        case .available:
            return .install
        case .downloaded:
            return .restartInstall
        case .failed:
            return .retry
        case .idle, .checking, .busy, .installing, .upToDate, .disabled:
            return .check
        }
    }

    private var showsManualUpdateCheckRow: Bool {
        switch appState.sparkleUpdateStatus {
        case .idle, .upToDate:
            return true
        case .checking, .busy, .available, .downloaded, .installing, .disabled, .failed:
            return false
        }
    }

    private func performUpdateAction(_ action: UpdateBannerAction) {
        switch action {
        case .check, .retry:
            controller.retryUpdateCheck()
        case .install, .restartInstall:
            controller.installAvailableUpdate()
        }
    }

    private var updateBanner: UpdateBanner? {
        switch appState.sparkleUpdateStatus {
        case .idle:
            return nil
        case .checking:
            return UpdateBanner(
                icon: "arrow.triangle.2.circlepath",
                title: "Checking for updates",
                message: "Muesli is checking the appcast for the latest version.",
                tint: MuesliTheme.transcribing,
                action: nil
            )
        case .busy(let message):
            return UpdateBanner(
                icon: "clock.arrow.circlepath",
                title: "Updater is busy",
                message: message,
                tint: MuesliTheme.transcribing,
                action: nil
            )
        case .available(let version):
            return UpdateBanner(
                icon: "exclamationmark.triangle.fill",
                title: "Muesli \(version) is available",
                message: "An update is available. Start the updater to download and install it.",
                tint: MuesliTheme.transcribing,
                action: .install
            )
        case .downloaded(let version):
            return UpdateBanner(
                icon: "exclamationmark.triangle.fill",
                title: "Muesli \(version) is ready to install",
                message: "Restart Muesli from here and Sparkle will finish installing the update automatically.",
                tint: MuesliTheme.transcribing,
                action: .restartInstall
            )
        case .installing(let version):
            return UpdateBanner(
                icon: "arrow.down.circle.fill",
                title: "Installing Muesli \(version)",
                message: "Sparkle is preparing the update. Muesli may relaunch when installation finishes.",
                tint: MuesliTheme.transcribing,
                action: nil
            )
        case .upToDate:
            return UpdateBanner(
                icon: "checkmark.circle.fill",
                title: "Muesli is up to date",
                message: "No newer version was found in the appcast.",
                tint: MuesliTheme.success,
                action: nil
            )
        case .disabled(let message):
            return UpdateBanner(
                icon: "minus.circle.fill",
                title: "Updates are disabled",
                message: message,
                tint: MuesliTheme.textTertiary,
                action: nil
            )
        case .failed(let message):
            return UpdateBanner(
                icon: "xmark.octagon.fill",
                title: "Update check failed",
                message: message,
                tint: MuesliTheme.recording,
                action: .retry
            )
        }
    }

    @ViewBuilder
    private func updateBannerView(_ banner: UpdateBanner) -> some View {
        HStack(alignment: .top, spacing: MuesliTheme.spacing12) {
            Image(systemName: banner.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(banner.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
                Text(banner.title)
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text(banner.message)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MuesliTheme.spacing16)

            if let action = banner.action {
                actionButton(action.title, icon: action.icon) {
                    performUpdateAction(action)
                }
            }
        }
        .padding(MuesliTheme.spacing16)
        .background(banner.tint.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(banner.tint.opacity(0.45), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func aboutRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(MuesliTheme.body())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer()
            control()
        }
        .padding(.vertical, MuesliTheme.spacing8)
    }

    @ViewBuilder
    private func acknowledgement(name: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing4) {
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
            Text(description)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, MuesliTheme.spacing8)
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing16)
            .padding(.vertical, MuesliTheme.spacing8)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
