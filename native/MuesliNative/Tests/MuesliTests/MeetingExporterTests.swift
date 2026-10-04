import AppKit
import PDFKit
import Testing
@testable import MuesliNativeApp
import MuesliCore

@Suite("Meeting export")
struct MeetingExporterTests {

    private func makeMeeting(
        title: String = "Weekly Standup",
        startTime: String = "2026-04-14T10:00:00",
        durationSeconds: Double = 1800,
        rawTranscript: String = "[00:00:05] You: Hello everyone\n[00:00:10] Speaker 1: Hi there",
        formattedNotes: String = "## Key Points\n\n- Discussed roadmap\n- **Action item:** Ship export feature",
        wordCount: Int = 42,
        templateName: String? = "Default",
        templateKind: MeetingTemplateKind? = .builtin,
        status: MeetingStatus = .completed,
        manualNotes: String = ""
    ) -> MeetingRecord {
        MeetingRecord(
            id: 1,
            title: title,
            startTime: startTime,
            durationSeconds: durationSeconds,
            rawTranscript: rawTranscript,
            formattedNotes: formattedNotes,
            wordCount: wordCount,
            folderID: nil,
            status: status,
            manualNotes: manualNotes,
            selectedTemplateName: templateName,
            selectedTemplateKind: templateKind
        )
    }

    // MARK: - Markdown composition

    @Test("metadataHeader includes title, date, duration, words, template")
    func metadataHeaderIncludesFields() {
        let meeting = makeMeeting()
        let header = MeetingExporter.metadataHeader(for: meeting)

        #expect(header.contains("# Weekly Standup"))
        #expect(header.contains("**Date:** \(MeetingExporter.formatExportDate(meeting.startTime))"))
        #expect(header.contains("**Duration:** 30 minutes"))
        #expect(header.contains("**Words:** 42"))
        #expect(header.contains("**Template:** Default"))
    }

    @Test("metadataHeader uses override wordCount when provided")
    func metadataHeaderWithCustomWordCount() {
        let meeting = makeMeeting(wordCount: 42)
        let header = MeetingExporter.metadataHeader(for: meeting, wordCount: 100)

        #expect(header.contains("**Words:** 100"))
        #expect(!header.contains("**Words:** 42"))
    }

    @Test("Notes export includes metadata header and formatted notes")
    func notesMarkdownIncludesMetadata() {
        let meeting = makeMeeting()
        let md = MeetingExporter.buildMarkdown(meeting: meeting, content: .notes)

        #expect(md.contains("# Weekly Standup"))
        #expect(md.contains("**Date:** \(MeetingExporter.formatExportDate(meeting.startTime))"))
        #expect(md.contains("**Duration:** 30 minutes"))
        #expect(md.contains("**Words:** 42"))
        #expect(md.contains("**Template:** Default"))
        #expect(md.contains("---"))
        #expect(md.contains("## Key Points"))
        #expect(md.contains("**Action item:** Ship export feature"))
    }

    @Test("Transcript export includes raw transcript text")
    func transcriptMarkdownIncludesRawText() {
        let meeting = makeMeeting()
        let md = MeetingExporter.buildMarkdown(meeting: meeting, content: .transcript)

        #expect(md.contains("# Weekly Standup"))
        #expect(md.contains("## Raw Transcript"))
        #expect(md.contains("[00:00:05] You: Hello everyone"))
        #expect(md.contains("[00:00:10] Speaker 1: Hi there"))
    }

    @Test("Full meeting export includes both notes and transcript")
    func fullMeetingIncludesBoth() {
        let meeting = makeMeeting()
        let md = MeetingExporter.buildMarkdown(meeting: meeting, content: .fullMeeting)

        #expect(md.contains("## Key Points"))
        #expect(md.contains("**Action item:** Ship export feature"))
        #expect(md.contains("## Raw Transcript"))
        #expect(md.contains("[00:00:05] You: Hello everyone"))
    }

    @Test("Full meeting shows fallback when no structured notes")
    func fullMeetingFallbackNoNotes() {
        let meeting = makeMeeting(formattedNotes: "## Raw Transcript\nsome text")
        let md = MeetingExporter.buildMarkdown(meeting: meeting, content: .fullMeeting)

        #expect(md.contains("*No structured notes available.*"))
        #expect(md.contains("## Raw Transcript"))
        #expect(md.contains("[00:00:05] You: Hello everyone"))
    }

    @Test("Notes export falls back to transcript when no structured notes")
    func notesFallbackToTranscript() {
        let meeting = makeMeeting(formattedNotes: "## Raw Transcript\nsome text")
        let md = MeetingExporter.buildMarkdown(meeting: meeting, content: .notes)

        #expect(md.contains("*No structured notes available."))
        #expect(md.contains("## Raw Transcript"))
        #expect(md.contains("[00:00:05] You: Hello everyone"))
    }

    @Test("Omits template line when no template name")
    func noTemplateLineWhenMissing() {
        let meeting = makeMeeting(templateName: nil)
        let md = MeetingExporter.buildMarkdown(meeting: meeting, content: .notes)

        #expect(!md.contains("**Template:**"))
    }

    @Test("Duration formats hours correctly")
    func hourDurationFormat() {
        let meeting = makeMeeting(durationSeconds: 5400)
        let md = MeetingExporter.buildMarkdown(meeting: meeting, content: .notes)

        #expect(md.contains("**Duration:** 1h 30m"))
    }

    @Test("Copy structured notes uses persisted or edited content with metadata")
    func copyStructuredNotes() {
        let meeting = makeMeeting(wordCount: 900)
        for edited in [nil, "## Updated\nOne\ntwo\tthree"] as [String?] {
            let copied = MeetingDetailView.copyContent(for: meeting, content: .notes, editedText: edited)
            let body = edited ?? meeting.formattedNotes
            #expect(copied.hasSuffix(body))
            #expect(copied.contains("**Date:**"))
            #expect(copied.contains("**Duration:** 30 minutes"))
            #expect(copied.contains("**Words:** \(body.split(whereSeparator: { $0.isWhitespace }).count)\n"))
            #expect(copied.components(separatedBy: "# Weekly Standup").count - 1 == 1)
        }
    }

    @Test("Copy raw notes removes only the editor's exact leading title")
    func copyRawTranscriptNotes() {
        let meeting = makeMeeting(formattedNotes: "## Raw Transcript\nsome text")
        let persisted = MeetingDetailView.copyContent(for: meeting, content: .notes)
        #expect(persisted.contains("## Raw Transcript"))
        #expect(persisted.hasSuffix(meeting.rawTranscript))
        for newline in ["\n", "\r\n"] {
            let edited = "# Weekly Standup" + newline + newline + "## Raw Transcript" + newline + "one two"
            let copied = MeetingDetailView.copyContent(for: meeting, content: .notes, editedText: edited)
            #expect(copied.components(separatedBy: "# Weekly Standup").count - 1 == 1)
            #expect(copied.hasSuffix("one two"))
            #expect(copied.contains("**Words:** 5\n"))
        }
        let differentTitle = "# Weekly Standup Extra\nUser content"
        let copied = MeetingDetailView.copyContent(for: meeting, content: .notes, editedText: differentTitle)
        #expect(copied.hasSuffix(differentTitle))
    }

    @Test("Copy transcript counts all whitespace and honors empty unsaved edits")
    func copyTranscript() {
        let meeting = makeMeeting(rawTranscript: "one\ntwo\tthree\r\nfour\u{00a0}five", wordCount: 900)
        let persisted = MeetingDetailView.copyContent(for: meeting, content: .transcript)
        #expect(persisted.contains("**Words:** 5\n"))
        #expect(persisted.hasSuffix(meeting.rawTranscript))
        let edited = MeetingDetailView.copyContent(for: meeting, content: .transcript, editedText: "new\ntext")
        #expect(edited.contains("**Words:** 2\n"))
        #expect(edited.hasSuffix("new\ntext"))
        let empty = MeetingDetailView.copyContent(for: meeting, content: .transcript, editedText: "")
        #expect(empty.contains("**Words:** 0\n"))
        #expect(!empty.contains(meeting.rawTranscript))
    }

    @Test("Copy manual notes preserves intentional title headings")
    func copyManualNotes() {
        let meeting = makeMeeting(formattedNotes: "", status: .noteOnly,
                                  manualNotes: "# Weekly Standup\nMy manual notes")
        let copied = MeetingDetailView.copyContent(for: meeting, content: .notes, editedText: meeting.manualNotes)
        #expect(copied.hasSuffix(meeting.manualNotes))
    }

    @Test("All Markdown export modes embed the official logo without external image URLs")
    func markdownBranding() throws {
        let officialAsset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("assets/muesli_app_icon.png")
        #expect(MeetingExportBranding.logoData == (try Data(contentsOf: officialAsset)))
        for content in MeetingExportContent.allCases {
            let markdown = MeetingExporter.buildMarkdown(meeting: makeMeeting(), content: content)
            #expect(markdown.hasSuffix(MeetingExportBranding.markdownFooter))
            #expect(markdown.components(separatedBy: "alt=\"Muesli logo\"").count - 1 == 1)
            #expect(markdown.contains("[Exported with Muesli](https://muesli.works)"))
            #expect(markdown.contains("data:image/png;base64,"))
            #expect(!markdown.contains("<img src=\"http"))
        }
        let copied = MeetingDetailView.copyContent(for: makeMeeting(), content: .notes)
        #expect(!copied.contains("data:image"))
        #expect(!copied.contains("Exported with Muesli"))
    }

    @Test("Copy and export use meeting date and minute precision; footer links to Muesli")
    func meetingDateAndFooterLink() throws {
        let meeting = makeMeeting(startTime: "2026-10-04T10:00:45Z")
        let dateText = MeetingExporter.formatExportDate(meeting.startTime,
            locale: Locale(identifier: "en_US_POSIX"), timeZone: try #require(TimeZone(secondsFromGMT: 0)))
        #expect(dateText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") == "Oct 4, 2026 at 10:00 AM")
        let headerDate = "**Date:** " + MeetingExporter.formatExportDate(meeting.startTime)
        for content in [MeetingDocumentMode.notes, .transcript] {
            let copied = MeetingDetailView.copyContent(for: meeting, content: content)
            #expect(copied.contains(headerDate))
            #expect(!copied.contains(":45"))
        }
        for content in MeetingExportContent.allCases {
            let markdown = MeetingExporter.buildMarkdown(meeting: meeting, content: content)
            #expect(markdown.contains(headerDate))
            #expect(!markdown.contains(":45"))
            #expect(markdown.hasSuffix("[Exported with Muesli](https://muesli.works)"))
            let html = MeetingExporter.markdownToHTML(markdown)
            #expect(html.contains("href=\"https://muesli.works\">Exported with Muesli</a>"))
            #expect(!MeetingExportBranding.removingFooter(from: markdown).contains("Exported with Muesli"))
        }
        #expect(MeetingExporter.formatExportDate("unrecognized date") == MeetingBrowserLogic.formatStartTime("unrecognized date"))
    }

    @MainActor
    @Test("PDF branding stays out of body text and appears on every page")
    func pdfBrandingEveryPage() throws {
        let lines = (1...180).map { "Line \($0): The team reviewed export branding and confirmed the next milestone." }
        let meeting = makeMeeting(formattedNotes: "## Review\n" + lines.joined(separator: "\n"))
        let markdown = MeetingExporter.buildMarkdown(meeting: meeting, content: .notes)
        let attributed = MeetingExporter.buildAttributedString(from: markdown)
        #expect(!attributed.string.contains("base64"))
        #expect(!attributed.string.contains("Exported with Muesli"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-pr528-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("meeting-export.pdf")
        try MeetingExporter.writePDF(attributed: attributed, to: url)
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount > 1)
        for index in 0..<document.pageCount {
            let page = try #require(document.page(at: index))
            #expect(page.string?.contains("Exported with Muesli") == true)
            #expect(page.annotations.contains { $0.url == MeetingExportBranding.websiteURL })
            // Rasterize only the footer's logo region, excluding the text, and
            // check for the official blue artwork on every page.
            let pdfPage = try #require(page.pageRef)
            let space = CGColorSpaceCreateDeviceRGB()
            let bitmap = try #require(CGContext(data: nil, width: 18, height: 18, bitsPerComponent: 8,
                bytesPerRow: 18 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.translateBy(x: -72, y: -27)
            bitmap.drawPDFPage(pdfPage)
            let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
            let bluePixels = (0..<(18 * 18)).filter { pixel in
                let offset = pixel * 4
                return Int(pixels[offset + 2]) > Int(pixels[offset]) + 25 && pixels[offset + 3] > 50
            }
            #expect(!bluePixels.isEmpty)
        }
        #expect(document.string?.contains("Line 180:") == true)
        try markdown.write(to: directory.appendingPathComponent("meeting-export.md"), atomically: true, encoding: .utf8)
        try MeetingExporter.markdownToHTML(markdown).write(to: directory.appendingPathComponent("meeting-export.html"), atomically: true, encoding: .utf8)
    }

    // MARK: - HTML rendering

    @Test("Converts headings to HTML tags")
    func htmlHeadings() {
        let html = MeetingExporter.markdownToHTML("# Title\n## Section\n### Subsection")

        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<h2>Section</h2>"))
        #expect(html.contains("<h3>Subsection</h3>"))
    }

    @Test("Converts bullet points")
    func htmlBullets() {
        let html = MeetingExporter.markdownToHTML("- First item\n- Second item")

        #expect(html.contains("&bull; First item"))
        #expect(html.contains("&bull; Second item"))
    }

    @Test("Converts checkboxes")
    func htmlCheckboxes() {
        let html = MeetingExporter.markdownToHTML("- [ ] Unchecked\n- [x] Checked")

        #expect(html.contains("&#9744; Unchecked"))
        #expect(html.contains("&#9745; Checked"))
    }

    @Test("Converts bold text")
    func htmlBold() {
        let html = MeetingExporter.markdownToHTML("This is **bold** text")

        #expect(html.contains("<strong>bold</strong>"))
    }

    @Test("Escapes HTML entities in content")
    func htmlEscaping() {
        let html = MeetingExporter.markdownToHTML("Use <script> & \"quotes\"")

        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("&amp;"))
    }

    @Test("Horizontal rule renders")
    func htmlHorizontalRule() {
        let html = MeetingExporter.markdownToHTML("---")

        #expect(html.contains("<hr"))
    }

    // MARK: - Attributed string (PDF path)

    @Test("Attributed string renders headings with correct fonts")
    func attributedStringHeadings() {
        let attr = MeetingExporter.buildAttributedString(from: "# Big\n## Medium\n### Small")
        let full = attr.string

        #expect(full.contains("Big"))
        #expect(full.contains("Medium"))
        #expect(full.contains("Small"))
    }

    @Test("Attributed string renders bold inline")
    func attributedStringBold() {
        let attr = MeetingExporter.buildAttributedString(from: "This is **bold** text")
        let full = attr.string

        #expect(full.contains("bold"))
        #expect(!full.contains("**"))
    }

    @Test("Attributed string renders bullets")
    func attributedStringBullets() {
        let attr = MeetingExporter.buildAttributedString(from: "- Item one\n- Item two")
        let full = attr.string

        #expect(full.contains("\u{2022} Item one"))
        #expect(full.contains("\u{2022} Item two"))
    }

    @Test("Attributed string handles empty input")
    func attributedStringEmpty() {
        let attr = MeetingExporter.buildAttributedString(from: "")

        #expect(attr.length > 0) // at least the trailing newline
    }

    @Test("Unmatched bold marker emits literal **")
    func attributedStringUnmatchedBold() {
        let attr = MeetingExporter.buildAttributedString(from: "Start ** no close")
        let full = attr.string

        #expect(full.contains("**"))
        #expect(full.contains("no close"))
    }

    // MARK: - Filename generation

    @Test("Notes filename has -notes suffix")
    func filenameNotes() {
        let meeting = makeMeeting(title: "Q2 Planning")
        let name = MeetingExporter.suggestedFilename(meeting: meeting, content: .notes)

        #expect(name == "q2-planning-notes.pdf")
    }

    @Test("Transcript filename has -transcript suffix")
    func filenameTranscript() {
        let meeting = makeMeeting(title: "Daily Standup")
        let name = MeetingExporter.suggestedFilename(meeting: meeting, content: .transcript)

        #expect(name == "daily-standup-transcript.pdf")
    }

    @Test("Full meeting filename has no suffix")
    func filenameFullMeeting() {
        let meeting = makeMeeting(title: "Daily Standup")
        let name = MeetingExporter.suggestedFilename(meeting: meeting, content: .fullMeeting)

        #expect(name == "daily-standup.pdf")
    }

    @Test("Falls back to 'meeting' when title has no alphanumeric chars")
    func filenameEmptyStem() {
        let meeting = makeMeeting(title: "!!!")
        let name = MeetingExporter.suggestedFilename(meeting: meeting, content: .notes)

        #expect(name == "meeting-notes.pdf")
    }

    @Test("Truncates long titles in filename")
    func filenameTruncation() {
        let longTitle = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let meeting = makeMeeting(title: longTitle)
        let name = MeetingExporter.suggestedFilename(meeting: meeting, content: .fullMeeting)

        let stem = name.replacingOccurrences(of: ".pdf", with: "")
        #expect(stem.count <= 50)
    }
}
