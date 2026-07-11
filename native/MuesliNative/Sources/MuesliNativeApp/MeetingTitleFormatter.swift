import AppKit
import ApplicationServices
import Foundation

struct MeetingTitleContext: Equatable {
    let appName: String
    let windowTitle: String

    static let empty = MeetingTitleContext(appName: "", windowTitle: "")

    static func capture() -> MeetingTitleContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return .empty
        }

        let appName = app.localizedName ?? ""
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
        let formatted = replacements.reduce(into: resolvedPattern) { result, replacement in
            result = result.replacingOccurrences(of: replacement.key, with: replacement.value)
        }

        let collapsedWhitespace = formatted.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let trimmed = collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutEmptyTokenSeparators = trimmed.trimmingCharacters(
            in: CharacterSet(charactersIn: " -–—:|/·")
        )
        return withoutEmptyTokenSeparators.isEmpty ? fallbackTitle : withoutEmptyTokenSeparators
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
