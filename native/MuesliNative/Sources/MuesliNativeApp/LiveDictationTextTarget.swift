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

    /// The native adapter and deterministic tests share the same ownership rules.
    struct Access {
        let snapshot: () -> Snapshot?
        let isFocused: () -> Bool
        let select: (NSRange) -> Bool
        let replaceSelection: (String) -> Bool
    }

    private static weak var activeTarget: LiveDictationTextTarget?
    private let access: Access
    private var expected: Snapshot
    private var ownedRange: NSRange
    private var isClosed = false
    private var isMutating = false
    private var pendingTextValidation = false
    private var nativeTarget: AccessibilityTarget?
    private(set) var isSuspended = false
    private(set) var hasInsertedText = false
    /// Even an unsuccessful AX call may have reached another process. Callers
    /// must never retry by normal paste after this becomes true.
    private(set) var hasAttemptedWrite = false
    private(set) var applicationName: String?
    private(set) var bundleIdentifier: String?

    init?(access: Access) {
        Self.activeTarget?.cancel()
        guard access.isFocused(), let snapshot = access.snapshot(),
              Self.isValid(snapshot.selection, in: snapshot.text) else { return nil }
        self.access = access
        expected = snapshot
        ownedRange = snapshot.selection
        Self.activeTarget = self
    }

    static func capture() -> LiveDictationTextTarget? {
        activeTarget?.cancel()
        guard let native = AccessibilityTarget.capture(),
              let target = LiveDictationTextTarget(access: native.access) else { return nil }
        target.nativeTarget = native
        target.applicationName = native.application.localizedName
        target.bundleIdentifier = native.application.bundleIdentifier
        guard native.observeChanges(onFocusChange: { [weak target] in
            target?.suspend()
        }, onTextChange: { [weak target] in
            target?.textTargetDidChange()
        }) else {
            target.cancel()
            return nil
        }
        return target
    }

    @discardableResult
    func update(text: String) -> Bool {
        guard validateCurrent() else { return false }
        // An empty early hypothesis must not delete the user's initial selection.
        if !hasAttemptedWrite && text.isEmpty { return true }
        let nextText = (expected.text as NSString).replacingCharacters(in: ownedRange, with: text)
        if nextText.utf16.elementsEqual(expected.text.utf16) { return true }
        let nextCaret = NSRange(location: ownedRange.location + (text as NSString).length, length: 0)
        hasAttemptedWrite = true
        isMutating = true
        defer {
            isMutating = false
            if pendingTextValidation {
                pendingTextValidation = false
                _ = validateCurrent()
            }
        }
        guard access.select(ownedRange) else { return suspend() }
        // Selecting our range is itself a mutation. Revalidate focus, content,
        // and exactly that selection before the separate cross-process text write.
        guard !isClosed, !isSuspended, Self.activeTarget === self,
              access.isFocused(), access.snapshot() == Snapshot(text: expected.text, selection: ownedRange) else {
            return suspend()
        }
        guard access.replaceSelection(text) else { return suspend() }
        hasInsertedText = hasInsertedText || !text.isEmpty
        let next = Snapshot(text: nextText, selection: nextCaret)
        // Do not force the caret afterwards: unexpected editor behavior is a
        // reason to stop, not permission for another write.
        guard !isClosed, !isSuspended, Self.activeTarget === self,
              access.isFocused(), access.snapshot() == next else { return suspend() }
        expected = next
        ownedRange = NSRange(location: ownedRange.location, length: (text as NSString).length)
        return true
    }

    @discardableResult
    func finish(text: String) -> Bool {
        let delivered = update(text: text)
        cancel()
        return delivered
    }

    /// Cancellation leaves already inserted text in place and rejects late work.
    func cancel() {
        isClosed = true
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

    @discardableResult
    private func validateCurrent() -> Bool {
        guard !isClosed, !isSuspended, Self.activeTarget === self else { return false }
        guard access.isFocused(), access.snapshot() == expected else { return suspend() }
        return true
    }

    @discardableResult
    private func suspend() -> Bool {
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
    private let appElement: AXUIElement
    private var observer: AXObserver?
    private var activationObserver: NSObjectProtocol?
    private var onFocusChange: (() -> Void)?
    private var onTextChange: (() -> Void)?

    private init(application: NSRunningApplication, element: AXUIElement) {
        self.application = application
        self.element = element
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
        guard supportsReplacement(element) else { return nil }
        return AccessibilityTarget(application: app, element: element)
    }

    private static func supportsReplacement(_ element: AXUIElement) -> Bool {
        guard let role = string(element, kAXRoleAttribute),
              [kAXTextFieldRole, kAXTextAreaRole].contains(role),
              let subrole = optionalSubrole(element),
              subrole.isEmpty || subrole == kAXSearchFieldSubrole,
              settable(element, kAXSelectedTextRangeAttribute),
              settable(element, kAXSelectedTextAttribute),
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
                  !application.isTerminated, Self.supportsReplacement(element),
                  let current = DictationContextCapture.focusedUIElement(for: application) else { return false }
            return CFEqual(current, element)
        }, select: { [self] selection in
            var range = CFRange(location: selection.location, length: selection.length)
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
        }, replaceSelection: { [self] text in
            AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        })
    }

    func observeChanges(onFocusChange: @escaping () -> Void, onTextChange: @escaping () -> Void) -> Bool {
        self.onFocusChange = onFocusChange
        self.onTextChange = onTextChange
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
                self.onFocusChange?()
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
