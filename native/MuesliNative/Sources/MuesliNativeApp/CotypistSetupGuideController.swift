import AppKit
import SwiftUI

/// Where the Cotypist setup guide sits relative to System Settings: beside the window when there's
/// room, so it never covers the Input Sources sheet or its add dialog (both centred on the window).
enum CotypistSetupGuideLayout {
    static let size = CGSize(width: 300, height: 268)
    static let gap: CGFloat = 14

    static func frame(besides settingsWindow: CGRect, on screen: CGRect) -> CGRect {
        let y = min(max(settingsWindow.maxY - size.height - 52, screen.minY + 12), screen.maxY - size.height - 12)
        let right = CGRect(x: settingsWindow.maxX + gap, y: y, width: size.width, height: size.height)
        if right.maxX <= screen.maxX - 8 { return right.integral }
        let left = CGRect(x: settingsWindow.minX - gap - size.width, y: y, width: size.width, height: size.height)
        if left.minX >= screen.minX + 8 { return left.integral }
        // No room either side: the bottom-left corner of the window, clear of the centred sheet.
        return CGRect(x: settingsWindow.minX + 16, y: settingsWindow.minY + 16, width: size.width, height: size.height).integral
    }
}

/// A floating guide beside System Settings for adding the Cotypist input source — the one setup
/// step macOS reserves for the user. Styled after the Accessibility drag guide; it doesn't take
/// focus, follows the Settings window, and is closed by `CotypistSetup` once setup completes.
@MainActor
final class CotypistSetupGuideController {
    var onClose: (() -> Void)?

    private let model = CotypistSetupGuideModel()
    private var panel: NSPanel?
    private var followTimer: Timer?

    func show(inputSourceName: String, suggestsRelogin: Bool) {
        model.inputSourceName = inputSourceName
        model.suggestsRelogin = suggestsRelogin
        ensurePanel()
        reposition()
        guard followTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    func dismiss() {
        followTimer?.invalidate()
        followTimer = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    /// Shown only while System Settings is open and frontmost, tracking its window.
    private func reposition() {
        guard let panel else { return }
        let settingsFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID
        guard settingsFrontmost, let window = SystemSettingsWindowLocator.mainWindowFrame() else {
            panel.orderOut(nil)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(window) }?.visibleFrame ?? window
        panel.setFrame(CotypistSetupGuideLayout.frame(besides: window, on: screen), display: true)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: CotypistSetupGuideLayout.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let view = NSHostingView(rootView: CotypistSetupGuideView(model: model) { [weak self] in
            self?.onClose?()
        }.preferredColorScheme(.dark))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        self.panel = panel
    }
}

@MainActor
private final class CotypistSetupGuideModel: ObservableObject {
    @Published var inputSourceName = ""
    @Published var suggestsRelogin = false
}

private struct CotypistSetupGuideView: View {
    @ObservedObject var model: CotypistSetupGuideModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Turn on Cotypist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }

            step(1, "Next to **Input Sources**, click **Edit…**")
            step(2, "Click **+** at the bottom left, then **English**")
            step(3, "Choose this, then click **Add**:")

            PermissionGuideAppRow(appName: model.inputSourceName, appIcon: NSApplication.shared.applicationIconImage)
                .frame(height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(MuesliTheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )

            if model.suggestsRelogin {
                Text("Not in the list? macOS lists new input sources after you log out and back in. Then turn Cotypist on again.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Cotypist turns on as soon as it's added")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: NSColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 0.94)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(2)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MuesliTheme.accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(MuesliTheme.accent.opacity(0.18)))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.80))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
