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

    /// Waits for the meeting URL's owning process, rather than inferring context
    /// from whichever unrelated app happens to be frontmost during launch.
    static func captureMatchingMeetingContext(
        meetingURL: URL,
        waitTimeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.1,
        targetProvider: @escaping @Sendable (String, String) -> CaptureTarget? = { meetingID, platform in
            matchingFrontmostMeetingTarget(meetingID: meetingID, platform: platform)
        },
        captureOperation: @escaping @Sendable (CaptureTarget?) -> MeetingTitleContext = { target in
            MeetingTitleContext.capture(target: target)
        }
    ) async -> MeetingTitleContext {
        guard let meeting = MeetingURLNormalizer.normalize(meetingURL.absoluteString) else {
            return .empty
        }

        let deadline = Date().addingTimeInterval(max(waitTimeout, 0))
        let pollMilliseconds = max(Int((max(pollInterval, 0.01) * 1_000).rounded(.up)), 1)
        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            switch await matchingTargetWithTimeout(
                meetingID: meeting.id,
                platform: meeting.platform.rawValue,
                timeout: min(remaining, 0.25),
                targetProvider: targetProvider
            ) {
            case .target(let target?):
                return await captureWithTimeout(target: target, captureOperation: captureOperation)
            case .timedOut:
                return .empty
            case .target(nil):
                break
            }
            let sleepMilliseconds = min(
                pollMilliseconds,
                max(Int((deadline.timeIntervalSinceNow * 1_000).rounded(.down)), 0)
            )
            guard sleepMilliseconds > 0 else { break }
            try? await Task.sleep(for: .milliseconds(sleepMilliseconds))
        }

        return .empty
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

    private static func matchingFrontmostMeetingTarget(
        meetingID: String,
        platform: String
    ) -> CaptureTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return nil
        }

        let appName = app.localizedName
            ?? MeetingCandidateResolver.browserApps[bundleID]
            ?? MeetingCandidateResolver.dedicatedApps[bundleID]?.name
            ?? bundleID
        if MeetingCandidateResolver.dedicatedApps[bundleID]?.platform.rawValue == platform {
            return CaptureTarget(appName: appName, processIdentifier: app.processIdentifier)
        }
        guard MeetingCandidateResolver.browserApps[bundleID] != nil,
              browserFocusedDocumentMatches(
                processIdentifier: app.processIdentifier,
                meetingID: meetingID
              ) else {
            return nil
        }
        return CaptureTarget(appName: appName, processIdentifier: app.processIdentifier)
    }

    private static func matchingTargetWithTimeout(
        meetingID: String,
        platform: String,
        timeout: TimeInterval,
        targetProvider: @escaping @Sendable (String, String) -> CaptureTarget?
    ) async -> MeetingTitleContextTargetLookupResult {
        guard timeout > 0 else { return .timedOut }
        return await withCheckedContinuation { continuation in
            let completion = MeetingTitleContextTargetCompletion(continuation)
            DispatchQueue.global(qos: .utility).async {
                completion.resume(.target(targetProvider(meetingID, platform)))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                completion.resume(.timedOut)
            }
        }
    }

    private static func browserFocusedDocumentMatches(
        processIdentifier: pid_t,
        meetingID: String
    ) -> Bool {
        let app = AXUIElementCreateApplication(processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        ) == .success,
        let window = windowRef,
        CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return false
        }

        var documentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window as! AXUIElement,
            kAXDocumentAttribute as CFString,
            &documentRef
        ) == .success,
        let documentURL = documentRef as? String else {
            return false
        }
        return MeetingURLNormalizer.normalize(documentURL)?.id == meetingID
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

private enum MeetingTitleContextTargetLookupResult: Sendable {
    case target(MeetingTitleContext.CaptureTarget?)
    case timedOut
}

private final class MeetingTitleContextTargetCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MeetingTitleContextTargetLookupResult, Never>?

    init(_ continuation: CheckedContinuation<MeetingTitleContextTargetLookupResult, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: MeetingTitleContextTargetLookupResult) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: result)
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
