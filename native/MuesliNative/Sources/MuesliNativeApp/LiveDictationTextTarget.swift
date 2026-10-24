import AppKit
import ApplicationServices

/// Owns one revisable range for one hands-free session. Never writes AXValue,
/// types deletion keystrokes, or uses the clipboard. Unsupported editors must
/// use the caller's preview/history path instead of an unverified replacement.
@MainActor
final class LiveDictationTextTarget {
    struct Snapshot: Equatable {
        let text: String
        let selection: NSRange

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.selection == rhs.selection && lhs.text.utf16.elementsEqual(rhs.text.utf16)
        }
    }

    enum Transport: String {
        case axSelectedText
        case targetedKeyboard
    }

    static func transport(for bundleIdentifier: String?) -> Transport {
        bundleIdentifier == "com.openai.codex" ? .targetedKeyboard : .axSelectedText
    }

    static func allowsEmptyLineSentinelRemoval(for bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.openai.codex"
    }

    struct KeyboardStep {
        let text: String
        /// Dispatch must revalidate immediately before posting both events.
        let send: (_ validate: () -> Bool, _ onFailure: (LiveDictationKeyboardInput.DispatchFailure) -> Void) -> Bool
    }

    /// The transport is selected before any write and never changed on failure.
    struct Access {
        let snapshot: () -> Snapshot?
        let isFocused: () -> Bool
        let select: (NSRange) -> Bool
        let replaceSelection: (String) -> Bool
        let transport: Transport
        let keyboardPlan: ((String) -> [KeyboardStep]?)?
        let allowsEmptyLineSentinelRemoval: Bool

        init(snapshot: @escaping () -> Snapshot?, isFocused: @escaping () -> Bool,
             select: @escaping (NSRange) -> Bool, replaceSelection: @escaping (String) -> Bool,
             transport: Transport = .axSelectedText,
             keyboardPlan: ((String) -> [KeyboardStep]?)? = nil,
             allowsEmptyLineSentinelRemoval: Bool = false) {
            self.snapshot = snapshot
            self.isFocused = isFocused
            self.select = select
            self.replaceSelection = replaceSelection
            self.transport = transport
            self.keyboardPlan = keyboardPlan
            self.allowsEmptyLineSentinelRemoval = allowsEmptyLineSentinelRemoval
        }
    }

    struct ReadbackTiming {
        var timeout: TimeInterval = 0.5
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var wait: () async -> Void = { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private static weak var activeTarget: LiveDictationTextTarget?
    private let access: Access
    private var expected: Snapshot
    private var ownedRange: NSRange
    private var isClosed = false
    private var isFinishing = false
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Bool, Never>] = []
    private let readbackTiming: ReadbackTiming
    private var isMutating = false
    private var pendingTextValidation = false
    private var canAcknowledgeEmptyLineSentinelRemoval = false
    private var frozenCommittedText = ""
    private var nativeTarget: AccessibilityTarget?
    private let onDiagnostic: (String) -> Void
    private(set) var isSuspended = false
    private(set) var hasInsertedText = false
    /// Even an unsuccessful AX call may have reached another process. Callers
    /// must never retry by normal paste after this becomes true.
    private(set) var hasAttemptedWrite = false
    private(set) var applicationName: String?
    private(set) var bundleIdentifier: String?

    init?(access: Access, onDiagnostic: @escaping (String) -> Void = { _ in },
          readbackTiming: ReadbackTiming = .init()) {
        Self.activeTarget?.cancel()
        guard access.isFocused(), let snapshot = access.snapshot(),
              Self.isValid(snapshot.selection, in: snapshot.text) else { return nil }
        self.access = access
        self.onDiagnostic = onDiagnostic
        self.readbackTiming = readbackTiming
        expected = snapshot
        ownedRange = snapshot.selection
        canAcknowledgeEmptyLineSentinelRemoval = access.transport == .targetedKeyboard
            && access.allowsEmptyLineSentinelRemoval
            && snapshot.text.utf16.elementsEqual("\n".utf16)
            && snapshot.selection == NSRange(location: 0, length: 0)
        Self.activeTarget = self
    }

    static func capture(onDiagnostic: @escaping (String) -> Void = { _ in }) -> LiveDictationTextTarget? {
        activeTarget?.cancel()
        guard let native = AccessibilityTarget.capture(),
              let target = LiveDictationTextTarget(access: native.access, onDiagnostic: onDiagnostic) else {
            onDiagnostic("capture_unavailable")
            return nil
        }
        target.nativeTarget = native
        target.applicationName = native.application.localizedName
        target.bundleIdentifier = native.application.bundleIdentifier
        onDiagnostic("transport:\(native.transport.rawValue)")
        guard native.observeChanges(onFocusChange: { [weak target] in
            target?.focusTargetDidChange()
        }, onTextChange: { [weak target] in
            target?.textTargetDidChange()
        }, onKnownFocusDeparture: { [weak target] in
            target?.focusTargetDidDepart()
        }) else {
            onDiagnostic("observer_unavailable")
            target.cancel()
            return nil
        }
        return target
    }

    /// One mutation at a time, including the renderer's asynchronous readback.
    /// Finalization joins the queue and rejects any subsequently offered preview.
    @discardableResult
    func update(text: String) async -> Bool {
        guard !isFinishing, await acquireOperation() else { return false }
        defer { releaseOperation() }
        return await performUpdate(text: text, frozenPrefixLength: frozenCommittedText.utf16.count)
    }

    /// A healthy preview may be deferred when it would rewrite too much tail.
    /// Commitments advance only when their complete text has been acknowledged.
    @discardableResult
    func update(committedText: String, tail: String) async -> Bool {
        guard !isFinishing, await acquireOperation() else { return false }
        defer { releaseOperation() }
        guard committedText.utf16.starts(with: frozenCommittedText.utf16) else {
            return suspend("committed_prefix_changed")
        }
        let text = committedText + tail
        let boundary = committedText.utf16.count
        var offset = 0
        let boundaries = [0] + text.map { character in
            offset += String(character).utf16.count
            return offset
        }
        guard boundaries.contains(boundary) else { return suspend("committed_boundary_invalid") }
        let accepted = await performUpdate(text: text, frozenPrefixLength: frozenCommittedText.utf16.count,
                                           maximumRewrittenGraphemes: 80)
        let acknowledgedText = (expected.text as NSString).substring(with: ownedRange)
        if accepted, acknowledgedText.utf16.elementsEqual(text.utf16) {
            frozenCommittedText = committedText
        }
        return accepted
    }

    @discardableResult
    func finish(text: String) async -> Bool {
        guard !isClosed, !isFinishing else { return false }
        isFinishing = true
        guard await acquireOperation() else { return false }
        defer { releaseOperation() }
        let delivered = await performUpdate(text: text)
        cancel()
        return delivered
    }

    private func acquireOperation() async -> Bool {
        guard !isClosed, !isSuspended, !Task.isCancelled else { return false }
        if !operationInProgress {
            operationInProgress = true
            return true
        }
        return await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        if !isClosed, !operationWaiters.isEmpty {
            operationWaiters.removeFirst().resume(returning: true)
        } else {
            operationInProgress = false
        }
    }

    private func performUpdate(text: String, frozenPrefixLength: Int = 0,
                               maximumRewrittenGraphemes: Int? = nil) async -> Bool {
        guard validateCurrent() else { return false }
        // Empty provisional hypotheses never erase existing or previously emitted text.
        if text.isEmpty { return true }
        let keyboardPlan: [KeyboardStep]?
        if access.transport == .targetedKeyboard {
            // Validate every proposed grapheme before changing even the selection.
            guard let plan = access.keyboardPlan?(text), !plan.isEmpty,
                  plan.allSatisfy({ $0.text.count == 1 }),
                  plan.map(\.text).joined().utf16.elementsEqual(text.utf16) else {
                return suspend("keyboard_text_unsupported")
            }
            keyboardPlan = plan
        } else {
            keyboardPlan = nil
        }
        let nextText = (expected.text as NSString).replacingCharacters(in: ownedRange, with: text)
        if nextText.utf16.elementsEqual(expected.text.utf16) { return true }
        let nextCaret = NSRange(location: ownedRange.location + (text as NSString).length, length: 0)
        let previous = (expected.text as NSString).substring(with: ownedRange).map(String.init)
        let proposed = text.map(String.init)
        var prefixCount = 0
        while prefixCount < min(previous.count, proposed.count),
              previous[prefixCount].utf16.elementsEqual(proposed[prefixCount].utf16) {
            prefixCount += 1
        }
        // Keyboard shortening retypes one retained grapheme instead of sending
        // Delete. A live preview must never retype a frozen committed grapheme.
        if keyboardPlan != nil, prefixCount == proposed.count { prefixCount -= 1 }
        let prefixLength = proposed.prefix(prefixCount).reduce(0) { $0 + $1.utf16.count }
        if prefixLength < frozenPrefixLength {
            if maximumRewrittenGraphemes != nil, keyboardPlan != nil,
               text.utf16.count == frozenPrefixLength,
               text.utf16.elementsEqual(frozenCommittedText.utf16) {
                onDiagnostic("preview_deferred_committed_boundary")
                return true
            }
            return suspend("committed_prefix_changed")
        }
        if let maximumRewrittenGraphemes, previous.count - prefixCount > maximumRewrittenGraphemes {
            onDiagnostic("preview_deferred_rewrite_limit")
            return true
        }
        let editRange = NSRange(location: ownedRange.location + prefixLength,
                                length: ownedRange.length - prefixLength)
        hasAttemptedWrite = true
        isMutating = true
        defer {
            isMutating = false
            if pendingTextValidation {
                pendingTextValidation = false
                _ = validateCurrent()
            }
        }
        if let keyboardPlan {
            return await performKeyboardUpdate(plan: keyboardPlan, prefixCount: prefixCount)
        }
        let selected = Snapshot(text: expected.text, selection: editRange)
        guard access.select(editRange) else { return suspend("selection_write_failed") }
        guard await awaitReadback(selected, stale: expected, stage: "selection") != nil else { return false }
        // Revalidate immediately before the second write, even after its ACK.
        guard mutationIsCurrent(), access.snapshot() == selected else {
            return suspend("selection_readback_changed")
        }
        let replacement = proposed.dropFirst(prefixCount).joined()
        guard access.replaceSelection(replacement) else { return suspend("text_write_failed") }
        let next = Snapshot(text: nextText, selection: nextCaret)
        guard await awaitReadback(next, stale: selected, stage: "text") != nil else { return false }
        hasInsertedText = true
        expected = next
        ownedRange = NSRange(location: ownedRange.location, length: (text as NSString).length)
        return true
    }

    private func performKeyboardUpdate(plan: [KeyboardStep], prefixCount: Int) async -> Bool {
        let originalBase = ownedRange.location
        let prefixLength = plan.prefix(prefixCount).reduce(0) { $0 + $1.text.utf16.count }
        let editRange = NSRange(location: originalBase + prefixLength,
                                length: ownedRange.length - prefixLength)
        var current = Snapshot(text: expected.text, selection: editRange)
        guard access.select(editRange) else { return suspend("selection_write_failed") }
        guard await awaitReadback(current, stale: expected, stage: "selection") != nil else { return false }
        for step in plan.dropFirst(prefixCount) {
            guard mutationIsCurrent(), access.snapshot() == current else {
                return suspend("keyboard_target_changed")
            }
            let nextText = (current.text as NSString).replacingCharacters(in: current.selection, with: step.text)
            let next = Snapshot(text: nextText,
                selection: NSRange(location: current.selection.location + step.text.utf16.count, length: 0))
            // Codex can expose an empty composer as one newline, then remove
            // that placeholder on the first key. Do not normalize at capture:
            // only acknowledge this exact observed first-key transformation.
            let sentinelRemoved: Snapshot?
            if canAcknowledgeEmptyLineSentinelRemoval,
               current.text.utf16.elementsEqual("\n".utf16),
               current.selection == NSRange(location: 0, length: 0) {
                sentinelRemoved = Snapshot(text: step.text, selection: next.selection)
            } else {
                sentinelRemoved = nil
            }
            canAcknowledgeEmptyLineSentinelRemoval = false
            guard step.send({
                guard self.mutationIsCurrent() else { return false }
                guard let snapshot = self.access.snapshot() else {
                    self.onDiagnostic("keyboard_validation_snapshot_unavailable")
                    return false
                }
                guard snapshot == current else {
                    let textMatches = snapshot.text.utf16.elementsEqual(current.text.utf16)
                    let caretMatches = snapshot.selection == current.selection
                    self.onDiagnostic("keyboard_validation_snapshot_changed:textMatches=\(textMatches),caretMatches=\(caretMatches)")
                    return false
                }
                return true
            }, { self.onDiagnostic("keyboard_dispatch_\($0.rawValue)") }) else {
                if isClosed || isSuspended { return false }
                return suspend("keyboard_dispatch_failed")
            }
            guard let acknowledged = await awaitReadback(next, stale: current, stage: "keyboard_text",
                                                        alternate: sentinelRemoved) else { return false }
            if let sentinelRemoved, acknowledged == sentinelRemoved {
                onDiagnostic("keyboard_empty_line_sentinel_removed")
            }
            hasInsertedText = true
            // Track acknowledged prefixes so cancellation leaves exactly the text
            // already delivered; later events and queued updates cannot resume it.
            expected = acknowledged
            ownedRange = NSRange(location: originalBase, length: acknowledged.selection.location - originalBase)
            current = acknowledged
        }
        return true
    }

    /// An accepted native setter can precede the browser's cached AX tree update.
    /// Exact old/new text and caret components may settle independently. The
    /// optional first-key sentinel result is another exact text candidate, with
    /// the same desired caret. Only a complete desired/alternate snapshot succeeds.
    /// Polling never retries a mutation, and no queued operation can run meanwhile.
    private func awaitReadback(_ desired: Snapshot, stale: Snapshot, stage: String,
                               alternate: Snapshot? = nil) async -> Snapshot? {
        let deadline = readbackTiming.now() + readbackTiming.timeout
        var reportedStates = Set<String>()
        while true {
            guard mutationIsCurrent() else { return nil }
            guard let observed = access.snapshot() else {
                suspend("\(stage)_readback_unavailable")
                return nil
            }
            if observed == desired { return observed }
            if let alternate, observed == alternate { return observed }
            // AX value and selection are separate reads and may be refreshed by
            // the editor in either order. Only the exact allowed components are
            // eligible to settle; an intermediate snapshot never authorizes the
            // next write, even if its caret is beyond the stale text's end.
            let oldText = observed.text.utf16.elementsEqual(stale.text.utf16)
            let newText = observed.text.utf16.elementsEqual(desired.text.utf16)
            let alternateText = alternate.map { observed.text.utf16.elementsEqual($0.text.utf16) } ?? false
            let oldCaret = observed.selection == stale.selection
            let newCaret = observed.selection == desired.selection
            let textState = newText ? "new" : oldText ? "old" : alternateText ? "alternate" : "other"
            let caretState = newCaret ? "new" : oldCaret ? "old" : "other"
            let state = "\(textState):\(caretState)"
            let timedOut = readbackTiming.now() >= deadline
            if (observed != stale || timedOut) && reportedStates.insert(state).inserted {
                let caseOnly = !newText && observed.text.lowercased().utf16.elementsEqual(desired.text.lowercased().utf16)
                func withoutTrailingNewlines(_ text: String) -> String {
                    var result = text
                    while result.last == "\n" || result.last == "\r" || result.last == "\r\n" {
                        result.removeLast()
                    }
                    return result
                }
                let trailingNewlineOnly = !newText && withoutTrailingNewlines(observed.text).utf16
                    .elementsEqual(withoutTrailingNewlines(desired.text).utf16)
                onDiagnostic("\(stage)_readback_state:text=\(textState),lengths=\(observed.text.utf16.count)/\(stale.text.utf16.count)/\(desired.text.utf16.count),caret=\(caretState),ranges=\(observed.selection.location):\(observed.selection.length)/\(stale.selection.location):\(stale.selection.length)/\(desired.selection.location):\(desired.selection.length),caseOnly=\(caseOnly),trailingNewlineOnly=\(trailingNewlineOnly)")
            }
            guard (oldText || newText || alternateText) && (oldCaret || newCaret) else {
                suspend("\(stage)_readback_changed")
                return nil
            }
            guard !timedOut else {
                suspend("\(stage)_readback_timeout")
                return nil
            }
            await readbackTiming.wait()
        }
    }

    private func mutationIsCurrent() -> Bool {
        guard !isClosed, !isSuspended, Self.activeTarget === self else { return false }
        guard !Task.isCancelled else { return suspend("cancelled") }
        guard access.isFocused() else { return suspend("focus_changed") }
        return true
    }

    /// Cancellation leaves already inserted text in place and rejects late work.
    func cancel() {
        isClosed = true
        let waiters = operationWaiters
        operationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: false) }
        nativeTarget?.stopObserving()
        if Self.activeTarget === self { Self.activeTarget = nil }
    }

    /// AX may deliver our own selection/value notifications reentrantly while
    /// replacing text. Validate them after the complete, verified mutation;
    /// focus-change notifications still suspend immediately.
    func textTargetDidChange() {
        if isMutating {
            pendingTextValidation = true
        } else {
            _ = validateCurrent()
        }
    }

    /// Editors may announce focus again for the same field while its selection
    /// changes. Revalidate the identity instead of treating every notification
    /// as a focus departure. An actual departure still permanently revokes us.
    func focusTargetDidChange() {
        guard !isClosed else { return }
        guard access.isFocused() else {
            _ = suspend("focus_changed")
            return
        }
        textTargetDidChange()
    }

    /// Unlike a redundant AX focus notification, this records a known departure
    /// even if its notification arrives after the original app becomes active again.
    func focusTargetDidDepart() {
        guard !isClosed else { return }
        _ = suspend("focus_changed")
    }

    @discardableResult
    private func validateCurrent() -> Bool {
        guard mutationIsCurrent() else { return false }
        guard access.snapshot() == expected else { return suspend("text_or_caret_changed") }
        return true
    }

    @discardableResult
    private func suspend(_ reason: String) -> Bool {
        onDiagnostic(reason)
        isSuspended = true
        cancel()
        return false
    }

    private static func isValid(_ range: NSRange, in text: String) -> Bool {
        let count = (text as NSString).length
        guard range.location >= 0, range.location <= count,
              range.length >= 0, range.length <= count - range.location else { return false }
        // Foundation's Range(NSRange, in:) can represent an index between UTF-16
        // surrogate units. Check both boundaries explicitly before NSString edits.
        let units = Array(text.utf16)
        func isBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < units.count else { return true }
            return !(0xD800...0xDBFF).contains(units[offset - 1])
                || !(0xDC00...0xDFFF).contains(units[offset])
        }
        return isBoundary(range.location) && isBoundary(range.location + range.length)
    }
}

@MainActor
private final class AccessibilityTarget {
    let application: NSRunningApplication
    private let element: AXUIElement
    let transport: LiveDictationTextTarget.Transport
    private let appElement: AXUIElement
    private var observer: AXObserver?
    private var activationObserver: NSObjectProtocol?
    private var onFocusChange: (() -> Void)?
    private var onTextChange: (() -> Void)?
    private var onKnownFocusDeparture: (() -> Void)?

    private init(application: NSRunningApplication, element: AXUIElement) {
        self.application = application
        self.element = element
        transport = LiveDictationTextTarget.transport(for: application.bundleIdentifier)
        appElement = AXUIElementCreateApplication(application.processIdentifier)
    }

    isolated deinit {
        stopObserving()
    }

    static func capture() -> AccessibilityTarget? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = DictationContextCapture.focusedUIElement(for: app) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        let transport = LiveDictationTextTarget.transport(for: app.bundleIdentifier)
        guard supportsReplacement(element, transport: transport) else { return nil }
        return AccessibilityTarget(application: app, element: element)
    }

    private static func supportsReplacement(_ element: AXUIElement,
                                            transport: LiveDictationTextTarget.Transport) -> Bool {
        guard let role = string(element, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole].contains(role),
              let subrole = optionalSubrole(element),
              subrole.isEmpty || subrole == kAXSearchFieldSubrole,
              settable(element, kAXSelectedTextRangeAttribute),
              (transport == .targetedKeyboard || settable(element, kAXSelectedTextAttribute)),
              string(element, kAXValueAttribute) != nil else { return false }
        // Rich editors which do not expose a string value and a writable selected
        // text range are unsupported. We never reconstruct surrounding formatting.
        return true
    }

    var access: LiveDictationTextTarget.Access {
        .init(snapshot: { [self] in
            guard let text = Self.string(element, kAXValueAttribute),
                  let range = DictationContextCapture.selectedTextRange(element),
                  range.location >= 0, range.length >= 0 else { return nil }
            return .init(text: text, selection: NSRange(location: range.location, length: range.length))
        }, isFocused: { [self] in
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
                  !application.isTerminated, Self.supportsReplacement(element, transport: transport),
                  let current = DictationContextCapture.focusedUIElement(for: application) else { return false }
            return CFEqual(current, element)
        }, select: { [self] selection in
            var range = CFRange(location: selection.location, length: selection.length)
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
        }, replaceSelection: { [self] text in
            AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        }, transport: transport, keyboardPlan: { [self] text in
            guard let plan = LiveDictationKeyboardInput.makePlan(text: text) else { return nil }
            return plan.map { step in
                LiveDictationTextTarget.KeyboardStep(text: step.text, send: { validate, onFailure in
                    LiveDictationKeyboardInput.post(step, to: self.application.processIdentifier,
                                                   validateTarget: validate, onFailure: onFailure)
                })
            }
        }, allowsEmptyLineSentinelRemoval: LiveDictationTextTarget.allowsEmptyLineSentinelRemoval(
            for: application.bundleIdentifier))
    }

    func observeChanges(onFocusChange: @escaping () -> Void, onTextChange: @escaping () -> Void,
                        onKnownFocusDeparture: @escaping () -> Void) -> Bool {
        self.onFocusChange = onFocusChange
        self.onTextChange = onTextChange
        self.onKnownFocusDeparture = onKnownFocusDeparture
        var newObserver: AXObserver?
        let result = AXObserverCreate(application.processIdentifier, { _, _, notification, context in
            guard let context else { return }
            // The observer source is installed only on the main run loop.
            MainActor.assumeIsolated {
                let target = Unmanaged<AccessibilityTarget>.fromOpaque(context).takeUnretainedValue()
                if notification as String == kAXFocusedUIElementChangedNotification {
                    target.onFocusChange?()
                } else {
                    target.onTextChange?()
                }
            }
        }, &newObserver)
        guard result == .success, let newObserver else { return false }
        observer = newObserver
        let context = Unmanaged.passUnretained(self).toOpaque()
        for (target, notification) in [(appElement, kAXFocusedUIElementChangedNotification),
                                       (element, kAXValueChangedNotification),
                                       (element, kAXSelectedTextChangedNotification)] {
            guard AXObserverAddNotification(newObserver, target, notification as CFString, context) == .success else {
                stopObserving()
                return false
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != self.application.processIdentifier else { return }
                self.onKnownFocusDeparture?()
            }
        }
        return true
    }

    func stopObserving() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for (target, notification) in [(appElement, kAXFocusedUIElementChangedNotification),
                                           (element, kAXValueChangedNotification),
                                           (element, kAXSelectedTextChangedNotification)] {
                AXObserverRemoveNotification(observer, target, notification as CFString)
            }
        }
        observer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        onFocusChange = nil
        onTextChange = nil
        onKnownFocusDeparture = nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func optionalSubrole(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        if result == .noValue || result == .attributeUnsupported { return "" }
        guard result == .success else { return nil }
        return value as? String
    }

    private static func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &value) == .success && value.boolValue
    }
}
