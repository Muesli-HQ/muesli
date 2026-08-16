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

enum FocusedTextCaretGeometryConfidence: String, Equatable, Sendable {
    case exact
    case inferred
    case unavailable
}

struct FocusedTextColor: Equatable, Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var relativeLuminance: CGFloat {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }
}

struct FocusedTextPresentationStyle: Equatable, Sendable {
    let fontName: String?
    let fontSize: CGFloat?
    let foregroundColor: FocusedTextColor?
    let backgroundColor: FocusedTextColor?

    var supportsInlineGhost: Bool {
        guard let fontSize, (7 ... 96).contains(fontSize) else { return false }
        return foregroundColor != nil || backgroundColor != nil
    }
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
    let caretGeometryConfidence: FocusedTextCaretGeometryConfidence
    let presentationStyle: FocusedTextPresentationStyle?
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
    let caretGeometryConfidence: FocusedTextCaretGeometryConfidence
    let presentationStyle: FocusedTextPresentationStyle?
}

protocol FocusedTextReading {
    func readFocusedText(maxPrefixCharacters: Int, maxSuffixCharacters: Int) -> FocusedTextRawSnapshot?
}

protocol FocusedTextWriting {
    func insertText(
        _ text: String,
        processID: pid_t,
        elementIdentifier: UInt,
        bundleID: String,
        selection: FocusedTextRange
    ) -> Bool
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
    private let writer: any FocusedTextWriting

    init(
        reader: any FocusedTextReading = SystemFocusedTextReader(),
        currentProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        currentBundleID: String = Bundle.main.bundleIdentifier ?? "",
        writer: any FocusedTextWriting = SystemFocusedTextWriter()
    ) {
        self.reader = reader
        self.currentProcessID = currentProcessID
        self.currentBundleID = currentBundleID
        self.writer = writer
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
            fingerprint: fingerprint,
            caretGeometryConfidence: raw.caretGeometryConfidence,
            presentationStyle: raw.presentationStyle
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

    /// Inserts into the exact focused element that was revalidated immediately
    /// before acceptance. Accessibility insertion avoids sending an app-owned
    /// Tab/Return event and works in many custom web editors that ignore
    /// synthesized per-character keyboard events.
    func insertText(_ text: String, into context: FocusedTextContext) -> Bool {
        guard !text.isEmpty else { return false }
        return writer.insertText(
            text,
            processID: context.processID,
            elementIdentifier: context.fingerprint.elementIdentifier,
            bundleID: context.bundleID,
            selection: context.selection
        )
    }
}

struct SystemFocusedTextWriter: FocusedTextWriting {
    /// These hosts expose `AXSelectedText` as writable and return success while
    /// silently discarding the value. Let the coordinator use physical text
    /// events instead of mistaking that no-op for a completed insertion.
    private static let syntheticOnlyBundleIDs: Set<String> = [
        "com.openai.codex",
    ]

    static func shouldAttemptAccessibilityInsertion(bundleID: String) -> Bool {
        !syntheticOnlyBundleIDs.contains(bundleID.lowercased())
    }

    static func selectionConfirmsInsertion(
        text: String,
        before: FocusedTextRange,
        after: FocusedTextRange?
    ) -> Bool {
        guard !text.isEmpty, before.length == 0, let after, after.length == 0 else { return false }
        return after.location == before.location + (text as NSString).length
    }

    func insertText(
        _ text: String,
        processID: pid_t,
        elementIdentifier: UInt,
        bundleID: String,
        selection: FocusedTextRange
    ) -> Bool {
        guard AXIsProcessTrusted(),
              !text.isEmpty,
              Self.shouldAttemptAccessibilityInsertion(bundleID: bundleID),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return false }

        let axApp = AXUIElementCreateApplication(processID)
        var rawElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedUIElementAttribute as CFString,
            &rawElement
        ) == .success,
        let rawElement,
        CFGetTypeID(rawElement) == AXUIElementGetTypeID() else { return false }

        let element = rawElement as! AXUIElement
        guard CFHash(element) == elementIdentifier,
              Self.selectedTextRange(of: element) == selection else { return false }

        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else { return false }

        // AX setters are synchronous for native controls, but some bridged
        // editors publish their updated caret on the next run-loop turn. Retry
        // briefly before declaring the write a no-op so the fallback cannot
        // duplicate text that was genuinely inserted.
        for retry in 0 ..< 3 {
            if Self.selectionConfirmsInsertion(
                text: text,
                before: selection,
                after: Self.selectedTextRange(of: element)
            ) {
                return true
            }
            if retry < 2 { Thread.sleep(forTimeInterval: 0.008) }
        }
        return false
    }

    private static func selectedTextRange(of element: AXUIElement) -> FocusedTextRange? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXValueGetTypeID() else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rawValue as! AXValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else { return nil }
        return FocusedTextRange(location: range.location, length: range.length)
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

        let caretGeometry = selection.flatMap { Self.caretGeometry(element: element, selection: $0) }
        let presentationStyle = selection.flatMap { Self.presentationStyle(element: element, selection: $0) }

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
            caretBounds: caretGeometry?.bounds,
            elementBounds: Self.elementBounds(element),
            caretGeometryConfidence: caretGeometry?.confidence ?? .unavailable,
            presentationStyle: presentationStyle
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

    private struct CaretGeometry {
        let bounds: CGRect
        let confidence: FocusedTextCaretGeometryConfidence
    }

    private static func caretGeometry(element: AXUIElement, selection: FocusedTextRange) -> CaretGeometry? {
        if let exact = bounds(element: element, range: selection), exact.isUsableCaretBounds {
            return CaretGeometry(bounds: exact, confidence: .exact)
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
            return CaretGeometry(
                bounds: CGRect(x: next.minX, y: next.minY, width: 0, height: next.height),
                confidence: .inferred
            )
        }
        if selection.location > 0,
           let previous = bounds(
               element: element,
               range: FocusedTextRange(location: selection.location - 1, length: 1)
           ), previous.isUsableTextBounds {
            return CaretGeometry(
                bounds: CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height),
                confidence: .inferred
            )
        }
        return nil
    }

    private static func presentationStyle(
        element: AXUIElement,
        selection: FocusedTextRange
    ) -> FocusedTextPresentationStyle? {
        let characterLocation = selection.location > 0 ? selection.location - 1 : selection.location
        guard let attributed = attributedString(
            element: element,
            range: FocusedTextRange(location: characterLocation, length: 1)
        ), attributed.length > 0 else { return nil }

        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        let fontAttribute = kAXFontTextAttribute.takeUnretainedValue() as String
        let fontNameKey = kAXFontNameKey.takeUnretainedValue()
        let visibleNameKey = kAXVisibleNameKey.takeUnretainedValue()
        let fontSizeKey = kAXFontSizeKey.takeUnretainedValue()
        let foregroundAttribute = kAXForegroundColorTextAttribute.takeUnretainedValue() as String
        let backgroundAttribute = kAXBackgroundColorTextAttribute.takeUnretainedValue() as String
        let fontInfo = attributes[
            NSAttributedString.Key(rawValue: fontAttribute)
        ] as? NSDictionary
        let fontName = (fontInfo?.object(forKey: fontNameKey) as? String)
            ?? (fontInfo?.object(forKey: visibleNameKey) as? String)
        let fontSize = (fontInfo?.object(forKey: fontSizeKey) as? NSNumber).map { CGFloat(truncating: $0) }
        let foreground = focusedTextColor(from: attributes[
            NSAttributedString.Key(rawValue: foregroundAttribute)
        ])
        let background = focusedTextColor(from: attributes[
            NSAttributedString.Key(rawValue: backgroundAttribute)
        ])

        guard fontName != nil || fontSize != nil || foreground != nil || background != nil else { return nil }
        return FocusedTextPresentationStyle(
            fontName: fontName,
            fontSize: fontSize,
            foregroundColor: foreground,
            backgroundColor: background
        )
    }

    private static func attributedString(
        element: AXUIElement,
        range: FocusedTextRange
    ) -> NSAttributedString? {
        guard range.location >= 0, range.length > 0 else { return nil }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXAttributedStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        ) == .success else { return nil }
        return result as? NSAttributedString
    }

    private static func focusedTextColor(from value: Any?) -> FocusedTextColor? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CGColor.typeID else { return nil }
        return FocusedTextColor(cgColor: value as! CGColor)
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

private extension FocusedTextColor {
    init?(cgColor: CGColor) {
        guard let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB) else { return nil }
        self.init(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }
}
