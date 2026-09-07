import AppKit
import ApplicationServices
import Foundation
import MuesliCore

enum PasteController {
    enum DispatchStrategy: Sendable {
        case keyboardShortcut
        case targetApplicationPasteCommand
    }

    enum LifecycleEvent: String, CaseIterable, Sendable {
        case clipboardStaged = "clipboard_staged"
        case clipboardStageFailed = "clipboard_stage_failed"
        case targetSnapshotted = "target_snapshotted"
        case targetPasteCommandDispatched = "target_paste_command_dispatched"
        case targetPasteCommandUnavailable = "target_paste_command_unavailable"
        case targetPasteCommandRejected = "target_paste_command_rejected"
        case pasteDispatched = "paste_dispatched"
        case pasteDispatchFailed = "paste_dispatch_failed"
        case pasteDispatchCancelled = "paste_dispatch_cancelled"
        case clipboardOwnershipLost = "clipboard_ownership_lost"
        case clipboardRestoreScheduled = "clipboard_restore_scheduled"
        case clipboardRestored = "clipboard_restored"
        case clipboardRestoreSkipped = "clipboard_restore_skipped"
        case clipboardRetainedForManualPaste = "clipboard_retained_for_manual_paste"
    }

    /// How long to wait after simulating Cmd+V before restoring the clipboard.
    /// The receiving app must have consumed the paste data within this window.
    private static let clipboardRestoreDelay: TimeInterval = 0.5
    /// Accessibility calls cross a process boundary and can block their caller while
    /// the target app is busy. Keep both each request and the full menu walk bounded;
    /// an unavailable command falls back to leaving Quill output on the clipboard.
    private static let targetPasteAXMaximumRequestTimeout: Float = 0.1
    private static let targetPasteAXTraversalBudget: TimeInterval = 0.35
    private static let physicalKeyMap: [Character: (CGKeyCode, CGEventFlags)] = [
        "a": (0, []), "b": (11, []), "c": (8, []), "d": (2, []), "e": (14, []),
        "f": (3, []), "g": (5, []), "h": (4, []), "i": (34, []), "j": (38, []),
        "k": (40, []), "l": (37, []), "m": (46, []), "n": (45, []), "o": (31, []),
        "p": (35, []), "q": (12, []), "r": (15, []), "s": (1, []), "t": (17, []),
        "u": (32, []), "v": (9, []), "w": (13, []), "x": (7, []), "y": (16, []),
        "z": (6, []),
        "A": (0, .maskShift), "B": (11, .maskShift), "C": (8, .maskShift), "D": (2, .maskShift), "E": (14, .maskShift),
        "F": (3, .maskShift), "G": (5, .maskShift), "H": (4, .maskShift), "I": (34, .maskShift), "J": (38, .maskShift),
        "K": (40, .maskShift), "L": (37, .maskShift), "M": (46, .maskShift), "N": (45, .maskShift), "O": (31, .maskShift),
        "P": (35, .maskShift), "Q": (12, .maskShift), "R": (15, .maskShift), "S": (1, .maskShift), "T": (17, .maskShift),
        "U": (32, .maskShift), "V": (9, .maskShift), "W": (13, .maskShift), "X": (7, .maskShift), "Y": (16, .maskShift),
        "Z": (6, .maskShift),
        "1": (18, []), "2": (19, []), "3": (20, []), "4": (21, []), "5": (23, []),
        "6": (22, []), "7": (26, []), "8": (28, []), "9": (25, []), "0": (29, []),
        "!": (18, .maskShift), "@": (19, .maskShift), "#": (20, .maskShift), "$": (21, .maskShift), "%": (23, .maskShift),
        "^": (22, .maskShift), "&": (26, .maskShift), "*": (28, .maskShift), "(": (25, .maskShift), ")": (29, .maskShift),
        " ": (49, []), "\n": (36, []), "\t": (48, []),
        "-": (27, []), "_": (27, .maskShift), "=": (24, []), "+": (24, .maskShift),
        "[": (33, []), "{": (33, .maskShift), "]": (30, []), "}": (30, .maskShift),
        "\\": (42, []), "|": (42, .maskShift), ";": (41, []), ":": (41, .maskShift),
        "'": (39, []), "\"": (39, .maskShift), ",": (43, []), "<": (43, .maskShift),
        ".": (47, []), ">": (47, .maskShift), "/": (44, []), "?": (44, .maskShift),
        "`": (50, []), "~": (50, .maskShift),
    ]

    /// Paste text into the active app via clipboard, then restore the original clipboard contents.
    ///
    /// Flow: save clipboard → write text → dispatch Paste → restore clipboard after delay.
    /// If the clipboard cannot be saved (e.g. lazy-provided data), falls back to a simple
    /// paste without restoration.
    /// For nonempty text, completion receives the target app only when the selected Paste
    /// command was accepted. When staged-clipboard ownership is required, a failed write or
    /// intervening clipboard change also completes with `nil` attribution and skips dispatch.
    @MainActor
    static func paste(
        text: String,
        pasteboard: NSPasteboard = .general,
        requireStagedClipboardOwnership: Bool = false,
        targetApplicationProvider: @escaping @MainActor () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        },
        shouldDispatchPaste: @escaping @MainActor () -> Bool = { true },
        dispatchStrategy: DispatchStrategy = .keyboardShortcut,
        retainStagedTextOnFailure: Bool = false,
        targetPasteAction: @escaping @MainActor (NSRunningApplication) -> Bool? = {
            PasteController.performTargetPasteCommand(in: $0)
        },
        simulatePasteAction: @escaping @MainActor () -> Bool = PasteController.simulatePaste,
        onPasteDispatched: @escaping @MainActor () -> Void = {},
        onPasteFinished: @escaping @MainActor (NSRunningApplication?) -> Void = { _ in },
        onClipboardSettled: @escaping @MainActor () -> Void = {},
        onLifecycleEvent: @escaping @MainActor (LifecycleEvent) -> Void = { _ in }
    ) {
        guard !text.isEmpty else { return }

        // Save current clipboard contents (all types) so we can restore after paste.
        let savedItems = saveClipboard(pasteboard)

        let clearedChangeCount = pasteboard.clearContents()
        let didStageText = pasteboard.setString(text, forType: .string)
        let pasteChangeCount = pasteboard.changeCount
        onLifecycleEvent(didStageText ? .clipboardStaged : .clipboardStageFailed)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // Snapshot immediately before Paste dispatch so attribution and the command
            // refer to the same frontmost application.
            let targetApplication = targetApplicationProvider()
            onLifecycleEvent(.targetSnapshotted)

            @MainActor
            func settleFailedDispatch() {
                if retainStagedTextOnFailure, pasteboard.changeCount == pasteChangeCount {
                    onLifecycleEvent(.clipboardRetainedForManualPaste)
                } else if pasteboard.changeCount == pasteChangeCount {
                    restoreClipboard(pasteboard, from: savedItems)
                    onLifecycleEvent(.clipboardRestored)
                } else {
                    onLifecycleEvent(.clipboardRestoreSkipped)
                }
                onPasteFinished(nil)
                onClipboardSettled()
            }

            if requireStagedClipboardOwnership {
                guard didStageText else {
                    // Restore only when Muesli still owns the cleared pasteboard. If another
                    // app wrote to it, preserving that newer content takes precedence.
                    if pasteboard.changeCount == clearedChangeCount {
                        restoreClipboard(pasteboard, from: savedItems)
                        onLifecycleEvent(.clipboardRestored)
                    } else {
                        onLifecycleEvent(.clipboardRestoreSkipped)
                    }
                    onPasteFinished(nil)
                    onClipboardSettled()
                    return
                }
                guard pasteboard.changeCount == pasteChangeCount else {
                    onLifecycleEvent(.clipboardOwnershipLost)
                    onPasteFinished(nil)
                    onClipboardSettled()
                    return
                }
            }
            guard shouldDispatchPaste() else {
                onLifecycleEvent(.pasteDispatchCancelled)
                settleFailedDispatch()
                return
            }

            let didDispatchPaste: Bool
            switch dispatchStrategy {
            case .keyboardShortcut:
                didDispatchPaste = simulatePasteAction()
            case .targetApplicationPasteCommand:
                guard let targetApplication else {
                    onLifecycleEvent(.targetPasteCommandUnavailable)
                    onLifecycleEvent(.pasteDispatchFailed)
                    settleFailedDispatch()
                    return
                }
                switch targetPasteAction(targetApplication) {
                case true:
                    onLifecycleEvent(.targetPasteCommandDispatched)
                    didDispatchPaste = true
                case false:
                    onLifecycleEvent(.targetPasteCommandRejected)
                    didDispatchPaste = false
                case nil:
                    onLifecycleEvent(.targetPasteCommandUnavailable)
                    didDispatchPaste = false
                }
            }
            onLifecycleEvent(didDispatchPaste ? .pasteDispatched : .pasteDispatchFailed)
            if didDispatchPaste {
                onPasteDispatched()
            } else {
                settleFailedDispatch()
                return
            }

            // Arm restoration before completion bookkeeping. The dictation completion callback
            // persists attribution and refreshes UI; neither is allowed to extend how long the
            // transcript owns the user's clipboard.
            onLifecycleEvent(.clipboardRestoreScheduled)
            DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
                if pasteboard.changeCount == pasteChangeCount {
                    restoreClipboard(pasteboard, from: savedItems)
                    onLifecycleEvent(.clipboardRestored)
                } else {
                    onLifecycleEvent(.clipboardRestoreSkipped)
                }
                onClipboardSettled()
            }

            onPasteFinished(didDispatchPaste ? targetApplication : nil)
        }
    }

    /// Type text directly via CGEvent keyboard simulation without touching the clipboard.
    /// Common ASCII is posted as physical keydown+keyup events. Other text falls
    /// back to Unicode CGEvents so non-ASCII dictation still works.
    static func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            fputs("[muesli-native] failed to create event source for typeText\n", stderr)
            return
        }
        for char in text {
            if let (keyCode, flags) = physicalKeyMap[char] {
                postPhysicalKey(source: source, keyCode: keyCode, flags: flags)
            } else {
                postUnicodeCharacter(source: source, char: char)
            }
        }
    }

    static func canTypeUsingPhysicalKeys(_ text: String) -> Bool {
        text.allSatisfy { physicalKeyMap[$0] != nil }
    }

    /// Reads the active application's selection through Cmd+C while preserving the
    /// user's clipboard. This is a fallback for browser editors such as Google Docs,
    /// which can render a visible selection without exposing AXSelectedText.
    @MainActor
    static func copySelectedText(
        pasteboard: NSPasteboard = .general,
        timeout: TimeInterval = 0.35,
        pollInterval: TimeInterval = 0.01,
        simulateCopyAction: @MainActor () -> Bool = PasteController.simulateCopy
    ) -> String? {
        let savedItems = saveClipboard(pasteboard)
        let originalChangeCount = pasteboard.changeCount
        guard simulateCopyAction() else { return nil }

        let deadline = Date().addingTimeInterval(max(0, timeout))
        while pasteboard.changeCount == originalChangeCount, Date() < deadline {
            // Keep the main run loop responsive while the target app services Cmd+C.
            // Quill begins from a synchronous hotkey callback, so a nested run-loop
            // wait avoids blocking UI without moving clipboard access off MainActor.
            let nextPoll = min(deadline, Date().addingTimeInterval(max(0.001, pollInterval)))
            _ = RunLoop.current.run(mode: .default, before: nextPoll)
        }
        guard pasteboard.changeCount != originalChangeCount else { return nil }

        let copiedChangeCount = pasteboard.changeCount
        let copiedText = pasteboard.string(forType: .string)
        // Do not overwrite a newer clipboard write from another process.
        if pasteboard.changeCount == copiedChangeCount {
            restoreClipboard(pasteboard, from: savedItems)
        }
        guard let copiedText, !copiedText.isEmpty else { return nil }
        return copiedText
    }

    // MARK: - Private

    private static func simulateCopy() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            fputs("[muesli-native] failed to create event source for copy\n", stderr)
            return false
        }
        let keyCode: CGKeyCode = 8 // C
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            fputs("[muesli-native] failed to create keyboard events for copy\n", stderr)
            return false
        }
        MuesliSyntheticKeyboardEvent.mark(commandDown)
        MuesliSyntheticKeyboardEvent.mark(commandUp)
        commandDown.flags = .maskCommand
        commandUp.flags = .maskCommand
        commandDown.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        return true
    }

    private static func simulatePaste() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            fputs("[muesli-native] failed to create event source for paste\n", stderr)
            return false
        }
        let keyCode: CGKeyCode = 9 // V
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            fputs("[muesli-native] failed to create keyboard events for paste\n", stderr)
            return false
        }
        MuesliSyntheticKeyboardEvent.mark(commandDown)
        MuesliSyntheticKeyboardEvent.mark(commandUp)
        commandDown.flags = .maskCommand
        commandUp.flags = .maskCommand
        commandDown.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        return true
    }

    /// Invokes the target process's standard Cmd+V menu item through Accessibility.
    ///
    /// `true` means the target app accepted AXPress, `false` means the command was
    /// found but disabled/rejected, and `nil` means the app did not expose a
    /// standard Paste command. Resolving by shortcut metadata avoids depending on
    /// localized menu titles such as "Paste".
    private static func performTargetPasteCommand(in application: NSRunningApplication) -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let deadline = Date().addingTimeInterval(targetPasteAXTraversalBudget)
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let menuBar = axElement(
            appElement,
            attribute: kAXMenuBarAttribute as String,
            deadline: deadline
        ),
              let pasteItem = standardPasteMenuItem(
                in: menuBar,
                maxDepth: 4,
                deadline: deadline,
                visited: []
              ),
              configureTargetPasteTimeout(for: pasteItem, deadline: deadline)
        else { return nil }
        // Menu enabled state is lazily validated by AppKit/Electron and can be stale
        // while the menu is closed. AXPress is the authoritative acceptance signal.
        return AXUIElementPerformAction(pasteItem, kAXPressAction as CFString) == .success
    }

    private static func standardPasteMenuItem(
        in element: AXUIElement,
        maxDepth: Int,
        deadline: Date,
        visited: Set<AXUIElement>
    ) -> AXUIElement? {
        guard maxDepth >= 0,
              Date() < deadline,
              !visited.contains(element) else { return nil }
        var visited = visited
        visited.insert(element)

        guard let role = axString(
            element,
            attribute: kAXRoleAttribute as String,
            deadline: deadline
        ),
              let commandCharacter = axString(
                element,
                attribute: kAXMenuItemCmdCharAttribute as String,
                deadline: deadline
              ) else { return nil }
        let commandModifiers = axInt(
            element,
            attribute: kAXMenuItemCmdModifiersAttribute as String,
            deadline: deadline
        )
        if role == (kAXMenuItemRole as String),
           commandCharacter.caseInsensitiveCompare("V") == .orderedSame,
           commandModifiers == 0 {
            return element
        }

        guard let children = axChildren(element, deadline: deadline) else { return nil }
        for child in children {
            guard Date() < deadline else { return nil }
            if let match = standardPasteMenuItem(
                in: child,
                maxDepth: maxDepth - 1,
                deadline: deadline,
                visited: visited
            ) {
                return match
            }
        }
        return nil
    }

    static func targetPasteAXTimeout(until deadline: Date, now: Date = Date()) -> Float? {
        let remaining = Float(deadline.timeIntervalSince(now))
        guard remaining > 0 else { return nil }
        return min(targetPasteAXMaximumRequestTimeout, remaining)
    }

    private static func configureTargetPasteTimeout(
        for element: AXUIElement,
        deadline: Date
    ) -> Bool {
        guard let timeout = targetPasteAXTimeout(until: deadline) else { return false }
        return AXUIElementSetMessagingTimeout(element, timeout) == .success
            && Date() < deadline
    }

    private static func axElement(
        _ element: AXUIElement,
        attribute: String,
        deadline: Date
    ) -> AXUIElement? {
        guard configureTargetPasteTimeout(for: element, deadline: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func axChildren(_ element: AXUIElement, deadline: Date) -> [AXUIElement]? {
        guard configureTargetPasteTimeout(for: element, deadline: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
        let children = value as? [AXUIElement] else { return [] }
        return children
    }

    private static func axString(
        _ element: AXUIElement,
        attribute: String,
        deadline: Date
    ) -> String? {
        guard configureTargetPasteTimeout(for: element, deadline: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }

    private static func axInt(
        _ element: AXUIElement,
        attribute: String,
        deadline: Date
    ) -> Int? {
        guard configureTargetPasteTimeout(for: element, deadline: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.intValue
    }

    private static func postPhysicalKey(source: CGEventSource, keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        MuesliSyntheticKeyboardEvent.mark(keyDown)
        MuesliSyntheticKeyboardEvent.mark(keyUp)
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func postUnicodeCharacter(source: CGEventSource, char: Character) {
        var utf16 = Array(char.utf16)
        utf16.withUnsafeMutableBufferPointer { buf in
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return }
            MuesliSyntheticKeyboardEvent.mark(keyDown)
            MuesliSyntheticKeyboardEvent.mark(keyUp)
            keyDown.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            keyUp.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    /// Snapshot every item on the pasteboard so we can put it back later.
    /// Returns an array of (type, data) pairs for each item.
    /// Note: Lazy/promised clipboard providers may return nil for some types —
    /// those types are skipped, so restoration may be partial for apps that use
    /// deferred clipboard rendering.
    private static func saveClipboard(_ pasteboard: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        var saved: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in items {
            var pairs: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    pairs.append((type, data))
                }
            }
            if !pairs.isEmpty {
                saved.append(pairs)
            }
        }
        return saved
    }

    /// Restore previously saved clipboard contents. If nothing was saved, clears the clipboard
    /// so dictation text doesn't linger.
    private static func restoreClipboard(_ pasteboard: NSPasteboard, from saved: [[(NSPasteboard.PasteboardType, Data)]]) {
        pasteboard.clearContents()
        if saved.isEmpty { return }
        var restoredItems: [NSPasteboardItem] = []
        for itemPairs in saved {
            let item = NSPasteboardItem()
            for (type, data) in itemPairs {
                item.setData(data, forType: type)
            }
            restoredItems.append(item)
        }
        pasteboard.writeObjects(restoredItems)
    }
}
