import AppKit
import ApplicationServices
import Foundation

struct FocusedTextRange: Equatable, Sendable {
    let location: Int
    let length: Int
}

struct FocusedTextFingerprint: Equatable, Sendable {
    let processID: pid_t
    let elementIdentifier: UInt
    let selection: FocusedTextRange
    let prefix: String
    let suffix: String
}

struct FocusedTextContext: Equatable, Sendable {
    let appName: String
    let bundleID: String
    let processID: pid_t
    let browserLocation: String?
    let windowTitle: String
    let role: String
    let subrole: String
    let fieldMetadata: String
    let selection: FocusedTextRange
    let prefix: String
    let suffix: String
    /// Quartz global coordinates (top-left origin), matching Accessibility bounds.
    let caretBounds: CGRect?
    let elementBounds: CGRect?
    let fingerprint: FocusedTextFingerprint
}

struct FocusedTextRawSnapshot: Equatable, Sendable {
    let appName: String
    let bundleID: String
    let processID: pid_t
    let elementIdentifier: UInt
    let browserLocation: String?
    let windowTitle: String
    let role: String
    let subrole: String
    let fieldMetadata: String
    let isEnabled: Bool
    let isEditable: Bool
    let isSecure: Bool
    let selection: FocusedTextRange?
    let prefix: String
    let suffix: String
    let selectedText: String
    let caretBounds: CGRect?
    let elementBounds: CGRect?
}

protocol FocusedTextReading {
    func readFocusedText(maxPrefixCharacters: Int, maxSuffixCharacters: Int) -> FocusedTextRawSnapshot?
}

enum FocusedTextFallbackReader {
    static func boundedSegments(
        fullText: String,
        selection: FocusedTextRange?,
        maxPrefixCharacters: Int,
        maxSuffixCharacters: Int
    ) -> (prefix: String, suffix: String) {
        let nsValue = fullText as NSString
        let location = min(max(selection?.location ?? nsValue.length, 0), nsValue.length)
        let selectedLength = min(max(selection?.length ?? 0, 0), nsValue.length - location)
        let prefixStart = max(0, location - maxPrefixCharacters)
        let suffixStart = location + selectedLength
        let suffixLength = min(maxSuffixCharacters, nsValue.length - suffixStart)
        return (
            nsValue.substring(with: NSRange(location: prefixStart, length: location - prefixStart)),
            nsValue.substring(with: NSRange(location: suffixStart, length: suffixLength))
        )
    }
}

/// Shared, bounded Accessibility capture for dictation and Cotypist.
struct FocusedTextContextService {
    static let maximumPrefixCharacters = 1_200
    static let maximumSuffixCharacters = 400

    private let reader: any FocusedTextReading
    private let currentProcessID: pid_t
    private let currentBundleID: String

    init(
        reader: any FocusedTextReading = SystemFocusedTextReader(),
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        currentBundleID: String = Bundle.main.bundleIdentifier ?? ""
    ) {
        self.reader = reader
        self.currentProcessID = currentProcessID
        self.currentBundleID = currentBundleID
    }

    func capture(excludedBundleIDs: Set<String>) -> FocusedTextContext? {
        guard let raw = reader.readFocusedText(
            maxPrefixCharacters: Self.maximumPrefixCharacters,
            maxSuffixCharacters: Self.maximumSuffixCharacters
        ) else { return nil }

        guard raw.processID != currentProcessID,
              raw.bundleID != currentBundleID,
              !raw.bundleID.hasPrefix("com.muesli"),
              !excludedBundleIDs.contains(raw.bundleID),
              raw.isEnabled,
              raw.isEditable,
              !raw.isSecure,
              let selection = raw.selection,
              selection.length == 0,
              raw.prefix.count >= 3 else { return nil }

        let fingerprint = FocusedTextFingerprint(
            processID: raw.processID,
            elementIdentifier: raw.elementIdentifier,
            selection: selection,
            prefix: raw.prefix,
            suffix: raw.suffix
        )
        return FocusedTextContext(
            appName: raw.appName,
            bundleID: raw.bundleID,
            processID: raw.processID,
            browserLocation: raw.browserLocation,
            windowTitle: raw.windowTitle,
            role: raw.role,
            subrole: raw.subrole,
            fieldMetadata: raw.fieldMetadata,
            selection: selection,
            prefix: raw.prefix,
            suffix: raw.suffix,
            caretBounds: raw.caretBounds,
            elementBounds: raw.elementBounds,
            fingerprint: fingerprint
        )
    }

    /// Less restrictive capture for dictation, which may intentionally operate on
    /// read-only controls or a non-empty selection.
    func captureRaw(maxPrefixCharacters: Int, maxSuffixCharacters: Int = 0) -> FocusedTextRawSnapshot? {
        reader.readFocusedText(
            maxPrefixCharacters: maxPrefixCharacters,
            maxSuffixCharacters: maxSuffixCharacters
        )
    }
}

struct SystemFocusedTextReader: FocusedTextReading {
    private static let smallDocumentLimit = 5_000
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac",
    ]

    func readFocusedText(maxPrefixCharacters: Int, maxSuffixCharacters: Int) -> FocusedTextRawSnapshot? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let element = Self.elementAttribute(axApp, kAXFocusedUIElementAttribute as String) else { return nil }

        let role = Self.stringAttribute(element, kAXRoleAttribute as String)
        let subrole = Self.stringAttribute(element, kAXSubroleAttribute as String)
        let enabled = Self.boolAttribute(element, kAXEnabledAttribute as String) ?? true
        let editable = Self.isEditable(element: element, role: role)
        let secure = subrole == (kAXSecureTextFieldSubrole as String)
            || role.localizedCaseInsensitiveContains("password")
            || subrole.localizedCaseInsensitiveContains("secure")

        let selection = Self.rangeAttribute(element, kAXSelectedTextRangeAttribute as String)
        let segments = Self.readTextSegments(
            element: element,
            selection: selection,
            maxPrefixCharacters: maxPrefixCharacters,
            maxSuffixCharacters: maxSuffixCharacters
        )
        let focusedWindow = Self.elementAttribute(axApp, kAXFocusedWindowAttribute as String)
        let windowTitle = focusedWindow.map { Self.stringAttribute($0, kAXTitleAttribute as String) } ?? ""
        let browserLocation = Self.browserLocation(for: app, focusedWindow: focusedWindow)

        let metadataAttributes = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            kAXPlaceholderValueAttribute as String,
            kAXIdentifierAttribute as String,
        ]
        let metadata = metadataAttributes
            .map { Self.stringAttribute(element, $0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            }
            .joined(separator: " · ")

        return FocusedTextRawSnapshot(
            appName: app.localizedName ?? "Unknown",
            bundleID: app.bundleIdentifier ?? "",
            processID: app.processIdentifier,
            elementIdentifier: CFHash(element),
            browserLocation: browserLocation,
            windowTitle: windowTitle,
            role: role,
            subrole: subrole,
            fieldMetadata: metadata,
            isEnabled: enabled,
            isEditable: editable,
            isSecure: secure,
            selection: selection,
            prefix: segments.prefix,
            suffix: segments.suffix,
            selectedText: Self.stringAttribute(element, kAXSelectedTextAttribute as String),
            caretBounds: selection.flatMap { Self.caretBounds(element: element, selection: $0) },
            elementBounds: Self.elementBounds(element)
        )
    }

    static func sanitizedBrowserLocation(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard let components = URLComponents(string: value), let host = components.host, !host.isEmpty else {
            return String(value.prefix(100))
        }
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        return "\(host)\(port)\(path)"
    }

    private static func browserLocation(
        for app: NSRunningApplication,
        focusedWindow: AXUIElement?
    ) -> String? {
        guard browserBundleIDs.contains(app.bundleIdentifier ?? ""), let focusedWindow else { return nil }
        return sanitizedBrowserLocation(stringAttribute(focusedWindow, kAXDocumentAttribute as String))
    }

    private static func readTextSegments(
        element: AXUIElement,
        selection: FocusedTextRange?,
        maxPrefixCharacters: Int,
        maxSuffixCharacters: Int
    ) -> (prefix: String, suffix: String) {
        guard let selection else { return fallbackTextSegments(element: element, selection: nil, maxPrefixCharacters: maxPrefixCharacters, maxSuffixCharacters: maxSuffixCharacters) }

        let prefixLength = min(max(selection.location, 0), maxPrefixCharacters)
        let prefix = prefixLength > 0
            ? stringForRange(element, location: selection.location - prefixLength, length: prefixLength)
            : ""

        let characterCount = intAttribute(element, kAXNumberOfCharactersAttribute as String)
        let suffixLength = characterCount.map { min(max($0 - selection.location - selection.length, 0), maxSuffixCharacters) }
            ?? maxSuffixCharacters
        let suffix = suffixLength > 0
            ? stringForRange(element, location: selection.location + selection.length, length: suffixLength)
            : ""

        if (prefixLength == 0 || !prefix.isEmpty) && (suffixLength == 0 || !suffix.isEmpty) {
            return (prefix, suffix)
        }
        return fallbackTextSegments(
            element: element,
            selection: selection,
            maxPrefixCharacters: maxPrefixCharacters,
            maxSuffixCharacters: maxSuffixCharacters
        )
    }

    private static func fallbackTextSegments(
        element: AXUIElement,
        selection: FocusedTextRange?,
        maxPrefixCharacters: Int,
        maxSuffixCharacters: Int
    ) -> (prefix: String, suffix: String) {
        if let count = intAttribute(element, kAXNumberOfCharactersAttribute as String), count > smallDocumentLimit {
            return ("", "")
        }
        let full = stringAttribute(element, kAXValueAttribute as String)
        guard !full.isEmpty else { return ("", "") }
        return FocusedTextFallbackReader.boundedSegments(
            fullText: full,
            selection: selection,
            maxPrefixCharacters: maxPrefixCharacters,
            maxSuffixCharacters: maxSuffixCharacters
        )
    }

    private static func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String {
        guard location >= 0, length >= 0 else { return "" }
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return "" }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        ) == .success else { return "" }
        return result as? String ?? ""
    }

    private static func caretBounds(element: AXUIElement, selection: FocusedTextRange) -> CGRect? {
        if let exact = bounds(element: element, range: selection), exact.isUsableCaretBounds {
            return exact
        }

        // Some text controls return CGRect.zero for a zero-length range even though
        // neighboring character bounds are available. Prefer the next character so
        // a caret at the start of a wrapped line stays on that line; at the end of
        // the value, infer the caret from the trailing edge of the previous glyph.
        guard selection.length == 0 else { return nil }
        if let next = bounds(
            element: element,
            range: FocusedTextRange(location: selection.location, length: 1)
        ), next.isUsableTextBounds {
            return CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        }
        if selection.location > 0,
           let previous = bounds(
               element: element,
               range: FocusedTextRange(location: selection.location - 1, length: 1)
           ), previous.isUsableTextBounds {
            return CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        }
        return nil
    }

    private static func bounds(element: AXUIElement, range: FocusedTextRange) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        ) == .success, let value = result, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.isFinite, !rect.isNull else { return nil }
        return rect
    }

    private static func elementBounds(_ element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = rawAttribute(element, kAXPositionAttribute as String),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              let sizeValue = rawAttribute(element, kAXSizeAttribute as String),
              CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        let rect = CGRect(origin: position, size: size)
        return rect.isUsableElementBounds ? rect : nil
    }

    private static func isEditable(element: AXUIElement, role: String) -> Bool {
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        guard editableRoles.contains(role) || role.localizedCaseInsensitiveContains("text") else { return false }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue { return true }
        return rangeAttribute(element, kAXSelectedTextRangeAttribute as String) != nil
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = rawAttribute(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func rawAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String {
        rawAttribute(element, attribute) as? String ?? ""
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        (rawAttribute(element, attribute) as? NSNumber)?.boolValue
    }

    private static func intAttribute(_ element: AXUIElement, _ attribute: String) -> Int? {
        (rawAttribute(element, attribute) as? NSNumber)?.intValue
    }

    private static func rangeAttribute(_ element: AXUIElement, _ attribute: String) -> FocusedTextRange? {
        guard let value = rawAttribute(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return FocusedTextRange(location: range.location, length: range.length)
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && size.width.isFinite && size.height.isFinite
    }

    var isUsableCaretBounds: Bool {
        isFinite && !isNull && width >= 0 && height > 0
    }

    var isUsableTextBounds: Bool {
        isFinite && !isNull && width > 0 && height > 0
    }

    var isUsableElementBounds: Bool {
        isFinite && !isNull && width > 0 && height > 0
    }
}
