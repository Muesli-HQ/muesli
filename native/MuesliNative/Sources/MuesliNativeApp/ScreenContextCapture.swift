import AppKit
import ApplicationServices
import Vision

// MARK: - Dictation context (Accessibility + optional on-device OCR)

struct DictationContext {
    let appName: String
    let bundleID: String
    let documentContext: String
    let selectedText: String
    let url: String?
    let documentIdentifier: String?
    let ocrText: String
}

enum DictationContextCapture {
    struct FocusedWindowSnapshot {
        let documentIdentifier: String?
        let title: String
        let frame: CGRect?
    }

    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.brave.Browser", "com.microsoft.edgemac",
    ]

    /// Captures focused app name + text context via Accessibility API, with optional
    /// on-device OCR when Screen Recording permission is already granted.
    static func capture(
        includeScreenOCR: Bool,
        shouldCaptureScreenOCR: (@Sendable () async -> Bool)? = nil,
        allowTitleFallback: Bool = true
    ) async -> DictationContext {
        let base = capture(allowTitleFallback: allowTitleFallback)
        guard includeScreenOCR, CGPreflightScreenCaptureAccess() else { return base }
        let screenContext = await ScreenContextCapture.captureVisibleScreen(
            shouldCapture: shouldCaptureScreenOCR,
            allowTitleFallback: allowTitleFallback
        )
        guard screenContext?.bundleID == base.bundleID,
              (base.documentIdentifier == nil
                || screenContext?.documentIdentifier == base.documentIdentifier) else { return base }
        let ocrText = screenContext?.ocrText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !ocrText.isEmpty else { return base }
        return DictationContext(
            appName: base.appName,
            bundleID: base.bundleID,
            documentContext: base.documentContext,
            selectedText: base.selectedText,
            url: base.url,
            documentIdentifier: base.documentIdentifier,
            ocrText: ocrText
        )
    }

    /// Captures focused app name + text context via Accessibility API.
    /// Lightweight and deterministic — no screenshots, no OCR.
    static func capture(allowTitleFallback: Bool = true) -> DictationContext {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown"
        let bundleID = app?.bundleIdentifier ?? ""

        var docContext = ""
        var selectedText = ""

        if let app, AXIsProcessTrusted(), let focusedElement = focusedUIElement(for: app) {
            docContext = textBeforeCursor(focusedElement, maxChars: 200)
            selectedText = selectedTextValue(in: focusedElement)
        }

        let url = browserURL(for: app)
        let documentIdentifier = focusedDocumentIdentifier(
            for: app,
            allowTitleFallback: allowTitleFallback
        )

        fputs("[muesli-native] dictation context: app=\(appName) docContext=\(docContext.count) chars selectedText=\(selectedText.count) chars url=\(url ?? "none")\n", stderr)

        return DictationContext(
            appName: appName,
            bundleID: bundleID,
            documentContext: docContext,
            selectedText: selectedText,
            url: url,
            documentIdentifier: documentIdentifier,
            ocrText: ""
        )
    }

    /// Formats for the post-processor LLM prompt. Compact, high-signal.
    static func formatForPrompt(_ ctx: DictationContext) -> String {
        var parts = "App: \(ctx.appName)"
        if let url = ctx.url {
            parts += " (\(url))"
        }
        if !ctx.documentContext.isEmpty {
            parts += "\nDocument context: \(ctx.documentContext)"
        }
        if !ctx.selectedText.isEmpty {
            parts += "\nSelected text: \(ctx.selectedText)"
        }
        if !ctx.ocrText.isEmpty {
            parts += "\nOCR screen text: \(ctx.ocrText)"
        }
        return parts
    }

    /// Compact format for the app_context DB column.
    static func formatForStorage(_ ctx: DictationContext) -> String {
        var parts = "\(ctx.appName)|\(ctx.bundleID)"
        if let url = ctx.url { parts += "|\(url)" }
        if !ctx.documentContext.isEmpty {
            parts += "|doc:\(ctx.documentContext)"
        }
        return parts
    }

    /// Quill screen context is optional, so fail closed when macOS cannot bind
    /// the captured context to the document that owns the selected text.
    static func matchesQuilSelection(
        _ context: DictationContext,
        bundleID expectedBundleID: String,
        documentIdentifier expectedDocumentIdentifier: String
    ) -> Bool {
        let capturedBundleID = context.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedBundleID = expectedBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedDocumentIdentifier = context.documentIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expectedDocumentIdentifier = expectedDocumentIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !capturedBundleID.isEmpty,
              !expectedBundleID.isEmpty,
              !capturedDocumentIdentifier.isEmpty,
              !expectedDocumentIdentifier.isEmpty else { return false }
        return capturedBundleID == expectedBundleID
            && capturedDocumentIdentifier == expectedDocumentIdentifier
    }

    // MARK: - Accessibility helpers

    static func focusedUIElement(for app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement,
              CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        return (element as! AXUIElement)
    }

    /// Reads up to `maxChars` of text before the cursor using the parameterized
    /// AX string-for-range attribute. Falls back to suffix of full value if unsupported.
    private static func textBeforeCursor(_ element: AXUIElement, maxChars: Int) -> String {
        // Try cursor-aware read via kAXSelectedTextRangeAttribute + kAXStringForRangeParameterizedAttribute
        if let selectedRange = selectedTextRange(element) {
            let cursorPos = selectedRange.location
            let prefixLen = min(cursorPos, maxChars)
            if prefixLen > 0 {
                var sliceRange = CFRange(location: cursorPos - prefixLen, length: prefixLen)
                let axRange: AXValue? = AXValueCreate(.cfRange, &sliceRange)
                if let axRange {
                    var sliceRef: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(
                        element,
                        kAXStringForRangeParameterizedAttribute as CFString,
                        axRange,
                        &sliceRef
                    ) == .success, let text = sliceRef as? String {
                        return text
                    }
                }
            }
        }

        // Fallback: read full value only if the document is small enough that the
        // IPC cost is acceptable. Skip for large documents (>5000 chars) to avoid
        // copying the entire text buffer across the process boundary.
        var charCountRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &charCountRef) == .success,
           let count = charCountRef as? Int, count > 5000 {
            return ""
        }
        let full = axStringValue(element, attribute: kAXValueAttribute as String)
        if full.count > maxChars {
            return "..." + String(full.suffix(maxChars))
        }
        return full
    }

    static func axStringValue(_ element: AXUIElement, attribute: String) -> String {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let str = value as? String else { return "" }
        return str
    }

    static func selectedTextRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    /// Some web editors expose a selected range and parameterized text without
    /// implementing AXSelectedText. Prefer the direct attribute, then reconstruct
    /// the exact selection from that range before considering clipboard fallback.
    static func selectedTextValue(in element: AXUIElement) -> String {
        let direct = axStringValue(element, attribute: kAXSelectedTextAttribute as String)
        guard direct.isEmpty, let range = selectedTextRange(element), range.length > 0 else {
            return direct
        }
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return "" }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        ) == .success else { return "" }
        return value as? String ?? ""
    }

    static func isBrowserApplication(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return browserBundleIDs.contains(bundleID)
    }

    static func browserURL(for app: NSRunningApplication?) -> String? {
        guard let app else { return nil }
        guard isBrowserApplication(app) else { return nil }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }

        let axWindow = (window as! AXUIElement)
        var urlValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &urlValue) == .success,
           let url = urlValue as? String, !url.isEmpty {
            if let parsed = URL(string: url) {
                return "\(parsed.host ?? "")\(parsed.path)"
            }
            return String(url.prefix(100))
        }
        return nil
    }

    /// Returns the focused document identifier. Window titles are useful as
    /// descriptive context, but callers that bind asynchronous context across
    /// time must disable the fallback because titles are neither stable nor unique.
    static func focusedDocumentIdentifier(
        for app: NSRunningApplication?,
        allowTitleFallback: Bool = true
    ) -> String? {
        focusedWindowSnapshot(
            for: app,
            allowTitleFallback: allowTitleFallback
        )?.documentIdentifier
    }

    static func focusedWindowSnapshot(
        for app: NSRunningApplication?,
        allowTitleFallback: Bool = true
    ) -> FocusedWindowSnapshot? {
        guard let app else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef,
              CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        let window = windowRef as! AXUIElement
        let title = axStringValue(window, attribute: kAXTitleAttribute as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attributes = allowTitleFallback
            ? [kAXDocumentAttribute as String, kAXTitleAttribute as String]
            : [kAXDocumentAttribute as String]
        var documentIdentifier: String?
        for attribute in attributes {
            let value = axStringValue(window, attribute: attribute)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                documentIdentifier = String(value.prefix(500))
                break
            }
        }

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var frame: CGRect?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
           AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let positionRef,
           let sizeRef,
           CFGetTypeID(positionRef) == AXValueGetTypeID(),
           CFGetTypeID(sizeRef) == AXValueGetTypeID() {
            let positionValue = positionRef as! AXValue
            let sizeValue = sizeRef as! AXValue
            var position = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(positionValue, .cgPoint, &position),
               AXValueGetValue(sizeValue, .cgSize, &size),
               size.width > 0,
               size.height > 0 {
                frame = CGRect(origin: position, size: size)
            }
        }

        return FocusedWindowSnapshot(
            documentIdentifier: documentIdentifier,
            title: title,
            frame: frame
        )
    }
}

@MainActor
final class QuilSelectionSnapshot {
    let text: String
    let application: NSRunningApplication
    private let element: AXUIElement
    private let selectedRange: CFRange?
    private let usesClipboardFallback: Bool
    let contextDocumentIdentifier: String?

    private init(
        text: String,
        application: NSRunningApplication,
        element: AXUIElement,
        selectedRange: CFRange?,
        usesClipboardFallback: Bool,
        contextDocumentIdentifier: String?
    ) {
        self.text = text
        self.application = application
        self.element = element
        self.selectedRange = selectedRange
        self.usesClipboardFallback = usesClipboardFallback
        self.contextDocumentIdentifier = contextDocumentIdentifier
    }

    static func capture() throws -> QuilSelectionSnapshot {
        guard AXIsProcessTrusted() else { throw QuilTransformationError.accessibilityPermissionRequired }
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = DictationContextCapture.focusedUIElement(for: application) else {
            throw QuilTransformationError.noTextTarget
        }
        var text = DictationContextCapture.selectedTextValue(in: element)
        var usesClipboardFallback = false
        if text.isEmpty, DictationContextCapture.isBrowserApplication(application) {
            text = PasteController.copySelectedText() ?? ""
            usesClipboardFallback = !text.isEmpty
        }
        return QuilSelectionSnapshot(
            text: text,
            application: application,
            element: element,
            selectedRange: DictationContextCapture.selectedTextRange(element),
            usesClipboardFallback: usesClipboardFallback,
            contextDocumentIdentifier: DictationContextCapture.focusedDocumentIdentifier(
                for: application,
                allowTitleFallback: false
            )
        )
    }

    func isStillCurrent() -> Bool {
        guard isTargetStillFocused(),
              let focused = DictationContextCapture.focusedUIElement(for: application) else { return false }
        if usesClipboardFallback {
            // Google Docs does not expose its selection through AX. Re-copy once,
            // immediately before replacement, rather than at every lifecycle guard.
            return true
        }
        guard DictationContextCapture.selectedTextValue(in: focused) == text else { return false }
        guard let selectedRange else { return true }
        guard let currentRange = DictationContextCapture.selectedTextRange(focused) else { return false }
        return currentRange.location == selectedRange.location
            && currentRange.length == selectedRange.length
    }

    func isStillCurrentForReplacement() -> Bool {
        guard isStillCurrent() else { return false }
        if usesClipboardFallback {
            return PasteController.copySelectedText() == text
        }
        return true
    }

    func matches(context: DictationContext?) -> Bool {
        guard let context else { return true }
        guard let contextDocumentIdentifier else { return false }
        return DictationContextCapture.matchesQuilSelection(
            context,
            bundleID: application.bundleIdentifier ?? "",
            documentIdentifier: contextDocumentIdentifier
        )
    }

    /// Safe to call after Quill has staged its replacement on the clipboard.
    /// Full text equality is checked before staging; this last guard only ensures
    /// focus has not moved during the short paste dispatch delay.
    func isTargetStillFocused() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier,
              let focused = DictationContextCapture.focusedUIElement(for: application) else { return false }
        return CFEqual(focused, element)
    }
}

// MARK: - Meeting context (Screenshot + OCR — richer, for cloud LLMs)

struct ScreenContext {
    let appName: String
    let bundleID: String
    let documentIdentifier: String?
    let ocrText: String
    let capturedAt: Date
}

enum ScreenContextCapture {
    struct WindowCandidate {
        let id: CGWindowID
        let frame: CGRect
        let title: String
    }


    /// Captures the frontmost app window and runs on-device OCR. The screenshot itself
    /// is not persisted or sent to cleanup backends; only recognized text is used.
    static func captureVisibleScreen(
        shouldCapture: (@Sendable () async -> Bool)? = nil,
        allowTitleFallback: Bool = true
    ) async -> ScreenContext? {
        await captureFrontmostWindow(
            logLabel: "dictation OCR",
            shouldCapture: shouldCapture,
            allowTitleFallback: allowTitleFallback
        )
    }

    /// Captures a screenshot of the focused window and runs on-device OCR.
    /// Used for meeting context only — heavier than AX but provides visual content.
    static func captureOnce() async -> ScreenContext? {
        await captureFrontmostWindow(
            logLabel: "meeting OCR",
            allowTitleFallback: true
        )
    }

    private static func captureFrontmostWindow(
        logLabel: String,
        shouldCapture: (@Sendable () async -> Bool)? = nil,
        allowTitleFallback: Bool
    ) async -> ScreenContext? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown"
        let bundleID = app?.bundleIdentifier ?? ""
        guard let focusedWindow = DictationContextCapture.focusedWindowSnapshot(
            for: app,
            allowTitleFallback: allowTitleFallback
        ), let focusedFrame = focusedWindow.frame else {
            fputs("[muesli-native] screen context: focused window is not available for \(appName)\n", stderr)
            return nil
        }

        let pid = app?.processIdentifier ?? 0
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let candidates = windowList.compactMap { windowCandidate(from: $0, ownerPID: pid) }
        guard let windowID = focusedWindowID(
            from: candidates,
            focusedFrame: focusedFrame,
            focusedTitle: focusedWindow.title,
            requiresTitleMatch: !allowTitleFallback
        ) else {
            fputs("[muesli-native] screen context: focused window could not be bound for \(appName)\n", stderr)
            return nil
        }
        if let shouldCapture, !(await shouldCapture()) {
            return nil
        }
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            fputs("[muesli-native] screen context: screenshot capture failed\n", stderr)
            return nil
        }

        do {
            let text = try await ocrImage(image)
            fputs("[muesli-native] screen context: captured \(text.count) \(logLabel) chars from \(appName)\n", stderr)
            return ScreenContext(
                appName: appName,
                bundleID: bundleID,
                documentIdentifier: focusedWindow.documentIdentifier,
                ocrText: text,
                capturedAt: Date()
            )
        } catch {
            fputs("[muesli-native] screen context: \(logLabel) failed: \(error)\n", stderr)
            return nil
        }
    }

    static func focusedWindowID(
        from candidates: [WindowCandidate],
        focusedFrame: CGRect,
        focusedTitle: String,
        requiresTitleMatch: Bool = false
    ) -> CGWindowID? {
        let frameMatches = candidates.filter { framesRepresentSameWindow($0.frame, focusedFrame) }
        guard !frameMatches.isEmpty else { return nil }

        let normalizedFocusedTitle = normalizedWindowTitle(focusedTitle)
        if requiresTitleMatch, normalizedFocusedTitle.isEmpty {
            return nil
        }
        if !normalizedFocusedTitle.isEmpty {
            let titleMatches = frameMatches.filter {
                normalizedWindowTitle($0.title) == normalizedFocusedTitle
            }
            if titleMatches.count == 1 {
                return titleMatches[0].id
            }
            if titleMatches.count > 1 {
                return nil
            }
            if requiresTitleMatch {
                return nil
            }
        }

        // Normal dictation and meeting OCR retain the existing unique-frame
        // fallback. Quill disables it because its OCR may be sent to a hosted
        // model under the focused AX document identity.
        guard frameMatches.count == 1 else { return nil }
        return frameMatches[0].id
    }

    private static func windowCandidate(
        from info: [CFString: Any],
        ownerPID: pid_t
    ) -> WindowCandidate? {
        guard let candidatePID = numericValue(info[kCGWindowOwnerPID]),
              pid_t(candidatePID) == ownerPID,
              let layer = numericValue(info[kCGWindowLayer]),
              Int(layer) == 0,
              let id = numericValue(info[kCGWindowNumber]),
              let bounds = info[kCGWindowBounds] as? [String: Any],
              let x = numericValue(bounds["X"]),
              let y = numericValue(bounds["Y"]),
              let width = numericValue(bounds["Width"]),
              let height = numericValue(bounds["Height"]),
              width > 0,
              height > 0 else { return nil }
        return WindowCandidate(
            id: CGWindowID(id),
            frame: CGRect(x: x, y: y, width: width, height: height),
            title: info[kCGWindowName] as? String ?? ""
        )
    }

    private static func framesRepresentSameWindow(_ candidate: CGRect, _ focused: CGRect) -> Bool {
        let coordinateTolerance: CGFloat = 12
        let sizeTolerance: CGFloat = 18
        return abs(candidate.minX - focused.minX) <= coordinateTolerance
            && abs(candidate.minY - focused.minY) <= coordinateTolerance
            && abs(candidate.width - focused.width) <= sizeTolerance
            && abs(candidate.height - focused.height) <= sizeTolerance
    }

    private static func normalizedWindowTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func numericValue(_ value: Any?) -> CGFloat? {
        switch value {
        case let number as NSNumber:
            return CGFloat(truncating: number)
        case let value as CGFloat:
            return value
        case let value as Double:
            return CGFloat(value)
        case let value as Int:
            return CGFloat(value)
        default:
            return nil
        }
    }

    private static func ocrImage(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Dispatch to background queue to avoid blocking the Swift cooperative thread pool
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.usesCPUOnly = true

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    let text = observations
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Meeting periodic context capture (AX-based, no screenshots)
//
// Uses the Accessibility API instead of CGWindowListCreateImage to avoid
// disrupting the active SCStream system audio capture during meetings.

actor MeetingScreenContextCollector {
    private struct Snapshot {
        let timestamp: Date
        let appName: String
        let contextText: String
        let ocrCharCount: Int
        let appContextCharCount: Int
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var snapshots: [Snapshot] = []
    private var captureTask: Task<Void, Never>?
    private var isPaused = false

    private static func isMeaningfulAppContext(_ text: String, appName: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "App: \(appName)"
    }

    /// Start periodic screen context capture.
    /// - Parameter useOCR: When `true`, uses screenshot + OCR (richer context).
    ///   Safe only when CoreAudio tap is active (no SCStream conflict).
    ///   When `false`, uses Accessibility API only (lightweight, no screenshots).
    func startPeriodicCapture(interval: TimeInterval = 60, useOCR: Bool = false) {
        captureTask?.cancel()
        isPaused = false
        captureTask = Task {
            while !Task.isCancelled {
                if isPaused {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }

                let timestamp = Date()
                let appContext = DictationContextCapture.capture()
                let appContextText = DictationContextCapture.formatForPrompt(appContext)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let meaningfulAppContext = Self.isMeaningfulAppContext(appContextText, appName: appContext.appName)
                    ? appContextText
                    : ""

                let screenContext = useOCR ? await ScreenContextCapture.captureOnce() : nil
                let ocrText = screenContext?.ocrText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let appName = screenContext?.appName ?? appContext.appName

                var sections: [String] = []
                if !meaningfulAppContext.isEmpty {
                    sections.append("App context:\n\(String(meaningfulAppContext.prefix(700)))")
                }
                if !ocrText.isEmpty {
                    sections.append("OCR visual text:\n\(String(ocrText.prefix(1000)))")
                }

                let contextText = sections.joined(separator: "\n\n")
                fputs("[meeting] context capture app=\(appName) axChars=\(meaningfulAppContext.count) ocrChars=\(ocrText.count) appended=\(!contextText.isEmpty)\n", stderr)
                if !contextText.isEmpty {
                    snapshots.append(Snapshot(
                        timestamp: screenContext?.capturedAt ?? timestamp,
                        appName: appName,
                        contextText: contextText,
                        ocrCharCount: ocrText.count,
                        appContextCharCount: meaningfulAppContext.count
                    ))
                }

                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    @discardableResult
    func stopAndDrain() -> String {
        captureTask?.cancel()
        captureTask = nil
        isPaused = false
        guard !snapshots.isEmpty else { return "" }

        var deduped: [Snapshot] = []
        for snapshot in snapshots {
            if let last = deduped.last, last.contextText == snapshot.contextText {
                continue
            }
            deduped.append(snapshot)
        }
        snapshots = []

        let totalOCRChars = deduped.reduce(0) { $0 + $1.ocrCharCount }
        let totalAppContextChars = deduped.reduce(0) { $0 + $1.appContextCharCount }
        fputs("[meeting] context drain snapshots=\(deduped.count) axChars=\(totalAppContextChars) ocrChars=\(totalOCRChars)\n", stderr)

        let result = deduped.map { entry in
            "[\(Self.timeFormatter.string(from: entry.timestamp))] \(entry.appName):\n\(entry.contextText)"
        }.joined(separator: "\n\n")

        return String(result.prefix(5000))
    }
}
