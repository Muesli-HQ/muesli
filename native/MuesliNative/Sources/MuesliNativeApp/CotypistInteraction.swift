import AppKit
import ApplicationServices
import Foundation
import os

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

/// A key event that may change the text immediately before the focused caret.
///
/// The event tap never consumes these events. They are only used to schedule a
/// debounced ambient request after the target application has handled the edit.
struct CotypistTypingEvent: Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: CotypistEventModifiers
    let isRepeat: Bool

    /// Hardware key codes for printable keys plus backward/forward delete.
    /// Tab, Escape, arrows, and other navigation keys are deliberately
    /// excluded so ordinary navigation does not start a completion. Return is
    /// retained because a new paragraph is a legitimate text edit.
    private static let textEditKeyCodes: Set<UInt16> =
        Set(0...47).union([49, 50, 51, 76, 117])

    var isLikelyTextEdit: Bool {
        guard !isRepeat,
              modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        return Self.textEditKeyCodes.contains(keyCode)
    }

    init?(input: CotypistInputEvent) {
        guard case .keyDown(let keyCode, let modifiers, let isRepeat) = input else { return nil }
        self.init(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)
    }

    init(keyCode: UInt16, modifiers: CotypistEventModifiers = [], isRepeat: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isRepeat = isRepeat
    }
}

/// The ambient experience deliberately has a small, learnable trigger surface:
/// finish a word or thought with whitespace or punctuation, then pause. The
/// focused-text prefix is inspected after the target app handles the key event,
/// so this works with different keyboard layouts without decoding hardware keys.
struct CotypistAmbientSuggestionPolicy: Sendable {
    static let idleDelay = Duration.milliseconds(750)
    private static let boundaryPunctuation = CharacterSet(
        charactersIn: ".,;:!?)]}\"'…’”"
    )

    static func isEligible(prefix: String) -> Bool {
        guard let lastCharacter = prefix.last else { return false }
        return lastCharacter.unicodeScalars.contains { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                || boundaryPunctuation.contains(scalar)
        }
    }
}

/// A small process-memory cache. Suggestions never leave the running app and
/// expire quickly. Besides exact matches, a completion can be reused when the
/// user types its beginning and the focused suffix still matches.
struct CotypistCompletionCache {
    private struct Entry {
        let fingerprint: FocusedTextFingerprint
        let model: CotypistModelOption
        let completion: CotypistCompletion
        let createdAt: Date
    }

    private let timeToLive: TimeInterval
    private let capacity: Int
    private var entries: [Entry] = []

    init(timeToLive: TimeInterval = 45, capacity: Int = 8) {
        self.timeToLive = max(0, timeToLive)
        self.capacity = max(1, capacity)
    }

    mutating func completion(
        for context: FocusedTextContext,
        model: CotypistModelOption,
        now: Date = Date()
    ) -> CotypistCompletion? {
        removeExpiredEntries(at: now)
        for entry in entries.reversed() where entry.model == model {
            if entry.fingerprint == context.fingerprint {
                return entry.completion
            }
            guard entry.fingerprint.processID == context.fingerprint.processID,
                  entry.fingerprint.elementIdentifier == context.fingerprint.elementIdentifier,
                  entry.fingerprint.suffix == context.fingerprint.suffix,
                  context.fingerprint.prefix.hasPrefix(entry.fingerprint.prefix) else { continue }

            let consumedCount = context.fingerprint.prefix.count - entry.fingerprint.prefix.count
            guard consumedCount > 0 else { continue }
            let consumed = String(context.fingerprint.prefix.suffix(consumedCount))
            guard entry.completion.text.hasPrefix(consumed) else { continue }
            let remainder = String(entry.completion.text.dropFirst(consumed.count))
            guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return CotypistCompletion(text: remainder, quality: entry.completion.quality)
        }
        return nil
    }

    mutating func store(
        _ completion: CotypistCompletion,
        for context: FocusedTextContext,
        model: CotypistModelOption,
        now: Date = Date()
    ) {
        removeExpiredEntries(at: now)
        entries.removeAll { $0.model == model && $0.fingerprint == context.fingerprint }
        entries.append(Entry(
            fingerprint: context.fingerprint,
            model: model,
            completion: completion,
            createdAt: now
        ))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }

    private mutating func removeExpiredEntries(at now: Date) {
        entries.removeAll { now.timeIntervalSince($0.createdAt) > timeToLive }
    }
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
    var isAmbientWaiting = false
    var isGenerating = false
    var isPreviewing = false
    var invocationKeyCode: UInt16 = 8
    var invocationModifiers: CotypistEventModifiers = [.control, .option]

    private var consumedKeyUps: Set<UInt16> = []

    init(
        isEnabled: Bool = false,
        isAmbientWaiting: Bool = false,
        isGenerating: Bool = false,
        isPreviewing: Bool = false,
        invocationKeyCode: UInt16 = 8,
        invocationModifiers: CotypistEventModifiers = [.control, .option]
    ) {
        self.isEnabled = isEnabled
        self.isAmbientWaiting = isAmbientWaiting
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
            return (isAmbientWaiting || isGenerating || isPreviewing) ? .passAndInvalidate : .pass
        case .keyDown(let keyCode, let modifiers, let isRepeat):
            if isEnabled, keyCode == invocationKeyCode, modifiers == invocationModifiers {
                consumedKeyUps.insert(keyCode)
                if isGenerating || isPreviewing {
                    return .consumeAndAccept
                }
                return isRepeat ? .consume : .consumeAndInvoke
            }
            if (isGenerating || isPreviewing), keyCode == Self.escapeKeyCode, modifiers.isEmpty {
                consumedKeyUps.insert(keyCode)
                return .consumeAndCancel
            }
            // Consume acceptance while generation is pending as well as while
            // the preview is visible. The coordinator queues the acceptance and
            // inserts once the result is ready, preventing submit-on-Tab hosts
            // such as Codex from receiving the original key event.
            if (isGenerating || isPreviewing),
               keyCode == Self.tabKeyCode,
               modifiers.intersection([.command, .control, .shift]).isEmpty {
                consumedKeyUps.insert(keyCode)
                return .consumeAndAccept
            }
            return (isAmbientWaiting || isGenerating || isPreviewing) ? .passAndInvalidate : .pass
        }
    }
}

final class CotypistEventTap: @unchecked Sendable {
    struct Snapshot {
        var policy = CotypistEventPolicy()
        var previewHitFrame: CGRect?
    }

    var onInvoke: (@Sendable () -> Void)?
    var onAccept: (@Sendable () -> Void)?
    var onCancel: (@Sendable () -> Void)?
    var onInvalidate: (@Sendable () -> Void)?
    var onTyping: (@Sendable (CotypistTypingEvent) -> Void)?

    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var eventThread: Thread?
    private var eventRunLoop: CFRunLoop?

    private static let logger = Logger(subsystem: "com.muesli.native", category: "CotypistInput")
    private static let diagnosticsQueue = DispatchQueue(
        label: "com.muesli.cotypist.input-diagnostics",
        qos: .utility
    )

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

    func updateAmbientWaiting(_ isWaiting: Bool) {
        lock.lock()
        snapshot.policy.isAmbientWaiting = isWaiting
        lock.unlock()
    }

    func updatePreviewHitFrame(_ frame: CGRect?) {
        lock.lock()
        snapshot.previewHitFrame = frame
        lock.unlock()
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = [
            CGEventType.keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        // Prefer the HID stream so acceptance keys are removed before hosts
        // with submit-on-Tab behavior (for example Codex) see them. Keep the
        // session stream as a compatibility fallback for environments where a
        // HID tap is unavailable.
        var selectedLocation: CGEventTapLocation?
        var newTap: CFMachPort?
        for location in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            guard let candidate = CGEvent.tapCreate(
                tap: location,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: userInfo
            ) else { continue }
            selectedLocation = location
            newTap = candidate
            break
        }
        guard let newTap else { return false }
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        let ready = DispatchSemaphore(value: 0)
        tap = newTap
        source = newSource
        let thread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.lock.lock()
            self?.eventRunLoop = runLoop
            self?.lock.unlock()

            CFRunLoopAddSource(runLoop, newSource, .commonModes)
            CGEvent.tapEnable(tap: newTap, enable: true)
            ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, newSource, .commonModes)
        }
        thread.name = "Muesli Cotypist Input"
        thread.qualityOfService = .userInteractive
        eventThread = thread
        thread.start()

        let started = ready.wait(timeout: .now() + 1) == .success
        let location = selectedLocation == .cghidEventTap ? "hid" : "session"
        Self.diagnosticsQueue.async {
            Self.logger.notice(
                "tap start location=\(location, privacy: .public) ready=\(started, privacy: .public) trusted=\(CGPreflightListenEventAccess(), privacy: .public)"
            )
        }
        if !started {
            stop()
        }
        return started
    }

    func stop() {
        lock.lock()
        let existingTap = tap
        let existingRunLoop = eventRunLoop
        eventRunLoop = nil
        lock.unlock()
        guard let existingTap else { return }
        CGEvent.tapEnable(tap: existingTap, enable: false)
        if let existingRunLoop {
            CFRunLoopStop(existingRunLoop)
            CFRunLoopWakeUp(existingRunLoop)
        }
        self.source = nil
        self.tap = nil
        self.eventThread = nil
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
        let isPreviewPanelMouseDown = input == .mouseDown
            && snapshot.policy.isPreviewing
            && snapshot.previewHitFrame?.contains(event.location) == true
        let action = isPreviewPanelMouseDown ? .pass : snapshot.policy.handle(input)
        let typingEvent = CotypistTypingEvent(input: input)
        let shouldObserveTyping = snapshot.policy.isEnabled
            && (action == .pass || action == .passAndInvalidate)
            && typingEvent?.isLikelyTextEdit == true
        let isGenerating = snapshot.policy.isGenerating
        let isPreviewing = snapshot.policy.isPreviewing
        lock.unlock()

        if case .keyDown(let keyCode, let modifiers, _) = input,
           keyCode == CotypistEventPolicy.tabKeyCode {
            let actionLabel = Self.diagnosticLabel(for: action)
            let modifierValue = modifiers.rawValue
            Self.diagnosticsQueue.async {
                Self.logger.notice(
                    "tab action=\(actionLabel, privacy: .public) generating=\(isGenerating, privacy: .public) previewing=\(isPreviewing, privacy: .public) modifiers=\(modifierValue, privacy: .public)"
                )
            }
        }

        switch action {
        case .pass:
            if let typingEvent, shouldObserveTyping {
                DispatchQueue.main.async { [weak self] in self?.onTyping?(typingEvent) }
            }
            return Unmanaged.passUnretained(event)
        case .passAndInvalidate:
            if let typingEvent, shouldObserveTyping {
                // Text edits are handled by the ambient coordinator, which
                // cancels the old preview before scheduling the next one. Keep
                // this as one ordered callback so a separate invalidation job
                // cannot cancel the newly scheduled debounce task.
                DispatchQueue.main.async { [weak self] in self?.onTyping?(typingEvent) }
            } else {
                DispatchQueue.main.async { [weak self] in self?.onInvalidate?() }
            }
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
            lock.lock()
            let existingTap = tap
            lock.unlock()
            if let existingTap { CGEvent.tapEnable(tap: existingTap, enable: true) }
            Self.diagnosticsQueue.async {
                Self.logger.error("tap recovered after system disable")
            }
            return Unmanaged.passUnretained(event)
        }
    }

    private static func diagnosticLabel(for action: CotypistEventAction) -> String {
        switch action {
        case .pass: "pass"
        case .passAndInvalidate: "pass-invalidate"
        case .consume: "consume"
        case .consumeAndInvoke: "invoke"
        case .consumeAndAccept: "accept"
        case .consumeAndCancel: "cancel"
        case .recoverTap: "recover"
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

struct CotypistCapsuleLayout: Equatable {
    let size: CGSize
    let textRect: CGRect
    let keycapRect: CGRect?
    let requiredTextSize: CGSize

    var displaysCompleteText: Bool {
        requiredTextSize.width <= textRect.width + 1
            && requiredTextSize.height <= textRect.height + 1
    }
}

enum CotypistPreviewLayout {
    private static let keycapWidth: CGFloat = 68
    private static let horizontalInset: CGFloat = 10
    private static let verticalInset: CGFloat = 6
    private static let keycapGap: CGFloat = 6

    static func displayText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func capsule(
        text: String,
        font: NSFont,
        isLoading: Bool,
        maxWidth: CGFloat
    ) -> CotypistCapsuleLayout {
        let visibleText = displayText(text)
        let boundedMaximumWidth = max(1, maxWidth)
        let minimumWidth = min(isLoading ? 108 : 120, boundedMaximumWidth)
        let reservedTrailingWidth = isLoading ? 0 : keycapWidth + keycapGap
        let chromeWidth = (horizontalInset * 2) + reservedTrailingWidth
        let naturalTextWidth = ceil((visibleText as NSString).size(withAttributes: [.font: font]).width)
        let width = min(max(naturalTextWidth + chromeWidth, minimumWidth), boundedMaximumWidth)
        let textWidth = max(1, width - chromeWidth)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        let requiredBounds = (visibleText as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraphStyle]
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let requiredTextSize = CGSize(
            width: min(textWidth, ceil(requiredBounds.width)),
            height: max(lineHeight, ceil(requiredBounds.height))
        )
        let height = max(requiredTextSize.height + (verticalInset * 2), 28)
        let size = CGSize(width: width, height: height)
        let textRect = CGRect(
            x: horizontalInset,
            y: verticalInset,
            width: textWidth,
            height: requiredTextSize.height
        )
        let keycapRect = isLoading ? nil : CGRect(
            x: width - keycapWidth - 8,
            y: (height - 20) / 2,
            width: keycapWidth,
            height: 20
        )
        return CotypistCapsuleLayout(
            size: size,
            textRect: textRect,
            keycapRect: keycapRect,
            requiredTextSize: requiredTextSize
        )
    }
}

@MainActor
final class CotypistPreviewPanel {
    private let panel: NonactivatingOverlayPanel
    private let previewView: CotypistPreviewView
    var onAccept: (() -> Void)?

    /// Quartz screen coordinates use a top-left origin, while AppKit window
    /// frames use a bottom-left origin. The event tap uses this converted frame
    /// to avoid invalidating a preview when its own card is clicked.
    var quartzHitFrame: CGRect? {
        guard panel.isVisible,
              let primaryScreenMaxY = NSScreen.screens.first?.frame.maxY,
              primaryScreenMaxY.isFinite else { return nil }
        return CGRect(
            x: panel.frame.minX,
            y: primaryScreenMaxY - panel.frame.maxY,
            width: panel.frame.width,
            height: panel.frame.height
        )
    }

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
        panel.ignoresMouseEvents = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        previewView.onAccept = { [weak self] in self?.onAccept?() }
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

        // Inline ghost text must never hide an accepted tail. If the complete
        // continuation does not fit beside the caret, use the capsule, which
        // can widen or wrap while remaining non-modal.
        if let ghostFrame = frame, !previewView.displaysCompleteText(in: ghostFrame.size) {
            frame = nil
        }

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
            size = previewView.preferredSize(maxWidth: Self.maximumCapsuleWidth(for: context, screens: screens))
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

    private static func maximumCapsuleWidth(
        for context: FocusedTextContext,
        screens: [NSScreen]
    ) -> CGFloat {
        let screenFrames = screens.map(\.frame)
        let primaryScreenMaxY = screens.first?.frame.maxY ?? 0
        let candidateBounds = [context.caretBounds, context.elementBounds].compactMap { $0 }
        for bounds in candidateBounds where bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && (bounds.width > 0 || bounds.height > 0) {
            let anchor = CGPoint(x: bounds.midX, y: bounds.midY)
            if let converted = AccessibilityScreenGeometry.appKitPoint(
                forQuartzPoint: anchor,
                screenFrames: screenFrames,
                primaryScreenMaxY: primaryScreenMaxY,
                tolerance: 8
            ), screens.indices.contains(converted.screenIndex) {
                return min(760, max(120, screens[converted.screenIndex].visibleFrame.width - 8))
            }
        }

        let fallbackScreen = screens.first(where: { $0.visibleFrame.contains(NSEvent.mouseLocation) }) ?? screens.first
        return min(760, max(120, (fallbackScreen?.visibleFrame.width ?? 760) - 8))
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
    var onAccept: (() -> Void)?

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

    override func mouseDown(with event: NSEvent) {
        guard !isLoading else { return }
        onAccept?()
    }

    /// Keep model line breaks in the accepted completion, but flatten them for
    /// presentation. Any additional visual lines are wrapping only, never
    /// hidden or synthetic characters.
    private var singleLineText: String {
        CotypistPreviewLayout.displayText(text)
    }

    func preferredSize(maxWidth: CGFloat) -> CGSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        if mode == .ghost {
            let measured = ceil((text as NSString).size(withAttributes: attributes).width)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            return CGSize(width: min(max(measured + 2, 1), maxWidth), height: max(lineHeight, 16))
        }
        return CotypistPreviewLayout.capsule(
            text: singleLineText,
            font: font,
            isLoading: isLoading,
            maxWidth: maxWidth
        ).size
    }

    func displaysCompleteText(in size: CGSize) -> Bool {
        switch mode {
        case .ghost:
            let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            return measured <= size.width + 1
        case .capsule:
            return CotypistPreviewLayout.capsule(
                text: singleLineText,
                font: font,
                isLoading: isLoading,
                maxWidth: size.width
            ).displaysCompleteText
        }
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

        let layout = CotypistPreviewLayout.capsule(
            text: singleLineText,
            font: font,
            isLoading: isLoading,
            maxWidth: bounds.width
        )
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        (singleLineText as NSString).draw(
            with: layout.textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle,
            ]
        )

        guard !isLoading else { return }
        guard let keycapRect = layout.keycapRect else { return }
        let keycap = NSBezierPath(roundedRect: keycapRect, xRadius: 5, yRadius: 5)
        NSColor.controlBackgroundColor.withAlphaComponent(0.88).setFill()
        keycap.fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        keycap.lineWidth = 1
        keycap.stroke()
        let keycapText = "Tab / ⌥Tab" as NSString
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
    private static let loadingPresentationDelay = Duration.milliseconds(300)
    private static let ambientInsertionSuppression: TimeInterval = 0.8
    private static let ambientMissSuppression: TimeInterval = 1.5
    private static let logger = Logger(subsystem: "com.muesli.native", category: "CotypistInput")

    private enum Trigger: Sendable {
        case manual
        case ambient
    }

    private let transcriptionRuntime: TranscriptionCoordinator
    private let contextService: FocusedTextContextService
    private let eventTap = CotypistEventTap()
    private let previewPanel = CotypistPreviewPanel()
    private var config = AppConfig()
    private var requestTask: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?
    private var ambientTask: Task<Void, Never>?
    private var ambientSuppressedUntil = Date.distantPast
    private var completionCache = CotypistCompletionCache()
    private var acceptWhenReady = false
    private var requestID: UUID?
    private var requestTrigger: Trigger?
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
        previewPanel.onAccept = { [weak self] in self?.accept() }
        eventTap.onInvoke = { [weak self] in Task { @MainActor in self?.invoke() } }
        eventTap.onAccept = { [weak self] in Task { @MainActor in self?.accept() } }
        eventTap.onCancel = { [weak self] in Task { @MainActor in self?.dismiss() } }
        eventTap.onInvalidate = { [weak self] in Task { @MainActor in self?.cancel() } }
        eventTap.onTyping = { [weak self] event in
            Task { @MainActor in self?.handleTyping(event) }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedProcessID = activatedApplication?.processIdentifier
            Task { @MainActor in
                guard let self else { return }
                // A preview-panel click may briefly activate Muesli itself, and
                // acceptance may activate the original target app again. Neither
                // transition means the user's text context became stale.
                if activatedProcessID == ProcessInfo.processInfo.processIdentifier || self.state == .accepting {
                    return
                }
                self.cancel()
            }
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

        if !config.enableCotypist || !config.enableCotypistAmbient {
            ambientTask?.cancel()
            ambientTask = nil
            eventTap.updateAmbientWaiting(false)
            if requestTrigger == .ambient {
                cancel()
            }
        }

        guard config.enableCotypist else {
            completionCache.removeAll()
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
            completionCache.removeAll()
            Task(priority: .userInitiated) { [model = config.resolvedCotypistModel] in
                try? await transcriptionRuntime.prepareCotypist(model: model)
            }
        }
    }

    func shutdown() {
        eventTap.stop()
        cancel()
        completionCache.removeAll()
        Task { await transcriptionRuntime.unloadCotypist() }
    }

    func invoke() {
        invoke(trigger: .manual)
    }

    private func invoke(trigger: Trigger, prefetchedContext: FocusedTextContext? = nil) {
        guard config.enableCotypist, config.resolvedCotypistModel.isDownloaded else { return }
        ambientTask?.cancel()
        ambientTask = nil
        eventTap.updateAmbientWaiting(false)
        requestTask?.cancel()
        loadingTask?.cancel()
        hidePreviewPanel()
        acceptWhenReady = false
        let excluded = Set(config.cotypistExcludedBundleIDs)
        guard let context = prefetchedContext ?? contextService.capture(excludedBundleIDs: excluded) else {
            if trigger == .manual {
                fail("No supported text field at the cursor")
            } else {
                resetUI()
            }
            return
        }

        if case .ambient = trigger,
           let completion = completionCache.completion(
               for: context,
               model: config.resolvedCotypistModel
           ) {
            requestID = nil
            requestTrigger = nil
            previewContext = context
            state = .previewing(completion)
            previewPanel.show(text: completion.text, context: context, quality: completion.quality)
            eventTap.updatePreviewHitFrame(previewPanel.quartzHitFrame)
            return
        }

        let id = UUID()
        requestID = id
        requestTrigger = trigger
        previewContext = nil
        state = .generating
        loadingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.loadingPresentationDelay)
                guard let self, requestID == id, state.isGenerating else { return }
                let loadingText = if case .manual = trigger { "Completing…" } else { "…" }
                previewPanel.show(text: loadingText, context: context, isLoading: true)
                eventTap.updatePreviewHitFrame(previewPanel.quartzHitFrame)
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
                requestTrigger = nil
                previewContext = fresh
                completionCache.store(
                    completion,
                    for: fresh,
                    model: request.model
                )
                state = .previewing(completion)
                previewPanel.show(
                    text: completion.text,
                    context: fresh,
                    quality: completion.quality
                )
                eventTap.updatePreviewHitFrame(previewPanel.quartzHitFrame)
                if acceptWhenReady {
                    accept()
                }
            } catch is CancellationError {
                if requestID == id { resetUI() }
            } catch CotypistCompletionError.noSuggestion {
                if requestID == id {
                    suppressAmbientAfterMiss(trigger)
                    resetUI()
                }
            } catch CotypistCompletionError.invalidOutput {
                if requestID == id {
                    suppressAmbientAfterMiss(trigger)
                    resetUI()
                }
            } catch {
                if requestID == id {
                    if trigger == .manual {
                        fail(error.localizedDescription)
                    } else {
                        resetUI()
                    }
                }
            }
        }
    }

    func accept() {
        if state.isGenerating {
            acceptWhenReady = true
            Self.logger.notice("accept queued while generation is pending")
            return
        }
        guard case .previewing(let completion) = state, let expected = previewContext else {
            Self.logger.notice("accept ignored because no preview is active")
            return
        }
        Self.logger.notice("accept started from active preview")
        acceptWhenReady = false
        state = .accepting
        hidePreviewPanel()
        loadingTask?.cancel()
        loadingTask = nil
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        requestTrigger = nil
        previewContext = nil

        // A click on the non-activating preview panel can briefly make Muesli the
        // frontmost process, even though the target field remains focused in the
        // other app. Restore that app before revalidating and typing so a click is
        // equivalent to Tab acceptance. The fingerprint is still checked on every
        // attempt; we never insert into a field that changed while the preview was
        // visible.
        finishAcceptance(completion: completion, expected: expected, attemptsRemaining: 3)
    }

    private func finishAcceptance(
        completion: CotypistCompletion,
        expected: FocusedTextContext,
        attemptsRemaining: Int
    ) {
        let targetApplication = NSRunningApplication(processIdentifier: expected.processID)
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmostProcessID != expected.processID {
            Self.logger.notice("accept waiting for target application activation")
            _ = targetApplication?.activate(options: [])
            guard attemptsRemaining > 0 else {
                Self.logger.error("accept failed because target application did not activate")
                state = .idle
                return
            }
            scheduleAcceptanceRetry(
                completion: completion,
                expected: expected,
                attemptsRemaining: attemptsRemaining - 1
            )
            return
        }

        let fresh = contextService.capture(excludedBundleIDs: Set(config.cotypistExcludedBundleIDs))
        guard fresh?.fingerprint == expected.fingerprint else {
            Self.logger.notice("accept waiting for focused-text revalidation")
            guard attemptsRemaining > 0 else {
                Self.logger.error("accept failed focused-text revalidation")
                state = .idle
                return
            }
            scheduleAcceptanceRetry(
                completion: completion,
                expected: expected,
                attemptsRemaining: attemptsRemaining - 1
            )
            return
        }

        state = .idle
        ambientSuppressedUntil = Date().addingTimeInterval(Self.ambientInsertionSuppression)
        ambientTask?.cancel()
        ambientTask = nil
        eventTap.updateAmbientWaiting(false)
        let insertedWithAccessibility = contextService.insertText(completion.text, into: expected)
        Self.logger.notice("accept insertion accessibility=\(insertedWithAccessibility, privacy: .public)")
        if !insertedWithAccessibility {
            Self.logger.notice("accept falling back to synthetic text events")
            PasteController.typeText(completion.text)
        }
    }

    private func scheduleAcceptanceRetry(
        completion: CotypistCompletion,
        expected: FocusedTextContext,
        attemptsRemaining: Int
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, state == .accepting else { return }
            finishAcceptance(
                completion: completion,
                expected: expected,
                attemptsRemaining: attemptsRemaining
            )
        }
    }

    func cancel() {
        let hadActiveRequest = requestTask != nil || state != .idle
        ambientTask?.cancel()
        ambientTask = nil
        eventTap.updateAmbientWaiting(false)
        loadingTask?.cancel()
        loadingTask = nil
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        requestTrigger = nil
        previewContext = nil
        acceptWhenReady = false
        resetUI()
        if hadActiveRequest {
            Task { await transcriptionRuntime.cancelCotypistCompletion() }
        }
    }

    private func dismiss() {
        if state.isGenerating || state.isPreviewing {
            ambientSuppressedUntil = Date().addingTimeInterval(Self.ambientMissSuppression)
        }
        cancel()
    }

    private func handleTyping(_ event: CotypistTypingEvent) {
        guard config.enableCotypist,
              event.isLikelyTextEdit else { return }

        ambientTask?.cancel()
        ambientTask = nil
        eventTap.updateAmbientWaiting(false)
        if state.isGenerating || state.isPreviewing {
            cancel()
        }
        guard config.enableCotypistAmbient,
              Date() >= ambientSuppressedUntil else { return }

        ambientTask = Task { [weak self] in
            do {
                try await Task.sleep(for: CotypistAmbientSuggestionPolicy.idleDelay)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.ambientTask = nil
                self.eventTap.updateAmbientWaiting(false)
                let excluded = Set(self.config.cotypistExcludedBundleIDs)
                guard let context = self.contextService.capture(excludedBundleIDs: excluded),
                      CotypistAmbientSuggestionPolicy.isEligible(prefix: context.prefix) else { return }
                self.invoke(trigger: .ambient, prefetchedContext: context)
            } catch {
                return
            }
        }
        eventTap.updateAmbientWaiting(true)
    }

    private func suppressAmbientAfterMiss(_ trigger: Trigger) {
        guard case .ambient = trigger else { return }
        ambientSuppressedUntil = Date().addingTimeInterval(Self.ambientMissSuppression)
    }

    private func fail(_ message: String) {
        loadingTask?.cancel()
        loadingTask = nil
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        requestTrigger = nil
        previewContext = nil
        acceptWhenReady = false
        state = .failed(message)
        hidePreviewPanel()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, case .failed = state else { return }
            state = .idle
        }
    }

    private func resetUI() {
        loadingTask?.cancel()
        loadingTask = nil
        requestTask = nil
        requestID = nil
        requestTrigger = nil
        previewContext = nil
        acceptWhenReady = false
        hidePreviewPanel()
        state = .idle
    }

    private func hidePreviewPanel() {
        previewPanel.hide()
        eventTap.updatePreviewHitFrame(nil)
    }
}
