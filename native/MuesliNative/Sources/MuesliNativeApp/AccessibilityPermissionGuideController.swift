import AppKit
import ApplicationServices
import SwiftUI

struct AccessibilityPermissionGuideFrames: Equatable {
    let guide: CGRect
    let dragSource: CGRect
    let postDropGuide: CGRect
    let permissionListDropRegion: CGRect
    let dragDirection: PermissionGuideDragDirection
}

enum PermissionGuideDragDirection: Equatable {
    case up
    case down

    var symbolName: String {
        self == .up ? "arrow.up" : "arrow.down"
    }

    var instruction: String {
        self == .up ? "Drag this row up into this list" : "Drag this row down into this list"
    }
}

enum AccessibilityPermissionGuideLayout {
    static func frames(for settingsWindow: CGRect) -> AccessibilityPermissionGuideFrames? {
        guard settingsWindow.width >= 720, settingsWindow.height >= 500 else { return nil }

        let sidebarWidth = min(max(settingsWindow.width * 0.32, 250), 370)
        let contentMinX = settingsWindow.minX + sidebarWidth + 24
        let contentMaxX = settingsWindow.maxX - 28
        let contentWidth = contentMaxX - contentMinX
        guard contentWidth >= 360 else { return nil }

        let guideWidth = min(640, contentWidth - 24)
        let guideHeight: CGFloat = 128
        let preferredY = settingsWindow.minY + max(88, settingsWindow.height * 0.18)
        let guideY = min(preferredY, settingsWindow.maxY - guideHeight - 80)
        let guide = CGRect(
            x: contentMinX + (contentWidth - guideWidth) / 2,
            y: guideY,
            width: guideWidth,
            height: guideHeight
        )

        let dragSource = CGRect(
            x: guide.minX + 12,
            y: guide.minY + 12,
            width: guide.width - 24,
            height: 70
        )

        let postDropGuide = CGRect(
            x: guide.minX + 64,
            y: dragSource.minY + 7,
            width: guide.width - 128,
            height: 56
        )

        let dragDirection: PermissionGuideDragDirection = guide.midY <= settingsWindow.midY ? .up : .down
        let contentTop = settingsWindow.maxY - 88
        let contentBottom = settingsWindow.minY + 64
        let permissionListDropRegion: CGRect
        if dragDirection == .up {
            permissionListDropRegion = CGRect(
                x: dragSource.minX,
                y: guide.maxY + 8,
                width: dragSource.width,
                height: max(0, contentTop - guide.maxY - 8)
            )
        } else {
            permissionListDropRegion = CGRect(
                x: dragSource.minX,
                y: contentBottom,
                width: dragSource.width,
                height: max(0, guide.minY - contentBottom - 8)
            )
        }

        return AccessibilityPermissionGuideFrames(
            guide: guide.integral,
            dragSource: dragSource.integral,
            postDropGuide: postDropGuide.integral,
            permissionListDropRegion: permissionListDropRegion.integral,
            dragDirection: dragDirection
        )
    }
}

enum AccessibilityPermissionGuideDropPolicy {
    static func isLikelyPermissionListDropAttempt(
        operationAccepted: Bool,
        dropPoint: CGPoint,
        frontmostBundleID: String?,
        settingsWindow: CGRect?
    ) -> Bool {
        guard operationAccepted,
              frontmostBundleID == AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID,
              let settingsWindow,
              let frames = AccessibilityPermissionGuideLayout.frames(for: settingsWindow) else {
            return false
        }
        return frames.permissionListDropRegion.contains(dropPoint)
    }
}

enum AccessibilityPermissionGuideCopy {
    static func attemptedDropTitle(appName: String) -> String {
        "Turn \(appName) on"
    }

    static let attemptedDropDetail = "If it appears above, turn on its switch"
}

enum AccessibilityPermissionGuideRetryPolicy {
    static let attemptedDropRetryDelay: TimeInterval = 4

    static func shouldRestoreDragSource(didAttemptDrop: Bool, isGranted: Bool) -> Bool {
        didAttemptDrop && !isGranted
    }
}

enum PermissionDragGuidePermission {
    case accessibility
    case inputMonitoring

    var isGranted: Bool {
        switch self {
        case .accessibility:
            AXIsProcessTrusted()
        case .inputMonitoring:
            CGPreflightListenEventAccess()
        }
    }
}

enum AccessibilityPermissionGuidePresentationPolicy {
    static let systemSettingsBundleID = "com.apple.systempreferences"

    static func shouldShow(
        isRequested: Bool,
        isGranted: Bool,
        frontmostBundleID: String?,
        hasSettingsWindow: Bool
    ) -> Bool {
        isRequested
            && !isGranted
            && frontmostBundleID == systemSettingsBundleID
            && hasSettingsWindow
    }
}

enum AccessibilityPermissionGuideSuppressionPolicy {
    static func shouldSuppressOnboarding(
        isRequested: Bool,
        isGranted: Bool,
        frontmostBundleID: String?,
        muesliBundleID: String?,
        hasUsableGuide: Bool,
        isCurrentlySuppressed: Bool
    ) -> Bool {
        guard isRequested, !isGranted else { return false }
        if frontmostBundleID == AccessibilityPermissionGuidePresentationPolicy.systemSettingsBundleID {
            return hasUsableGuide
        }
        if frontmostBundleID == muesliBundleID {
            return false
        }
        return isCurrentlySuppressed
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
    private var attemptedDropRetryTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []
    private var requestedPermission: PermissionDragGuidePermission?
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

    func showWhenSystemSettingsIsAvailable(for permission: PermissionDragGuidePermission) {
        guard !permission.isGranted else {
            dismiss()
            return
        }

        // Each explicit invocation starts with a draggable row. A prior drop is
        // only an attempt; the TCC permission state is the sole completion signal.
        cancelAttemptedDropRetry()
        model.didAttemptDrop = false
        requestedPermission = permission
        installObserversIfNeeded()
        startRefreshTimerIfNeeded()
        refreshPresentation()
    }

    func dismiss() {
        requestedPermission = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        cancelAttemptedDropRetry()

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
        guard let requestedPermission else {
            dismiss()
            return
        }

        if requestedPermission.isGranted {
            dismiss()
            return
        }

        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let settingsWindow = SystemSettingsWindowLocator.mainWindowFrame()
        let frames = settingsWindow.flatMap {
            AccessibilityPermissionGuideLayout.frames(for: $0)
        }
        setPresenting(AccessibilityPermissionGuideSuppressionPolicy.shouldSuppressOnboarding(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: frontmostBundleID,
            muesliBundleID: Bundle.main.bundleIdentifier,
            hasUsableGuide: frames != nil,
            isCurrentlySuppressed: isPresenting
        ))
        guard AccessibilityPermissionGuidePresentationPolicy.shouldShow(
            isRequested: true,
            isGranted: false,
            frontmostBundleID: frontmostBundleID,
            hasSettingsWindow: frames != nil
        ), let frames else {
            hidePanels()
            return
        }

        ensurePanels()
        model.dragDirection = frames.dragDirection
        if model.didAttemptDrop {
            guidePanel?.setFrame(frames.postDropGuide, display: true)
            dragPanel?.orderOut(nil)
        } else {
            guidePanel?.setFrame(frames.guide, display: true)
            dragPanel?.setFrame(frames.dragSource, display: true)
        }
        guidePanel?.orderFrontRegardless()
        if !model.didAttemptDrop {
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
            dragView.onDragEnded = { [weak self] screenPoint, operation in
                guard let self else { return }
                let isLikelyPermissionListDropAttempt = AccessibilityPermissionGuideDropPolicy
                    .isLikelyPermissionListDropAttempt(
                    operationAccepted: !operation.isEmpty,
                    dropPoint: screenPoint,
                    frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                    settingsWindow: SystemSettingsWindowLocator.mainWindowFrame()
                )
                guard isLikelyPermissionListDropAttempt else {
                    self.cancelAttemptedDropRetry()
                    self.model.didAttemptDrop = false
                    self.refreshPresentation()
                    return
                }
                // AppKit tells a dragging source that some destination accepted
                // the URL, but not which System Settings view accepted it. Treat
                // this as an attempted drop, never as proof that Muesli was added.
                self.model.didAttemptDrop = true
                self.scheduleAttemptedDropRetry()
                self.refreshPresentation()
            }
            dragPanel = makePanel(
                frame: .zero,
                ignoresMouseEvents: false,
                contentView: dragView
            )
        }
    }

    private func scheduleAttemptedDropRetry() {
        cancelAttemptedDropRetry()

        let timer = Timer(
            timeInterval: AccessibilityPermissionGuideRetryPolicy.attemptedDropRetryDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.attemptedDropRetryTimer = nil
                guard let requestedPermission = self.requestedPermission,
                      AccessibilityPermissionGuideRetryPolicy.shouldRestoreDragSource(
                        didAttemptDrop: self.model.didAttemptDrop,
                        isGranted: requestedPermission.isGranted
                      ) else {
                    return
                }

                self.model.didAttemptDrop = false
                self.refreshPresentation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        attemptedDropRetryTimer = timer
    }

    private func cancelAttemptedDropRetry() {
        attemptedDropRetryTimer?.invalidate()
        attemptedDropRetryTimer = nil
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
    @Published var didAttemptDrop = false
    @Published var dragDirection: PermissionGuideDragDirection = .up
}

private struct CompactAccessibilityPermissionGuideView: View {
    let appName: String
    @ObservedObject var model: AccessibilityPermissionGuideModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrowIsDisplaced = false

    var body: some View {
        Group {
            if model.didAttemptDrop {
                HStack(spacing: 10) {
                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(MuesliTheme.accent)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(AccessibilityPermissionGuideCopy.attemptedDropTitle(appName: appName))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.94))
                        Text(AccessibilityPermissionGuideCopy.attemptedDropDetail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.62))
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: model.dragDirection.symbolName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(MuesliTheme.accent)
                            .offset(y: arrowOffset)

                        Text(model.dragDirection.instruction)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }

                    Spacer(minLength: 82)
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: NSColor(red: 0.10, green: 0.12, blue: 0.14, alpha: 0.91)))
        .clipShape(RoundedRectangle(cornerRadius: model.didAttemptDrop ? 14 : 18))
        .overlay(
            RoundedRectangle(cornerRadius: model.didAttemptDrop ? 14 : 18)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
        .padding(2)
        .onAppear { startArrowAnimation() }
        .onChange(of: model.dragDirection) { _, _ in
            arrowIsDisplaced = false
            startArrowAnimation()
        }
    }

    private var arrowOffset: CGFloat {
        guard !reduceMotion else { return 0 }
        let displacement: CGFloat = arrowIsDisplaced ? 4 : -1
        return model.dragDirection == .up ? -displacement : displacement
    }

    private func startArrowAnimation() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
            arrowIsDisplaced = true
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

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))

            Text(appName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.94))

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

@MainActor
private final class AccessibilityPermissionDragSourceView: NSView, NSDraggingSource {
    var onDragEnded: ((NSPoint, NSDragOperation) -> Void)?

    private let appURL: URL
    private var mouseDownLocation: CGPoint?
    private var hasStartedDrag = false
    private var cursorTrackingArea: NSTrackingArea?

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
        toolTip = "Drag \(appName) into the permission list"
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea {
            removeTrackingArea(cursorTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        (hasStartedDrag ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        hasStartedDrag = false
        NSCursor.closedHand.set()
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
        NSCursor.openHand.set()
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
        NSCursor.openHand.set()
        onDragEnded?(screenPoint, operation)
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
