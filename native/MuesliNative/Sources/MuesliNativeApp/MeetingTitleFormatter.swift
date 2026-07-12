import AppKit
import ApplicationServices
import Foundation

struct MeetingTitleContext: Equatable, Sendable {
    struct CaptureTarget: Sendable {
        let appName: String
        let processIdentifier: pid_t?
    }

    let appName: String
    let windowTitle: String

    static let empty = MeetingTitleContext(appName: "", windowTitle: "")

    /// Captures without holding up meeting audio when an accessibility query stalls.
    static func captureWithTimeout(
        target: CaptureTarget? = nil,
        delay: TimeInterval = 0,
        timeout: TimeInterval = 0.5,
        captureOperation: @escaping @Sendable (CaptureTarget?) -> MeetingTitleContext = { target in
            MeetingTitleContext.capture(target: target)
        }
    ) async -> MeetingTitleContext {
        let captureDelay = max(delay, 0)
        let captureTimeout = max(timeout, 0)
        guard captureTimeout > 0 else { return .empty }

        return await withCheckedContinuation { continuation in
            let completion = MeetingTitleContextCaptureCompletion(continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + captureDelay) {
                completion.resume(captureOperation(target))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + captureDelay + captureTimeout
            ) {
                completion.resume(.empty)
            }
        }
    }

    static func capture(target: CaptureTarget? = nil) -> MeetingTitleContext {
        let app: NSRunningApplication?
        if let processIdentifier = target?.processIdentifier {
            app = NSRunningApplication(processIdentifier: processIdentifier)
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let app else {
            let targetAppName = target?.appName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !targetAppName.isEmpty {
                return MeetingTitleContext(appName: targetAppName, windowTitle: "")
            }
            return .empty
        }

        let targetAppName = target?.appName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let appName = targetAppName.isEmpty ? (app.localizedName ?? "") : targetAppName
        guard AXIsProcessTrusted() else {
            return MeetingTitleContext(appName: appName, windowTitle: "")
        }

        let accessibilityApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            accessibilityApp,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowRef
        ) == .success,
        let focusedWindow = focusedWindowRef,
        CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() else {
            return MeetingTitleContext(appName: appName, windowTitle: "")
        }

        var titleRef: CFTypeRef?
        let titleResult = AXUIElementCopyAttributeValue(
            focusedWindow as! AXUIElement,
            kAXTitleAttribute as CFString,
            &titleRef
        )
        let windowTitle = titleResult == .success ? (titleRef as? String ?? "") : ""
        return MeetingTitleContext(appName: appName, windowTitle: windowTitle)
    }
}

private final class MeetingTitleContextCaptureCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MeetingTitleContext, Never>?

    init(_ continuation: CheckedContinuation<MeetingTitleContext, Never>) {
        self.continuation = continuation
    }

    func resume(_ context: MeetingTitleContext) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: context)
    }
}

enum MeetingTitleFormatter {
    static let defaultPattern = "{title}"

    static func format(
        pattern: String,
        generatedTitle: String,
        startTime: Date,
        context: MeetingTitleContext
    ) -> String {
        let fallbackTitle = generatedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedPattern.isEmpty else { return fallbackTitle }

        let replacements = [
            "{title}": fallbackTitle,
            "{date}": dateFormatter.string(from: startTime),
            "{time}": timeFormatter.string(from: startTime),
            "{app}": context.appName.trimmingCharacters(in: .whitespacesAndNewlines),
            "{window}": context.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        let formatted = replacements.reduce(resolvedPattern) { result, replacement in
            replacingToken(replacement.key, with: replacement.value, in: result)
        }

        let collapsedWhitespace = formatted.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let trimmed = collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackTitle : trimmed
    }

    private static func replacingToken(_ token: String, with value: String, in pattern: String) -> String {
        guard value.isEmpty else {
            return pattern.replacingOccurrences(of: token, with: value)
        }

        let escapedToken = NSRegularExpression.escapedPattern(for: token)
        let separator = "[-–—:|/·]"
        let removeLeadingSeparator = #"\s*"# + separator + #"\s*"# + escapedToken
        let removeTrailingSeparator = escapedToken + #"\s*"# + separator + #"\s*"#
        let withoutLeadingSeparator = pattern.replacingOccurrences(
            of: removeLeadingSeparator,
            with: "",
            options: .regularExpression
        )
        let withoutTrailingSeparator = withoutLeadingSeparator.replacingOccurrences(
            of: removeTrailingSeparator,
            with: "",
            options: .regularExpression
        )
        return withoutTrailingSeparator.replacingOccurrences(of: token, with: "")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
