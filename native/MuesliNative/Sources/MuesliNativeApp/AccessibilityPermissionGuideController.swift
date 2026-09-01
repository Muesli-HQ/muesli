import AppKit
import ApplicationServices
import SwiftUI

struct AccessibilityPermissionGuideFrames: Equatable {
    let guide: CGRect
    let dragSource: CGRect
    let completedGuide: CGRect
}

enum AccessibilityPermissionGuideLayout {
    static func frames(for settingsWindow: CGRect) -> AccessibilityPermissionGuideFrames? {
        guard settingsWindow.width >= 720, settingsWindow.height >= 500 else { return nil }

        let sidebarWidth = min(max(settingsWindow.width * 0.32, 250), 370)
        let contentMinX = settingsWindow.minX + sidebarWidth + 24
        let contentMaxX = settingsWindow.maxX - 28
        let contentWidth = contentMaxX - contentMinX
        guard contentWidth >= 360 else { return nil }

        let guideWidth = min(720, contentWidth - 16)
        let guideHeight: CGFloat = 226
        let preferredY = settingsWindow.minY + max(96, settingsWindow.height * 0.22)
        let guideY = min(preferredY, settingsWindow.maxY - guideHeight - 92)
        let guide = CGRect(
            x: contentMinX + (contentWidth - guideWidth) / 2,
            y: guideY,
            width: guideWidth,
            height: guideHeight
        )

        let dragSource = CGRect(
            x: guide.minX + 14,
            y: guide.minY + 14,
            width: guide.width - 28,
            height: 76
        )

        let completedGuide = CGRect(
            x: guide.minX + 46,
            y: dragSource.minY + 8,
            width: guide.width - 92,
            height: 58
        )

        return AccessibilityPermissionGuideFrames(
            guide: guide.integral,
            dragSource: dragSource.integral,
            completedGuide: completedGuide.integral
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
    var onPresentationChanged: ((Bool) -> Void)?

    private let appURL: URL
    private let appName: String
    private let appIcon: NSImage
    private let model = AccessibilityPermissionGuideModel()

    private var guidePanel: NSPanel?
    private var dragPanel: NSPanel?
    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private var isRequested = false
    private var isPresenting = false

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

        setPresenting(false)
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
            setPresenting(false)
            return
        }

        ensurePanels()
        setPresenting(true)
        if model.didCompleteDrag {
            guidePanel?.setFrame(frames.completedGuide, display: true)
            dragPanel?.orderOut(nil)
        } else {
            guidePanel?.setFrame(frames.guide, display: true)
            dragPanel?.setFrame(frames.dragSource, display: true)
        }
        guidePanel?.orderFrontRegardless()
        if !model.didCompleteDrag {
            dragPanel?.orderFrontRegardless()
        }
    }

    private func ensurePanels() {
        if guidePanel == nil {
            guidePanel = makePanel(
                frame: .zero,
                ignoresMouseEvents: true,
                contentView: NSHostingView(rootView: CompactAccessibilityPermissionGuideView(
                    appName: appName,
                    appIcon: appIcon,
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
                guard let self else { return }
                self.model.didCompleteDrag = true
                self.refreshPresentation()
            }
            dragPanel = makePanel(
                frame: .zero,
                ignoresMouseEvents: false,
                contentView: dragView
            )
        }
    }

    private func setPresenting(_ presenting: Bool) {
        guard isPresenting != presenting else { return }
        isPresenting = presenting
        onPresentationChanged?(presenting)
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
        guidePanel?.orderOut(nil)
        dragPanel?.orderOut(nil)
    }

    private func closePanels() {
        for panel in [guidePanel, dragPanel] {
            panel?.orderOut(nil)
            panel?.close()
        }
        guidePanel = nil
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

private struct CompactAccessibilityPermissionGuideView: View {
    let appName: String
    let appIcon: NSImage
    @ObservedObject var model: AccessibilityPermissionGuideModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        Group {
            if model.didCompleteDrag {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(MuesliTheme.success)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(appName) added")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.94))
                        Text("Turn it on in the list above")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(MuesliTheme.accent)

                    PermissionGuideAppRow(appName: appName, appIcon: appIcon, isGhost: true)
                        .frame(height: 52)
                        .offset(y: reduceMotion ? 0 : (isAnimating ? -7 : 4))

                    Text("Drag this row up into the list")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.66))

                    Spacer(minLength: 88)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 0.91)))
        .clipShape(RoundedRectangle(cornerRadius: model.didCompleteDrag ? 14 : 18))
        .overlay(
            RoundedRectangle(cornerRadius: model.didCompleteDrag ? 14 : 18)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .padding(2)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}

private struct AccessibilityPermissionDragRowView: View {
    let appName: String
    let appIcon: NSImage

    var body: some View {
        PermissionGuideAppRow(appName: appName, appIcon: appIcon)
            .padding(7)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        MuesliTheme.accent,
                        style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                    )
            )
            .padding(1)
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
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))

            Text(appName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(isGhost ? 0.84 : 0.94))

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(isGhost ? 0.07 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(isGhost ? 0.10 : 0.15), lineWidth: 1)
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

        let hostingView = NSHostingView(rootView: AccessibilityPermissionDragRowView(
            appName: appName,
            appIcon: appIcon
        ).preferredColorScheme(.dark))
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
        toolTip = "Drag \(appName) into the Accessibility list"
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
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
