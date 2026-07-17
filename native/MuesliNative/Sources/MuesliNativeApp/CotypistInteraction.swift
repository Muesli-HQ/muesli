import AppKit
import ApplicationServices
import Foundation

enum CotypistState: Equatable, Sendable {
    case idle
    case generating
    case previewing(CotypistCompletion)
    case accepting
    case failed(String)

    var isGenerating: Bool { self == .generating }
    var isPreviewing: Bool {
        if case .previewing = self { return true }
        return false
    }
}

struct CotypistEventModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt

    static let command = CotypistEventModifiers(rawValue: 1 << 0)
    static let control = CotypistEventModifiers(rawValue: 1 << 1)
    static let option = CotypistEventModifiers(rawValue: 1 << 2)
    static let shift = CotypistEventModifiers(rawValue: 1 << 3)

    static func from(_ flags: CGEventFlags) -> CotypistEventModifiers {
        var result: CotypistEventModifiers = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }

    static func from(_ flags: NSEvent.ModifierFlags) -> CotypistEventModifiers {
        var result: CotypistEventModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}

enum CotypistInputEvent: Equatable, Sendable {
    case keyDown(keyCode: UInt16, modifiers: CotypistEventModifiers, isRepeat: Bool)
    case keyUp(keyCode: UInt16)
    case flagsChanged
    case mouseDown
    case scroll
    case tapDisabled
}

enum CotypistEventAction: Equatable, Sendable {
    case pass
    case passAndInvalidate
    case consume
    case consumeAndInvoke
    case consumeAndAccept
    case consumeAndCancel
    case recoverTap
}

struct CotypistEventPolicy: Sendable {
    static let tabKeyCode: UInt16 = 48
    static let escapeKeyCode: UInt16 = 53

    var isEnabled = false
    var isGenerating = false
    var isPreviewing = false
    var invocationKeyCode: UInt16 = 8
    var invocationModifiers: CotypistEventModifiers = [.control, .option]

    private var consumedKeyUps: Set<UInt16> = []

    init(
        isEnabled: Bool = false,
        isGenerating: Bool = false,
        isPreviewing: Bool = false,
        invocationKeyCode: UInt16 = 8,
        invocationModifiers: CotypistEventModifiers = [.control, .option]
    ) {
        self.isEnabled = isEnabled
        self.isGenerating = isGenerating
        self.isPreviewing = isPreviewing
        self.invocationKeyCode = invocationKeyCode
        self.invocationModifiers = invocationModifiers
    }

    mutating func handle(_ event: CotypistInputEvent) -> CotypistEventAction {
        switch event {
        case .tapDisabled:
            return .recoverTap
        case .keyUp(let keyCode):
            if consumedKeyUps.remove(keyCode) != nil { return .consume }
            return .pass
        case .flagsChanged:
            return .pass
        case .mouseDown, .scroll:
            return (isGenerating || isPreviewing) ? .passAndInvalidate : .pass
        case .keyDown(let keyCode, let modifiers, let isRepeat):
            if isEnabled, keyCode == invocationKeyCode, modifiers == invocationModifiers {
                consumedKeyUps.insert(keyCode)
                return isRepeat ? .consume : .consumeAndInvoke
            }
            if (isGenerating || isPreviewing), keyCode == Self.escapeKeyCode, modifiers.isEmpty {
                consumedKeyUps.insert(keyCode)
                return .consumeAndCancel
            }
            if isPreviewing, keyCode == Self.tabKeyCode, modifiers.isEmpty {
                consumedKeyUps.insert(keyCode)
                return .consumeAndAccept
            }
            return (isGenerating || isPreviewing) ? .passAndInvalidate : .pass
        }
    }
}

final class CotypistEventTap: @unchecked Sendable {
    struct Snapshot {
        var policy = CotypistEventPolicy()
    }

    var onInvoke: (@Sendable () -> Void)?
    var onAccept: (@Sendable () -> Void)?
    var onCancel: (@Sendable () -> Void)?
    var onInvalidate: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    deinit { stop() }

    func update(enabled: Bool, hotkey: HotkeyConfig, state: CotypistState) {
        lock.lock()
        snapshot.policy.isEnabled = enabled
        snapshot.policy.isGenerating = state.isGenerating
        snapshot.policy.isPreviewing = state.isPreviewing
        if let keyCode = hotkey.combinationKeyCode,
           let modifiers = hotkey.resolvedCombinationModifiers {
            snapshot.policy.invocationKeyCode = keyCode
            snapshot.policy.invocationModifiers = .from(modifiers)
        }
        lock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = [
            CGEventType.keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.source = nil
        self.tap = nil
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<CotypistEventTap>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let input: CotypistInputEvent
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            input = .tapDisabled
        case .keyDown:
            input = .keyDown(
                keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                modifiers: .from(event.flags),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        case .keyUp:
            input = .keyUp(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)))
        case .flagsChanged:
            input = .flagsChanged
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            input = .mouseDown
        case .scrollWheel:
            input = .scroll
        default:
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        let action = snapshot.policy.handle(input)
        lock.unlock()

        switch action {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .passAndInvalidate:
            DispatchQueue.main.async { [weak self] in self?.onInvalidate?() }
            return Unmanaged.passUnretained(event)
        case .consume:
            return nil
        case .consumeAndInvoke:
            DispatchQueue.main.async { [weak self] in self?.onInvoke?() }
            return nil
        case .consumeAndAccept:
            DispatchQueue.main.async { [weak self] in self?.onAccept?() }
            return nil
        case .consumeAndCancel:
            DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            return nil
        case .recoverTap:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
    }
}

enum CotypistPreviewMode: Equatable {
    case ghost
    case capsule
}

enum CotypistPreviewPresentation {
    static func mode(
        text: String,
        isLoading: Bool,
        geometryConfidence: FocusedTextCaretGeometryConfidence,
        presentationStyle: FocusedTextPresentationStyle?
    ) -> CotypistPreviewMode {
        guard !isLoading,
              !text.contains(where: \.isNewline),
              geometryConfidence != .unavailable,
              presentationStyle?.supportsInlineGhost == true else { return .capsule }
        return .ghost
    }
}

enum CotypistOverlayPlacement {
    static func frame(
        caretBounds: CGRect?,
        elementBounds: CGRect?,
        panelSize: CGSize,
        screenFrames: [CGRect],
        visibleFrames: [CGRect],
        primaryScreenMaxY: CGFloat,
        fallbackPoint: CGPoint
    ) -> CGRect {
        if let caretBounds, isUsableCaretBounds(caretBounds),
           let placement = capsulePlacement(
               quartzBounds: caretBounds,
               horizontalAnchor: caretBounds.maxX + 6,
               panelSize: panelSize,
               screenFrames: screenFrames,
               visibleFrames: visibleFrames,
               primaryScreenMaxY: primaryScreenMaxY
           ) {
            return placement
        }

        if let elementBounds, isUsableElementBounds(elementBounds),
           let placement = capsulePlacement(
               quartzBounds: elementBounds,
               horizontalAnchor: elementBounds.minX + 8,
               panelSize: panelSize,
               screenFrames: screenFrames,
               visibleFrames: visibleFrames,
               primaryScreenMaxY: primaryScreenMaxY
           ) {
            return placement
        }

        return fallbackFrame(panelSize: panelSize, fallbackPoint: fallbackPoint, visibleFrames: visibleFrames)
    }

    static func ghostFrame(
        caretBounds: CGRect?,
        elementBounds: CGRect?,
        panelSize: CGSize,
        screenFrames: [CGRect],
        visibleFrames: [CGRect],
        primaryScreenMaxY: CGFloat
    ) -> CGRect? {
        guard let caretBounds, isUsableCaretBounds(caretBounds),
              let converted = AccessibilityScreenGeometry.appKitPoint(
                  forQuartzPoint: CGPoint(x: caretBounds.maxX + 2, y: caretBounds.minY),
                  screenFrames: screenFrames,
                  primaryScreenMaxY: primaryScreenMaxY,
                  tolerance: 8
              ) else { return nil }
        let visible = visibleFrames.indices.contains(converted.screenIndex)
            ? visibleFrames[converted.screenIndex]
            : visibleFrames.first
        guard let visible else { return nil }

        var rightEdge = visible.maxX - 4
        if let elementBounds, isUsableElementBounds(elementBounds), elementBounds.maxX > converted.point.x {
            rightEdge = min(rightEdge, elementBounds.maxX - 4)
        }
        let availableWidth = rightEdge - converted.point.x
        guard availableWidth >= 40 else { return nil }

        let size = CGSize(width: min(panelSize.width, availableWidth), height: panelSize.height)
        let origin = CGPoint(x: converted.point.x, y: converted.point.y - size.height + 2)
        guard origin.y >= visible.minY + 2, origin.y + size.height <= visible.maxY + 2 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func capsulePlacement(
        quartzBounds: CGRect,
        horizontalAnchor: CGFloat,
        panelSize: CGSize,
        screenFrames: [CGRect],
        visibleFrames: [CGRect],
        primaryScreenMaxY: CGFloat
    ) -> CGRect? {
        guard let convertedTop = AccessibilityScreenGeometry.appKitPoint(
            forQuartzPoint: CGPoint(x: quartzBounds.minX, y: quartzBounds.minY),
            screenFrames: screenFrames,
            primaryScreenMaxY: primaryScreenMaxY,
            tolerance: 8
        ) else { return nil }
        let visible = visibleFrames.indices.contains(convertedTop.screenIndex)
            ? visibleFrames[convertedTop.screenIndex]
            : visibleFrames.first
        let appKitBounds = CGRect(
            x: quartzBounds.minX,
            y: primaryScreenMaxY - quartzBounds.maxY,
            width: quartzBounds.width,
            height: quartzBounds.height
        )
        var origin = CGPoint(x: horizontalAnchor, y: appKitBounds.minY - panelSize.height - 6)
        if let visible {
            if origin.y < visible.minY + 4 { origin.y = appKitBounds.maxY + 6 }
        }
        return fit(CGRect(origin: origin, size: panelSize), in: visible)
    }

    private static func fallbackFrame(
        panelSize: CGSize,
        fallbackPoint: CGPoint,
        visibleFrames: [CGRect]
    ) -> CGRect {
        let visible = visibleFrames.first(where: { $0.contains(fallbackPoint) }) ?? visibleFrames.first
        return fit(
            CGRect(
                origin: CGPoint(x: fallbackPoint.x + 8, y: fallbackPoint.y - panelSize.height / 2),
                size: panelSize
            ),
            in: visible
        )
    }

    private static func isUsableCaretBounds(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && !rect.isNull && rect.width >= 0 && rect.height > 0
    }

    private static func isUsableElementBounds(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && !rect.isNull && rect.width > 0 && rect.height > 0
    }

    private static func fit(_ frame: CGRect, in visible: CGRect?) -> CGRect {
        guard let visible else { return frame }
        var origin = frame.origin
        origin.x = min(max(origin.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - frame.width - 4))
        origin.y = min(max(origin.y, visible.minY + 4), max(visible.minY + 4, visible.maxY - frame.height - 4))
        return CGRect(origin: origin, size: frame.size)
    }
}

@MainActor
final class CotypistPreviewPanel {
    private let panel: NonactivatingOverlayPanel
    private let previewView: CotypistPreviewView

    init() {
        previewView = CotypistPreviewView(frame: CGRect(x: 0, y: 0, width: 120, height: 28))
        panel = NonactivatingOverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 25),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = previewView
    }

    func show(
        text: String,
        context: FocusedTextContext,
        isLoading: Bool = false,
        quality: CotypistCompletionQuality = .normal
    ) {
        let screens = NSScreen.screens
        var mode = CotypistPreviewPresentation.mode(
            text: text,
            isLoading: isLoading,
            geometryConfidence: context.caretGeometryConfidence,
            presentationStyle: context.presentationStyle
        )
        var font = Self.font(for: context.presentationStyle, mode: mode)
        var textColor = Self.textColor(
            for: context.presentationStyle,
            mode: mode,
            isLoading: isLoading,
            quality: quality
        )
        previewView.configure(text: text, mode: mode, font: font, textColor: textColor, isLoading: isLoading)
        var size = previewView.preferredSize(maxWidth: mode == .ghost ? 520 : 430)

        var frame = mode == .ghost ? CotypistOverlayPlacement.ghostFrame(
            caretBounds: context.caretBounds,
            elementBounds: context.elementBounds,
            panelSize: size,
            screenFrames: screens.map(\.frame),
            visibleFrames: screens.map(\.visibleFrame),
            primaryScreenMaxY: screens.first?.frame.maxY ?? 0
        ) : nil

        if frame == nil {
            mode = .capsule
            font = Self.font(for: context.presentationStyle, mode: mode)
            textColor = Self.textColor(
                for: context.presentationStyle,
                mode: mode,
                isLoading: isLoading,
                quality: quality
            )
            previewView.configure(text: text, mode: mode, font: font, textColor: textColor, isLoading: isLoading)
            size = previewView.preferredSize(maxWidth: 430)
            frame = CotypistOverlayPlacement.frame(
                caretBounds: context.caretBounds,
                elementBounds: context.elementBounds,
                panelSize: size,
                screenFrames: screens.map(\.frame),
                visibleFrames: screens.map(\.visibleFrame),
                primaryScreenMaxY: screens.first?.frame.maxY ?? 0,
                fallbackPoint: NSEvent.mouseLocation
            )
        }

        guard let frame else { return }
        panel.hasShadow = mode == .capsule
        let wasVisible = panel.isVisible
        panel.setFrame(frame, display: true)
        previewView.frame = CGRect(origin: .zero, size: frame.size)
        previewView.needsDisplay = true
        if !wasVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.1
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private static func font(
        for style: FocusedTextPresentationStyle?,
        mode: CotypistPreviewMode
    ) -> NSFont {
        guard mode == .ghost, let size = style?.fontSize else {
            return .systemFont(ofSize: 13, weight: .regular)
        }
        let clampedSize = min(max(size, 7), 96)
        if let name = style?.fontName, let font = NSFont(name: name, size: clampedSize) {
            return font
        }
        return .systemFont(ofSize: clampedSize, weight: .regular)
    }

    private static func textColor(
        for style: FocusedTextPresentationStyle?,
        mode: CotypistPreviewMode,
        isLoading: Bool,
        quality: CotypistCompletionQuality
    ) -> NSColor {
        if !isLoading, quality == .contextEcho {
            return mode == .ghost
                ? NSColor.systemRed.withAlphaComponent(0.82)
                : NSColor.systemRed
        }
        guard mode == .ghost else { return isLoading ? .secondaryLabelColor : .labelColor }
        if let foreground = style?.foregroundColor {
            return foreground.nsColor.withAlphaComponent(min(max(foreground.alpha * 0.48, 0.34), 0.58))
        }
        let isLightBackground = (style?.backgroundColor?.relativeLuminance ?? 1) > 0.52
        return (isLightBackground ? NSColor.black : NSColor.white).withAlphaComponent(0.48)
    }
}

private final class CotypistPreviewView: NSView {
    private var text = ""
    private var mode = CotypistPreviewMode.capsule
    private var font = NSFont.systemFont(ofSize: 13)
    private var textColor = NSColor.labelColor
    private var isLoading = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func configure(
        text: String,
        mode: CotypistPreviewMode,
        font: NSFont,
        textColor: NSColor,
        isLoading: Bool
    ) {
        self.text = text
        self.mode = mode
        self.font = font
        self.textColor = textColor
        self.isLoading = isLoading
        needsDisplay = true
    }

    func preferredSize(maxWidth: CGFloat) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if mode == .ghost {
            let measured = ceil((text as NSString).size(withAttributes: attributes).width)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            return CGSize(width: min(max(measured + 2, 1), maxWidth), height: max(lineHeight, 16))
        }

        let keycapWidth: CGFloat = isLoading ? 0 : 38
        let horizontalInsets: CGFloat = 20
        let textLimit = max(80, maxWidth - horizontalInsets - keycapWidth)
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: textLimit, height: 58),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: attributes
        )
        let width = min(max(ceil(measured.width) + horizontalInsets + keycapWidth, isLoading ? 108 : 120), maxWidth)
        let height = min(max(ceil(measured.height) + 12, 28), 70)
        return CGSize(width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        switch mode {
        case .ghost:
            drawGhost()
        case .capsule:
            drawCapsule()
        }
    }

    private func drawGhost() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let lineHeight = font.ascender - font.descender + font.leading
        let y = max(0, floor((bounds.height - lineHeight) / 2))
        NSAttributedString(string: text, attributes: attributes).draw(at: CGPoint(x: 0, y: y))
    }

    private func drawCapsule() {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        background.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        background.lineWidth = 1
        background.stroke()

        let keycapWidth: CGFloat = isLoading ? 0 : 32
        let textRect = CGRect(
            x: 10,
            y: 6,
            width: max(1, bounds.width - 20 - (isLoading ? 0 : keycapWidth + 6)),
            height: max(1, bounds.height - 12)
        )
        (text as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: textColor]
        )

        guard !isLoading else { return }
        let keycapRect = CGRect(x: bounds.maxX - keycapWidth - 8, y: (bounds.height - 20) / 2, width: keycapWidth, height: 20)
        let keycap = NSBezierPath(roundedRect: keycapRect, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.withAlphaComponent(0.88).setFill()
        keycap.fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        keycap.lineWidth = 1
        keycap.stroke()
        let keycapText = "Tab" as NSString
        let keycapFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let textSize = keycapText.size(withAttributes: [.font: keycapFont])
        keycapText.draw(
            at: CGPoint(x: keycapRect.midX - textSize.width / 2, y: keycapRect.midY - textSize.height / 2),
            withAttributes: [.font: keycapFont, .foregroundColor: NSColor.secondaryLabelColor]
        )
    }
}

private extension FocusedTextColor {
    var nsColor: NSColor {
        NSColor(deviceRed: red, green: green, blue: blue, alpha: alpha)
    }
}

@MainActor
final class CotypistCoordinator {
    private static let loadingPresentationDelay = Duration.milliseconds(250)

    private let transcriptionRuntime: TranscriptionCoordinator
    private let contextService: FocusedTextContextService
    private let eventTap = CotypistEventTap()
    private let previewPanel = CotypistPreviewPanel()
    private var config = AppConfig()
    private var requestTask: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?
    private var requestID: UUID?
    private var previewContext: FocusedTextContext?
    private var workspaceObserver: NSObjectProtocol?

    private(set) var state: CotypistState = .idle {
        didSet { eventTap.update(enabled: config.enableCotypist, hotkey: config.cotypistHotkey, state: state) }
    }

    init(
        transcriptionRuntime: TranscriptionCoordinator,
        contextService: FocusedTextContextService = FocusedTextContextService()
    ) {
        self.transcriptionRuntime = transcriptionRuntime
        self.contextService = contextService
        eventTap.onInvoke = { [weak self] in Task { @MainActor in self?.invoke() } }
        eventTap.onAccept = { [weak self] in Task { @MainActor in self?.accept() } }
        eventTap.onCancel = { [weak self] in Task { @MainActor in self?.cancel() } }
        eventTap.onInvalidate = { [weak self] in Task { @MainActor in self?.cancel() } }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    deinit {
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
    }

    func update(config: AppConfig) {
        let previousModel = self.config.resolvedCotypistModel
        let wasEnabled = self.config.enableCotypist
        self.config = config
        eventTap.update(enabled: config.enableCotypist, hotkey: config.cotypistHotkey, state: state)

        guard config.enableCotypist else {
            eventTap.stop()
            cancel()
            if wasEnabled {
                Task { await transcriptionRuntime.unloadCotypist() }
            }
            return
        }
        guard config.cotypistHotkey.isCombination, eventTap.start() else {
            fail("Cotypist needs Accessibility and Input Monitoring permission")
            return
        }
        if previousModel != config.resolvedCotypistModel || !wasEnabled {
            cancel()
            Task { [model = config.resolvedCotypistModel] in
                try? await transcriptionRuntime.prepareCotypist(model: model)
            }
        }
    }

    func shutdown() {
        eventTap.stop()
        cancel()
        Task { await transcriptionRuntime.unloadCotypist() }
    }

    func invoke() {
        guard config.enableCotypist, config.resolvedCotypistModel.isDownloaded else { return }
        requestTask?.cancel()
        loadingTask?.cancel()
        previewPanel.hide()
        let excluded = Set(config.cotypistExcludedBundleIDs)
        guard let context = contextService.capture(excludedBundleIDs: excluded) else {
            fail("No supported text field at the cursor")
            return
        }

        let id = UUID()
        requestID = id
        previewContext = nil
        state = .generating
        loadingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.loadingPresentationDelay)
                guard let self, requestID == id, state.isGenerating else { return }
                previewPanel.show(text: "Completing…", context: context, isLoading: true)
            } catch {
                return
            }
        }
        let request = CotypistCompletionRequest(context: context, model: config.resolvedCotypistModel)
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let completion = try await transcriptionRuntime.completeText(request: request)
                try Task.checkCancellation()
                guard requestID == id,
                      let fresh = contextService.capture(excludedBundleIDs: excluded),
                      fresh.fingerprint == context.fingerprint else {
                    cancel()
                    return
                }
                loadingTask?.cancel()
                loadingTask = nil
                previewContext = fresh
                state = .previewing(completion)
                previewPanel.show(
                    text: completion.text,
                    context: fresh,
                    quality: completion.quality
                )
            } catch is CancellationError {
                if requestID == id { resetUI() }
            } catch {
                if requestID == id { fail(error.localizedDescription) }
            }
        }
    }

    func accept() {
        guard case .previewing(let completion) = state, let expected = previewContext else { return }
        state = .accepting
        previewPanel.hide()
        loadingTask?.cancel()
        loadingTask = nil
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        previewContext = nil

        let fresh = contextService.capture(excludedBundleIDs: Set(config.cotypistExcludedBundleIDs))
        guard fresh?.fingerprint == expected.fingerprint else {
            state = .idle
            return
        }
        state = .idle
        PasteController.typeText(completion.text)
    }

    func cancel() {
        let hadActiveRequest = requestTask != nil || state != .idle
        loadingTask?.cancel()
        loadingTask = nil
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        previewContext = nil
        resetUI()
        if hadActiveRequest {
            Task { await transcriptionRuntime.cancelCotypistCompletion() }
        }
    }

    private func fail(_ message: String) {
        loadingTask?.cancel()
        loadingTask = nil
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        previewContext = nil
        state = .failed(message)
        previewPanel.hide()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, case .failed = state else { return }
            state = .idle
        }
    }

    private func resetUI() {
        loadingTask?.cancel()
        loadingTask = nil
        previewPanel.hide()
        state = .idle
    }
}
