import AppKit
import ApplicationServices
import Foundation

enum CotypistState: Equatable, Sendable {
    case idle
    case generating
    case previewing(String)
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
           let placement = placement(
               quartzAnchor: CGPoint(x: caretBounds.maxX + 3, y: caretBounds.minY),
               panelSize: panelSize,
               screenFrames: screenFrames,
               visibleFrames: visibleFrames,
               primaryScreenMaxY: primaryScreenMaxY
           ) {
            return placement
        }

        if let elementBounds, isUsableElementBounds(elementBounds),
           let placement = placement(
               quartzAnchor: CGPoint(x: elementBounds.minX + 8, y: elementBounds.maxY - 8),
               panelSize: panelSize,
               screenFrames: screenFrames,
               visibleFrames: visibleFrames,
               primaryScreenMaxY: primaryScreenMaxY
           ) {
            return placement
        }

        return fallbackFrame(panelSize: panelSize, fallbackPoint: fallbackPoint, visibleFrames: visibleFrames)
    }

    private static func placement(
        quartzAnchor: CGPoint,
        panelSize: CGSize,
        screenFrames: [CGRect],
        visibleFrames: [CGRect],
        primaryScreenMaxY: CGFloat
    ) -> CGRect? {
        guard quartzAnchor.x.isFinite, quartzAnchor.y.isFinite, primaryScreenMaxY.isFinite else { return nil }
        let appKitAnchor = CGPoint(x: quartzAnchor.x, y: primaryScreenMaxY - quartzAnchor.y)
        // AX geometry uses a top-left global origin while AppKit uses a
        // bottom-left origin. Reject geometry that does not map to any display;
        // otherwise a bogus (often zero) AX rect gets clamped into a corner.
        guard let screenIndex = screenFrames.firstIndex(where: {
            $0.insetBy(dx: -8, dy: -8).contains(appKitAnchor)
        }) else { return nil }
        let visible = visibleFrames.indices.contains(screenIndex) ? visibleFrames[screenIndex] : visibleFrames.first
        var origin = CGPoint(x: appKitAnchor.x, y: appKitAnchor.y - panelSize.height + 2)
        if let visible {
            if origin.x + panelSize.width > visible.maxX { origin.x = appKitAnchor.x - panelSize.width - 5 }
            if origin.y < visible.minY { origin.y = appKitAnchor.y + 8 }
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
    private let panel: NSPanel
    private let label: NSTextField

    init() {
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabelColor.withAlphaComponent(0.78)
        label.backgroundColor = .clear
        label.isSelectable = false
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail

        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 25),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = label
    }

    func show(text: String, context: FocusedTextContext, isLoading: Bool = false) {
        label.stringValue = text
        label.textColor = isLoading
            ? .tertiaryLabelColor
            : .secondaryLabelColor.withAlphaComponent(0.78)
        let measured = label.sizeThatFits(CGSize(width: 520, height: 90))
        let size = CGSize(width: min(max(measured.width + 8, 40), 520), height: min(max(measured.height + 4, 22), 90))
        let screens = NSScreen.screens
        let frame = CotypistOverlayPlacement.frame(
            caretBounds: context.caretBounds,
            elementBounds: context.elementBounds,
            panelSize: size,
            screenFrames: screens.map(\.frame),
            visibleFrames: screens.map(\.visibleFrame),
            primaryScreenMaxY: screens.first?.frame.maxY ?? 0,
            fallbackPoint: NSEvent.mouseLocation
        )
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

@MainActor
final class CotypistCoordinator {
    private let transcriptionRuntime: TranscriptionCoordinator
    private let contextService: FocusedTextContextService
    private let eventTap = CotypistEventTap()
    private let previewPanel = CotypistPreviewPanel()
    private var config = AppConfig()
    private var requestTask: Task<Void, Never>?
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
        let excluded = Set(config.cotypistExcludedBundleIDs)
        guard let context = contextService.capture(excludedBundleIDs: excluded) else {
            fail("No supported text field at the cursor")
            return
        }

        let id = UUID()
        requestID = id
        previewContext = nil
        state = .generating
        previewPanel.show(text: "Completing…", context: context, isLoading: true)
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
                previewContext = fresh
                state = .previewing(completion)
                previewPanel.show(text: completion, context: fresh)
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
        PasteController.typeText(completion)
    }

    func cancel() {
        let hadActiveRequest = requestTask != nil || state != .idle
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
        previewPanel.hide()
        state = .idle
    }
}
