import AppKit
import UniformTypeIdentifiers
import MuesliCore

enum MeetingExportContent {
    case notes
    case transcript
    case fullMeeting
}

struct MeetingExporter {

    static let mdType = UTType(filenameExtension: "md") ?? .plainText
    static let pdfType = UTType.pdf

    static func export(meeting: MeetingRecord, content: MeetingExportContent) {
        DispatchQueue.main.async {
            let markdown = buildMarkdown(meeting: meeting, content: content)
            let filename = suggestedFilename(meeting: meeting, content: content)

            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            panel.allowedContentTypes = [pdfType]
            panel.canCreateDirectories = true

            let formatPicker = ExportFormatAccessory(panel: panel)
            panel.accessoryView = formatPicker.view

            presentSavePanel(panel) { url in
                if formatPicker.selectedFormat == .pdf {
                    writePDF(attributed: buildAttributedString(from: markdown), to: url)
                } else {
                    writeMarkdown(markdown, to: url)
                }
            }
        }
    }

    // MARK: - Markdown composition

    static func buildMarkdown(meeting: MeetingRecord, content: MeetingExportContent) -> String {
        var parts: [String] = []

        parts.append("# \(meeting.title)")
        parts.append("")
        parts.append("**Date:** \(formatExportDate(meeting.startTime))")
        parts.append("**Duration:** \(formatExportDuration(meeting.durationSeconds))")
        parts.append("**Words:** \(meeting.wordCount)")
        if let name = meeting.selectedTemplateName, !name.isEmpty {
            parts.append("**Template:** \(name)")
        }
        parts.append("")
        parts.append("---")
        parts.append("")

        switch content {
        case .notes:
            if meeting.notesState == .structuredNotes {
                parts.append(meeting.formattedNotes)
            } else {
                parts.append("*No structured notes available. Raw transcript included below.*")
                parts.append("")
                parts.append("## Raw Transcript")
                parts.append("")
                parts.append(meeting.rawTranscript)
            }
        case .transcript:
            parts.append("## Raw Transcript")
            parts.append("")
            parts.append(meeting.rawTranscript)
        case .fullMeeting:
            if meeting.notesState == .structuredNotes {
                parts.append(meeting.formattedNotes)
            } else {
                parts.append("*No structured notes available.*")
            }
            parts.append("")
            parts.append("---")
            parts.append("")
            parts.append("## Raw Transcript")
            parts.append("")
            parts.append(meeting.rawTranscript)
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Write files

    private static func writeMarkdown(_ text: String, to url: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            } catch {
                DispatchQueue.main.async { showError("Export Failed", error.localizedDescription) }
            }
        }
    }

    private static func writePDF(attributed: NSAttributedString, to url: URL) {
        let pageWidth: CGFloat = 612   // US Letter
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 72       // 1 inch
        let contentWidth = pageWidth - margin * 2

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: pageHeight - margin * 2))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = .zero
        textView.textStorage?.setAttributedString(attributed)

        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: pageWidth, height: pageHeight)
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary().setValue(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue)

        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel = false
        printOp.showsProgressPanel = false

        if printOp.run() {
            NSWorkspace.shared.open(url)
        } else {
            showError("Export Failed", "Could not generate the PDF document.")
        }
    }

    // MARK: - Save panel

    private static func presentSavePanel(_ panel: NSSavePanel, onSave: @escaping (URL) -> Void) {
        NSApp.activate()
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                onSave(url)
            }
        } else {
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                onSave(url)
            }
        }
    }

    // MARK: - Markdown → NSAttributedString (no WebKit)

    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let h1Font = NSFont.systemFont(ofSize: 22, weight: .bold)
    private static let h2Font = NSFont.systemFont(ofSize: 17, weight: .bold)
    private static let h3Font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let textColor = NSColor.black

    static func buildAttributedString(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                result.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont]))
            } else if trimmed == "---" {
                let rule = NSMutableAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4)])
                let para = NSMutableParagraphStyle()
                para.paragraphSpacingBefore = 6
                para.paragraphSpacing = 6
                rule.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: rule.length))
                result.append(rule)
            } else if trimmed.hasPrefix("### ") {
                let text = String(trimmed.dropFirst(4))
                result.append(styledLine(text + "\n", font: h3Font, spacingBefore: 8))
            } else if trimmed.hasPrefix("## ") {
                let text = String(trimmed.dropFirst(3))
                result.append(styledLine(text + "\n", font: h2Font, spacingBefore: 12))
            } else if trimmed.hasPrefix("# ") {
                let text = String(trimmed.dropFirst(2))
                result.append(styledLine(text + "\n", font: h1Font, spacingBefore: 14))
            } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                let text = String(trimmed.dropFirst(6))
                result.append(lineWithInlineBold("\u{2611} " + text + "\n", baseFont: bodyFont))
            } else if trimmed.hasPrefix("- [ ] ") {
                let text = String(trimmed.dropFirst(6))
                result.append(lineWithInlineBold("\u{2610} " + text + "\n", baseFont: bodyFont))
            } else if trimmed.hasPrefix("- ") {
                let text = String(trimmed.dropFirst(2))
                result.append(lineWithInlineBold("\u{2022} " + text + "\n", baseFont: bodyFont))
            } else {
                result.append(lineWithInlineBold(trimmed + "\n", baseFont: bodyFont))
            }
        }

        return result
    }

    private static func styledLine(_ text: String, font: NSFont, spacingBefore: CGFloat = 0) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacingBefore = spacingBefore
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: para
        ])
    }

    private static func lineWithInlineBold(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: textColor]
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let boldAttrs: [NSAttributedString.Key: Any] = [.font: boldFont, .foregroundColor: textColor]

        var remaining = text[text.startIndex...]
        while let start = remaining.range(of: "**") {
            let before = remaining[remaining.startIndex..<start.lowerBound]
            if !before.isEmpty {
                result.append(NSAttributedString(string: String(before), attributes: baseAttrs))
            }
            remaining = remaining[start.upperBound...]

            if let end = remaining.range(of: "**") {
                let bold = remaining[remaining.startIndex..<end.lowerBound]
                result.append(NSAttributedString(string: String(bold), attributes: boldAttrs))
                remaining = remaining[end.upperBound...]
            } else {
                result.append(NSAttributedString(string: "**", attributes: baseAttrs))
            }
        }

        if !remaining.isEmpty {
            result.append(NSAttributedString(string: String(remaining), attributes: baseAttrs))
        }

        return result
    }

    // MARK: - Markdown → HTML (kept for tests)

    static func markdownToHTML(_ markdown: String) -> String {
        var htmlLines: [String] = []
        let lines = markdown.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                htmlLines.append("<br>")
            } else if trimmed == "---" {
                htmlLines.append("<hr style='border:none;border-top:1px solid #ccc;margin:12px 0;'>")
            } else if trimmed.hasPrefix("### ") {
                htmlLines.append("<h3>\(escapeHTML(String(trimmed.dropFirst(4))))</h3>")
            } else if trimmed.hasPrefix("## ") {
                htmlLines.append("<h2>\(escapeHTML(String(trimmed.dropFirst(3))))</h2>")
            } else if trimmed.hasPrefix("# ") {
                htmlLines.append("<h1>\(escapeHTML(String(trimmed.dropFirst(2))))</h1>")
            } else if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                let text = inlineBoldHTML(escapeHTML(String(trimmed.dropFirst(6))))
                htmlLines.append("<p style='margin:2px 0;'>&#9745; \(text)</p>")
            } else if trimmed.hasPrefix("- [ ] ") {
                let text = inlineBoldHTML(escapeHTML(String(trimmed.dropFirst(6))))
                htmlLines.append("<p style='margin:2px 0;'>&#9744; \(text)</p>")
            } else if trimmed.hasPrefix("- ") {
                let text = inlineBoldHTML(escapeHTML(String(trimmed.dropFirst(2))))
                htmlLines.append("<p style='margin:2px 0;'>&bull; \(text)</p>")
            } else {
                htmlLines.append("<p style='margin:4px 0;'>\(inlineBoldHTML(escapeHTML(trimmed)))</p>")
            }
        }

        return """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8">
        <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif; font-size: 13px; line-height: 1.6; color: #1a1a1a; }
        h1 { font-size: 22px; margin: 16px 0 8px; }
        h2 { font-size: 17px; margin: 14px 0 6px; }
        h3 { font-size: 14px; margin: 10px 0 4px; }
        </style>
        </head>
        <body>
        \(htmlLines.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inlineBoldHTML(_ html: String) -> String {
        var result = html
        while let start = result.range(of: "**"),
              let end = result[start.upperBound...].range(of: "**") {
            let bold = String(result[start.upperBound..<end.lowerBound])
            result = result[..<start.lowerBound] + "<strong>\(bold)</strong>" + result[end.upperBound...]
        }
        return result
    }

    // MARK: - Helpers

    static func suggestedFilename(meeting: MeetingRecord, content: MeetingExportContent) -> String {
        let sanitized = String(
            meeting.title
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
                .lowercased()
                .prefix(50)
        )
        let stem = sanitized.isEmpty ? "meeting" : sanitized
        let suffix: String
        switch content {
        case .notes: suffix = "-notes"
        case .transcript: suffix = "-transcript"
        case .fullMeeting: suffix = ""
        }
        return "\(stem)\(suffix).pdf"
    }

    private static func formatExportDate(_ raw: String) -> String {
        StoredTimestampFormatting.exportDateTime(raw)
    }

    private static func formatExportDuration(_ seconds: Double) -> String {
        let rounded = Int(seconds.rounded())
        if rounded >= 3600 {
            return "\(rounded / 3600)h \((rounded % 3600) / 60)m"
        }
        if rounded >= 60 {
            let m = rounded / 60
            let s = rounded % 60
            return s == 0 ? "\(m) minutes" : "\(m)m \(s)s"
        }
        return "\(rounded)s"
    }

    private static func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Save panel format picker accessory

private class ExportFormatAccessory: NSObject {
    let view: NSView
    private let popup: NSPopUpButton
    private weak var panel: NSSavePanel?

    enum Format { case pdf, markdown }

    var selectedFormat: Format {
        popup.indexOfSelectedItem == 0 ? .pdf : .markdown
    }

    init(panel: NSSavePanel) {
        self.panel = panel

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 32))

        let label = NSTextField(labelWithString: "Format:")
        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: 0, y: 6, width: 55, height: 20)

        let button = NSPopUpButton(frame: NSRect(x: 60, y: 2, width: 190, height: 28), pullsDown: false)
        button.addItems(withTitles: ["PDF", "Markdown"])
        button.selectItem(at: 0)

        container.addSubview(label)
        container.addSubview(button)

        self.popup = button
        self.view = container

        super.init()

        button.target = self
        button.action = #selector(formatChanged)
    }

    @objc private func formatChanged() {
        guard let panel else { return }
        let currentName = panel.nameFieldStringValue
        let stem = (currentName as NSString).deletingPathExtension

        if selectedFormat == .pdf {
            panel.allowedContentTypes = [MeetingExporter.pdfType]
            panel.nameFieldStringValue = "\(stem).pdf"
        } else {
            panel.allowedContentTypes = [MeetingExporter.mdType]
            panel.nameFieldStringValue = "\(stem).md"
        }
    }
}
