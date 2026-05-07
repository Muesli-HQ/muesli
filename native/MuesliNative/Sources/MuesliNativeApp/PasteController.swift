import AppKit
import ApplicationServices
import Foundation
import MuesliCore

enum PasteController {
    /// How long to wait after simulating Cmd+V before restoring the clipboard.
    /// The receiving app must have consumed the paste data within this window.
    private static let clipboardRestoreDelay: TimeInterval = 0.5
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
    /// Flow: save clipboard → write text → Cmd+V → restore clipboard after delay.
    /// If the clipboard cannot be saved (e.g. lazy-provided data), falls back to a simple
    /// paste without restoration.
    static func paste(text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents (all types) so we can restore after paste.
        let savedItems = saveClipboard(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulatePaste()

            // Restore the original clipboard contents after the receiving app has consumed the paste.
            DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
                restoreClipboard(pasteboard, from: savedItems)
            }
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

    // MARK: - Private

    private static func simulatePaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            fputs("[muesli-native] failed to create event source for paste\n", stderr)
            return
        }
        let keyCode: CGKeyCode = 9 // V
        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        commandDown?.flags = .maskCommand
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        commandUp?.flags = .maskCommand
        commandDown?.post(tap: .cghidEventTap)
        commandUp?.post(tap: .cghidEventTap)
    }

    private static func postPhysicalKey(source: CGEventSource, keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
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
