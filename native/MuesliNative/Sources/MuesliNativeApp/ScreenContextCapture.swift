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
    let ocrText: String
}

enum DictationContextCapture {

    /// Captures focused app name + text context via Accessibility API, with optional
    /// on-device OCR when Screen Recording permission is already granted.
    static func capture(
        includeScreenOCR: Bool,
        shouldCaptureScreenOCR: (@Sendable () async -> Bool)? = nil
    ) async -> DictationContext {
        let base = capture()
        guard includeScreenOCR, CGPreflightScreenCaptureAccess() else { return base }
        let screenContext = await ScreenContextCapture.captureVisibleScreen(shouldCapture: shouldCaptureScreenOCR)
        let ocrText = screenContext?.ocrText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !ocrText.isEmpty else { return base }
        return DictationContext(
            appName: base.appName,
            bundleID: base.bundleID,
            documentContext: base.documentContext,
            selectedText: base.selectedText,
            url: base.url,
            ocrText: ocrText
        )
    }

    /// Captures focused app name + text context via Accessibility API.
    /// Lightweight and deterministic — no screenshots, no OCR.
    static func capture() -> DictationContext {
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown"
        let bundleID = app?.bundleIdentifier ?? ""
        let focusedText = FocusedTextContextService().captureRaw(maxPrefixCharacters: 200)
        let docContext = focusedText?.prefix ?? ""
        let selectedText = focusedText?.selectedText ?? ""
        let url = focusedText?.browserLocation

        fputs("[muesli-native] dictation context: app=\(appName) docContext=\(docContext.count) chars selectedText=\(selectedText.count) chars url=\(url ?? "none")\n", stderr)

        return DictationContext(
            appName: appName,
            bundleID: bundleID,
            documentContext: docContext,
            selectedText: selectedText,
            url: url,
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

}

// MARK: - Meeting context (Screenshot + OCR — richer, for cloud LLMs)

struct ScreenContext {
    let appName: String
    let bundleID: String
    let ocrText: String
    let capturedAt: Date
}

enum ScreenContextCapture {

    /// Captures the frontmost app window and runs on-device OCR. The screenshot itself
    /// is not persisted or sent to cleanup backends; only recognized text is used.
    static func captureVisibleScreen(shouldCapture: (@Sendable () async -> Bool)? = nil) async -> ScreenContext? {
        await captureFrontmostWindow(logLabel: "dictation OCR", shouldCapture: shouldCapture)
    }

    /// Captures a screenshot of the focused window and runs on-device OCR.
    /// Used for meeting context only — heavier than AX but provides visual content.
    static func captureOnce() async -> ScreenContext? {
        await captureFrontmostWindow(logLabel: "meeting OCR")
    }

    private static func captureFrontmostWindow(
        logLabel: String,
        shouldCapture: (@Sendable () async -> Bool)? = nil
    ) async -> ScreenContext? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let app = NSWorkspace.shared.frontmostApplication
        let appName = app?.localizedName ?? "Unknown"
        let bundleID = app?.bundleIdentifier ?? ""

        let pid = app?.processIdentifier ?? 0
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]] ?? []
        let appWindow = windowList.first(where: { dict in
            guard let ownerPID = dict[kCGWindowOwnerPID] as? Int32, ownerPID == pid else { return false }
            guard let layer = dict[kCGWindowLayer] as? Int, layer == 0 else { return false }
            return true
        })
        guard let windowID = appWindow?[kCGWindowNumber] as? CGWindowID else {
            fputs("[muesli-native] screen context: no window found for \(appName)\n", stderr)
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
                ocrText: text,
                capturedAt: Date()
            )
        } catch {
            fputs("[muesli-native] screen context: \(logLabel) failed: \(error)\n", stderr)
            return nil
        }
    }

    private static func ocrImage(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // Dispatch to background queue to avoid blocking the Swift cooperative thread pool
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let text = observations
                        .compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: "\n")
                    continuation.resume(returning: text)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.usesCPUOnly = true

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
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
