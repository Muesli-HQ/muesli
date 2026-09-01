import AppKit
import ApplicationServices
import SwiftUI

struct AccessibilityPermissionGuideFrames: Equatable {
    let target: CGRect
    let card: CGRect
    let dragSource: CGRect
}

enum AccessibilityPermissionGuideLayout {
    static func frames(for settingsWindow: CGRect) -> AccessibilityPermissionGuideFrames? {
        guard settingsWindow.width >= 720, settingsWindow.height >= 500 else { return nil }

        let sidebarWidth = min(max(settingsWindow.width * 0.32, 250), 370)
        let contentMinX = settingsWindow.minX + sidebarWidth + 24
        let contentMaxX = settingsWindow.maxX - 28
        let contentWidth = contentMaxX - contentMinX
        guard contentWidth >= 360 else { return nil }

        let targetHeight = min(250, max(170, settingsWindow.height * 0.30))
        let target = CGRect(
            x: contentMinX,
            y: settingsWindow.minY + settingsWindow.height * 0.38,
            width: contentWidth,
            height: targetHeight
        )

        let cardWidth = min(560, contentWidth - 24)
        let cardHeight: CGFloat = 190
        let card = CGRect(
            x: contentMinX + (contentWidth - cardWidth) / 2,
            y: max(settingsWindow.minY + 28, target.minY - cardHeight - 12),
            width: cardWidth,
            height: cardHeight
        )

        let dragSource = CGRect(
            x: card.minX + 24,
            y: card.minY + 52,
            width: card.width - 48,
            height: 68
        )

        return AccessibilityPermissionGuideFrames(
            target: target.integral,
            card: card.integral,
            dragSource: dragSource.integral
        )
    }
}

enum AccessibilityPermissionGuidePresentationPolicy {
    static let systemSettingsBundleID = "com.apple.systempreferences"

    static func shouldShow(
        isRequested: Bool,
        isTrusted: Bool,
        frontmostBundleID: String?,
        hasSettingsWindow: Bool
    ) -> Bool {
        isRequested
            && !isTrusted
            && frontmostBundleID == systemSettingsBundleID
            && hasSettingsWindow
    }
}

enum SystemSettingsWindowGeometry {
    static func appKitFrame(fromQuartz frame: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

@MainActor
final class AccessibilityPermissionGuideController {
    private let appURL: URL
    private let appName: String
    private let appIcon: NSImage
    private let model = AccessibilityPermissionGuideModel()

    private var targetPanel: NSPanel?
    private var cardPanel: NSPanel?
    private var dragPanel: NSPanel?
    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private var isRequested = false

    init(
        appURL: URL = Bundle.main.bundleURL,
        appName: String = AppIdentity.displayName,
        appIcon: NSImage? = nil
    ) {
        self.appURL = appURL
        self.appName = appName
        self.appIcon = appIcon ?? NSApplication.shared.applicationIconImage
    }

    func showWhenSystemSettingsIsAvailable() {
        guard !AXIsProcessTrusted() else {
            dismiss()
            return
        }

        isRequested = true
        model.didCompleteDrag = false
        installObserversIfNeeded()
        startRefreshTimerIfNeeded()
        refreshPresentation()
    }

    func dismiss() {
        isRequested = false
        refreshTimer?.invalidate()
        refreshTimer = nil

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspaceCenter.removeObserver($0) }
        workspaceObservers.removeAll()

        let notificationCenter = NotificationCenter.default
        applicationObservers.forEach { notificationCenter.removeObserver($0) }
        applicationObservers.removeAll()

        closePanels()
    }

    private func installObserversIfNeeded() {
        guard workspaceObservers.isEmpty, applicationObservers.isEmpty else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshPresentation()
                }
            })
        }

        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPresentation()
            }
        })
    }

    private func startRefreshTimerIfNeeded() {
        guard refreshTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPresentation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refreshPresentation() {
        if AXIsProcessTrusted() {
            dismiss()
            return
        }

        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let settingsWindow = SystemSettingsWindowLocator.mainWindowFrame()
        guard AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: isRequested,
            isTrusted: false,
            frontmostBundleID: frontmostBundleID,
            hasSettingsWindow: settingsWindow != nil
        ), let settingsWindow,
           let frames = AccessibilityPermissionGuideLayout.frames(for: settingsWindow) else {
            hidePanels()
            return
        }

        ensurePanels()
        targetPanel?.setFrame(frames.target, display: true)
        cardPanel?.setFrame(frames.card, display: true)
        dragPanel?.setFrame(frames.dragSource, display: true)

        targetPanel?.orderFrontRegardless()
        cardPanel?.orderFrontRegardless()
        dragPanel?.orderFrontRegardless()
    }

    private func ensurePanels() {
        if targetPanel == nil {
            targetPanel = makePanel(
                frame: .zero,
                ignoresMouseEvents: true,
                contentView: NSHostingView(rootView: AccessibilityPermissionGuideTargetView(
                    appName: appName,
                    appIcon: appIcon,
                    model: model
                ).preferredColorScheme(.dark))
            )
        }

        if cardPanel == nil {
            cardPanel = makePanel(
                frame: .zero,
                ignoresMouseEvents: true,
                contentView: NSHostingView(rootView: AccessibilityPermissionGuideCardView(
                    appName: appName,
                    model: model
                ).preferredColorScheme(.dark))
            )
        }

        if dragPanel == nil {
            let dragView = AccessibilityPermissionDragSourceView(
                frame: .zero,
                appURL: appURL,
                appName: appName,
                appIcon: appIcon
            )
            dragView.onDragEnded = { [weak self] in
                self?.model.didCompleteDrag = true
            }
            dragPanel = makePanel(
                frame: .zero,
                ignoresMouseEvents: false,
                contentView: dragView
            )
        }
    }

    private func makePanel(
        frame: CGRect,
        ignoresMouseEvents: Bool,
        contentView: NSView
    ) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView.frame = CGRect(origin: .zero, size: frame.size)
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView
        return panel
    }

    private func hidePanels() {
        targetPanel?.orderOut(nil)
        cardPanel?.orderOut(nil)
        dragPanel?.orderOut(nil)
    }

    private func closePanels() {
        for panel in [targetPanel, cardPanel, dragPanel] {
            panel?.orderOut(nil)
            panel?.close()
        }
        targetPanel = nil
        cardPanel = nil
        dragPanel = nil
    }
}

private enum SystemSettingsWindowLocator {
    static func mainWindowFrame() -> CGRect? {
        guard let settingsApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID
        ).first else {
            return nil
        }

        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let quartzFrame = windows.compactMap { info -> CGRect? in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == settingsApp.processIdentifier,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 720,
                  frame.height >= 500 else {
                return nil
            }
            return frame
        }.max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }

        guard let quartzFrame else { return nil }
        let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY ?? quartzFrame.maxY
        return SystemSettingsWindowGeometry.appKitFrame(
            fromQuartz: quartzFrame,
            primaryScreenMaxY: primaryScreenMaxY
        )
    }
}

@MainActor
private final class AccessibilityPermissionGuideModel: ObservableObject {
    @Published var didCompleteDrag = false
}

private struct AccessibilityPermissionGuideTargetView: View {
    let appName: String
    let appIcon: NSImage
    @ObservedObject var model: AccessibilityPermissionGuideModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.black.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(
                            MuesliTheme.accent,
                            style: StrokeStyle(lineWidth: 2.5, dash: [9, 7])
                        )
                )

            VStack(spacing: 8) {
                Image(systemName: model.didCompleteDrag ? "checkmark" : "arrow.up")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(model.didCompleteDrag ? MuesliTheme.success : MuesliTheme.accent)

                PermissionGuideAppRow(appName: appName, appIcon: appIcon, isGhost: true)
                    .frame(maxWidth: 430)
                    .offset(y: reduceMotion || model.didCompleteDrag ? 0 : (isAnimating ? -30 : 28))
                    .opacity(model.didCompleteDrag ? 0.62 : 0.88)
            }
            .padding(.horizontal, 24)
        }
        .padding(2)
        .onAppear {
            guard !reduceMotion, !model.didCompleteDrag else { return }
            withAnimation(.easeInOut(duration: 1.45).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}

private struct AccessibilityPermissionGuideCardView: View {
    let appName: String
    @ObservedObject var model: AccessibilityPermissionGuideModel

    var body: some View {
        VStack(spacing: 0) {
            Text(model.didCompleteDrag ? "Turn \(appName) on" : "Drag \(appName) into the list")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 20)

            Spacer()
                .frame(height: 80)

            Text(model.didCompleteDrag
                ? "Use the switch beside \(appName) above."
                : "If it is already listed, just turn its switch on.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.66))
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 0.96)))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 20, y: 8)
        .padding(2)
    }
}

private struct PermissionGuideAppRow: View {
    let appName: String
    let appIcon: NSImage
    var isGhost = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(appName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(isGhost ? 0.84 : 0.94))

            Spacer()

            if !isGhost {
                Image(systemName: "hand.draw.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MuesliTheme.accent)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(isGhost ? 0.08 : 0.11))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(isGhost ? 0.12 : 0.18), lineWidth: 1)
        )
    }
}

@MainActor
private final class AccessibilityPermissionDragSourceView: NSView, NSDraggingSource {
    var onDragEnded: (() -> Void)?

    private let appURL: URL
    private var mouseDownLocation: CGPoint?
    private var hasStartedDrag = false

    init(frame frameRect: NSRect, appURL: URL, appName: String, appIcon: NSImage) {
        self.appURL = appURL
        super.init(frame: frameRect)

        let hostingView = NSHostingView(rootView: PermissionGuideAppRow(
            appName: appName,
            appIcon: appIcon
        ).preferredColorScheme(.dark))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        toolTip = "Drag \(appName) into the Accessibility list"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        hasStartedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasStartedDrag, let mouseDownLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - mouseDownLocation.x, current.y - mouseDownLocation.y) >= 4 else { return }

        hasStartedDrag = true
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: dragImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        hasStartedDrag = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        mouseDownLocation = nil
        hasStartedDrag = false
        if !operation.isEmpty {
            onDragEnded?()
        }
    }

    private func dragImage() -> NSImage {
        guard let representation = bitmapImageRepForCachingDisplay(in: bounds) else {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        cacheDisplay(in: bounds, to: representation)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(representation)
        return image
    }
}
