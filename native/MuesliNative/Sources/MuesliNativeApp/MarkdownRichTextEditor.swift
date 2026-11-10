import AppKit
import SwiftUI
import ImageIO

private enum NoteImageSource {
    case data(Data)
    case file(URL)
}

private extension NSAttributedString.Key {
    static let muesliMarkdownStrong = NSAttributedString.Key("com.muesli.markdown.strong")
    static let muesliMarkdownEmphasis = NSAttributedString.Key("com.muesli.markdown.emphasis")
    static let muesliMarkdownCode = NSAttributedString.Key("com.muesli.markdown.code")
    static let muesliMarkdownImage = NSAttributedString.Key("com.muesli.markdown.image")
}

struct MarkdownEditorCommand: Equatable {
    enum Kind: Equatable {
        case heading
        case bold
        case bullet
        case checkbox
    }

    let id = UUID()
    let kind: Kind
}

struct MarkdownRichTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var command: MarkdownEditorCommand?
    var shouldFocus: Bool = false
    var isEditable: Bool = true
    var placeholder: String = "Write notes here..."
    var renderMarkdownFormatting: Bool = true
    var onTextChange: ((String) -> Void)?
    var onSelectionChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, command: $command, onTextChange: onTextChange,
                    renderMarkdownFormatting: renderMarkdownFormatting)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = PlaceholderTextView()
        textView.placeholder = placeholder
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.textContainerInset = NSSize(width: 34, height: 30)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = context.coordinator.bodyAttributes()
        textView.imageHandler = { [weak coordinator = context.coordinator, weak textView] source in
            guard let coordinator, let textView else { return }
            coordinator.insertImage(source, into: textView)
        }
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, .rtfd, .rtf, .string])
        context.coordinator.apply(markdown: text, to: textView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaceholderTextView else { return }
        textView.placeholder = placeholder
        textView.isEditable = isEditable
        textView.isSelectable = true
        context.coordinator.onTextChange = onTextChange
        context.coordinator.onSelectionChange = onSelectionChange
        if context.coordinator.shouldApplyExternalMarkdown(text) {
            context.coordinator.apply(markdown: text, to: textView)
        }
        if let command {
            context.coordinator.schedule(command, in: textView)
        }
        if shouldFocus, !context.coordinator.didFocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
                context.coordinator.didFocus = true
            }
        }
        textView.needsDisplay = true
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        @Binding private var command: MarkdownEditorCommand?
        var onTextChange: ((String) -> Void)?
        var onSelectionChange: ((Bool) -> Void)?
        private var lastReportedSelection: Bool?
        private var hadImageSelection = false

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            clearImageTypingAttributes(in: textView)
            let range = textView.selectedRange()
            let storage = textView.textStorage
            let hasImageSelection = range.length == 1 && range.location != NSNotFound
                && range.upperBound <= (storage?.length ?? 0)
                && storage?.attribute(.muesliMarkdownImage, at: range.location, effectiveRange: nil) is String
            if hasImageSelection || hadImageSelection {
                textView.needsDisplay = true
            }
            hadImageSelection = hasImageSelection
            // AppKit can change selection during SwiftUI updates; publish after that pass.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                let hasSelection = textView.selectedRange().length > 0
                guard hasSelection != self.lastReportedSelection else { return }
                self.lastReportedSelection = hasSelection
                self.onSelectionChange?(hasSelection)
            }
        }

        weak var textView: NSTextView?
        var didFocus = false
        private(set) var currentMarkdown = ""
        private var isApplying = false
        private var isHandlingNewline = false
        private var usesMarkdownStyling = false
        private var lastBindingMarkdown = ""
        private var pendingLocalMarkdown: String?
        private var bindingPublishWorkItem: DispatchWorkItem?
        private var scheduledCommandID: UUID?
        private var imageCache: [UUID: NSImage] = [:]
        private var imageAttachments: [UUID: NSTextAttachment] = [:]
        private var loadingImages: Set<UUID> = []
        private var missingImages: Set<UUID> = []
        private var pendingImageCount = 0
        private let renderMarkdownFormatting: Bool

        private let bodyFont = AppFonts.font(size: 16)
        private let boldFont = AppFonts.bold(16)
        private let headingFont = AppFonts.font(size: 26, weight: .bold)
        private let bodyColor = NSColor.labelColor
        private let secondaryColor = NSColor.secondaryLabelColor

        init(text: Binding<String>, command: Binding<MarkdownEditorCommand?>, onTextChange: ((String) -> Void)?,
             renderMarkdownFormatting: Bool = true) {
            _text = text
            _command = command
            self.onTextChange = onTextChange
            self.renderMarkdownFormatting = renderMarkdownFormatting
        }

        fileprivate func insertImage(_ source: NoteImageSource, into view: NSTextView) {
            guard MeetingNoteImages.references(in: serializedMarkdown(from: view)).count + pendingImageCount < MeetingNoteImages.maximumImageCount else {
                let alert = NSAlert()
                alert.messageText = "Could not add image"
                alert.informativeText = MeetingNoteImageError.tooMany.localizedDescription
                if let window = view.window { alert.beginSheetModal(for: window) }
                return
            }
            pendingImageCount += 1
            let selection = view.selectedRange()
            let original = view.string
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak view] in
                let result: Result<MeetingNoteImages.Reference, Error> = Result {
                    let data: Data
                    switch source {
                    case .data(let value): data = value
                    case .file(let url):
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard values.isRegularFile == true, let size = values.fileSize,
                              size > 0, size <= MeetingNoteImages.maximumImageBytes else { throw ChatFileError.tooLarge }
                        data = try Data(contentsOf: url, options: .mappedIfSafe)
                    }
                    return try MeetingNoteImages.save(data)
                }
                DispatchQueue.main.async {
                    self?.pendingImageCount -= 1
                    guard let self, let view, view.window != nil, view.isEditable else {
                        if case .success(let reference) = result {
                            DispatchQueue.global(qos: .utility).async {
                                try? FileManager.default.removeItem(at: MeetingNoteImages.url(for: reference.id))
                            }
                        }
                        return
                    }
                    switch result {
                    case .success(let reference):
                        // If the user typed while the image was processed, keep their
                        // edits and insert at the current caret instead of replacing them.
                        let target = view.string == original ? selection : view.selectedRange()
                        self.insertImageReference(reference, into: view, replacing: target)
                    case .failure(let error):
                        let alert = NSAlert()
                        alert.messageText = "Could not add image"
                        alert.informativeText = error.localizedDescription
                        alert.beginSheetModal(for: view.window!)
                    }
                    _ = self
                }
            }
        }

        func insertImageReference(_ reference: MeetingNoteImages.Reference, into view: NSTextView, replacing range: NSRange) {
            guard let storage = view.textStorage, range.location != NSNotFound,
                  range.upperBound <= storage.length else { return }
            let attachment = inlineAttributedString(from: reference.markdown, attributes: bodyAttributes())
            usesMarkdownStyling = true
            view.breakUndoCoalescing()
            view.undoManager?.beginUndoGrouping()
            _ = NoteImageMove.replace(in: view, range: range, with: attachment,
                                      selection: NSRange(location: range.location + attachment.length, length: 0),
                                      undoSelection: range)
            view.undoManager?.setActionName("Paste Image")
            view.undoManager?.endUndoGrouping()
            view.breakUndoCoalescing()
        }

        private func loadImage(_ id: UUID) {
            guard !loadingImages.contains(id), !missingImages.contains(id) else { return }
            loadingImages.insert(id)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let url = MeetingNoteImages.url(for: id)
                let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                let image = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0,
                    [kCGImageSourceCreateThumbnailFromImageAlways: true,
                     kCGImageSourceThumbnailMaxPixelSize: 1000,
                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loadingImages.remove(id)
                    guard let image else { self.missingImages.insert(id); return }
                    let loaded = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    self.imageCache[id] = loaded
                    guard let view = self.textView, let storage = view.textStorage else { return }
                    var ranges: [NSRange] = []
                    storage.enumerateAttribute(.muesliMarkdownImage, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                        if let marker = value as? String, MeetingNoteImages.references(in: marker).first?.id == id { ranges.append(range) }
                    }
                    self.isApplying = true
                    let attachment = self.imageAttachments[id] ?? NSTextAttachment()
                    attachment.image = loaded
                    let marker = ranges.first.flatMap { storage.attribute(.muesliMarkdownImage, at: $0.location, effectiveRange: nil) as? String }
                    let desiredWidth = marker.flatMap { MeetingNoteImages.references(in: $0).first?.width }.map(CGFloat.init) ?? 500
                    let scale = min(1, desiredWidth / max(loaded.size.width, 1))
                    attachment.bounds = NSRect(x: 0, y: 0, width: loaded.size.width * scale, height: loaded.size.height * scale)
                    self.imageAttachments[id] = attachment
                    for range in ranges {
                        storage.addAttribute(.attachment, value: attachment, range: range)
                    }
                    self.isApplying = false
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplying, let textView = notification.object as? NSTextView else { return }
            applyInlineFormattingIfNeeded(in: textView)
            let markdown = markdownForLiveEdit(from: textView)
            if imageAttachments.count > 6 {
                let liveIDs = Set(MeetingNoteImages.references(in: markdown).map(\.id))
                imageAttachments = imageAttachments.filter { liveIDs.contains($0.key) }
                imageCache = imageCache.filter { liveIDs.contains($0.key) }
                missingImages.formIntersection(liveIDs)
            }
            currentMarkdown = markdown
            pendingLocalMarkdown = markdown
            onTextChange?(markdown)
            scheduleBindingPublish(markdown)
            textView.needsDisplay = true
        }

        func shouldApplyExternalMarkdown(_ markdown: String) -> Bool {
            if markdown == currentMarkdown {
                lastBindingMarkdown = markdown
                if pendingLocalMarkdown == markdown {
                    pendingLocalMarkdown = nil
                }
                return false
            }
            if pendingLocalMarkdown != nil, markdown == lastBindingMarkdown {
                return false
            }
            return true
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if let replacementString, !replacementString.contains("\u{fffc}") {
                clearImageTypingAttributes(in: textView)
            }
            guard !isHandlingNewline else { return true }
            guard replacementString == "\n" else { return true }
            continueListIfNeeded(in: textView, affectedCharRange: affectedCharRange)
            return false
        }

        private func clearImageTypingAttributes(in textView: NSTextView) {
            var attributes = textView.typingAttributes
            guard attributes[.attachment] != nil || attributes[.muesliMarkdownImage] != nil else { return }
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .muesliMarkdownImage)
            textView.typingAttributes = attributes
        }

        func apply(markdown: String, to textView: NSTextView) {
            let selectedRanges = textView.selectedRanges
            isApplying = true
            usesMarkdownStyling = Self.markdownNeedsRichRendering(markdown)
            textView.textStorage?.setAttributedString(attributedString(from: markdown))
            textView.typingAttributes = bodyAttributes()
            textView.selectedRanges = selectedRanges.clamped(to: (textView.string as NSString).length)
            currentMarkdown = markdown
            lastBindingMarkdown = markdown
            pendingLocalMarkdown = nil
            isApplying = false
            textView.needsDisplay = true
        }

        /// AppKit editor mutations publish SwiftUI bindings, so they cannot run
        /// synchronously from `updateNSView`. Queue each toolbar command once
        /// and restore the selection captured when SwiftUI delivered it.
        func schedule(_ command: MarkdownEditorCommand, in textView: NSTextView) {
            guard scheduledCommandID != command.id else { return }
            scheduledCommandID = command.id
            let selectedRanges = textView.selectedRanges

            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                textView.selectedRanges = selectedRanges.clamped(to: (textView.string as NSString).length)
                self.perform(command.kind, in: textView)
                if self.command?.id == command.id {
                    self.command = nil
                }
            }
        }

        func perform(_ command: MarkdownEditorCommand.Kind, in textView: NSTextView) {
            switch command {
            case .heading:
                applyHeading(in: textView)
            case .bold:
                toggleBold(in: textView)
            case .bullet:
                insertLinePrefix("• ", in: textView)
            case .checkbox:
                insertLinePrefix("☐ ", in: textView)
            }
            usesMarkdownStyling = true
            let markdown = serializedMarkdown(from: textView)
            currentMarkdown = markdown
            pendingLocalMarkdown = markdown
            onTextChange?(markdown)
            publishBinding(markdown)
            textView.needsDisplay = true
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }

        private func scheduleBindingPublish(_ markdown: String) {
            bindingPublishWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.publishBinding(markdown)
            }
            bindingPublishWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }

        private func publishBinding(_ markdown: String) {
            bindingPublishWorkItem?.cancel()
            bindingPublishWorkItem = nil
            guard text != markdown else {
                lastBindingMarkdown = markdown
                if pendingLocalMarkdown == markdown {
                    pendingLocalMarkdown = nil
                }
                return
            }
            text = markdown
            lastBindingMarkdown = markdown
            if pendingLocalMarkdown == markdown {
                pendingLocalMarkdown = nil
            }
        }

        func bodyAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: bodyFont,
                .foregroundColor: bodyColor,
                .paragraphStyle: paragraphStyle(spacing: 8, lineHeightMultiple: 1.08)
            ]
        }

        private func attributedString(from markdown: String) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let lines = markdown.components(separatedBy: .newlines)
            for (index, rawLine) in lines.enumerated() {
                result.append(renderedLine(from: rawLine))
                if index < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: bodyAttributes()))
                }
            }
            return result
        }

        private func renderedLine(from markdown: String) -> NSAttributedString {
            if !renderMarkdownFormatting {
                return inlineAttributedString(from: markdown, attributes: bodyAttributes())
            }
            let parsed = parseLine(markdown)
            // Keep an empty typed heading marker until the user enters its
            // first character. An empty attributed string cannot carry the
            // heading font, so stripping "# " here would strand the caret at
            // the start of an unstyled paragraph.
            if markdown == "# " {
                return NSAttributedString(string: markdown, attributes: bodyAttributes())
            }
            return inlineAttributedString(from: parsed.displayText, attributes: parsed.attributes)
        }

        /// Re-renders only the paragraph containing the caret. The stored
        /// binding remains Markdown while the NSTextView contains the visible
        /// WYSIWYG text, so typing a closing delimiter can immediately promote
        /// the completed span without reparsing the whole document.
        private func applyInlineFormattingIfNeeded(in textView: NSTextView) {
            guard let storage = textView.textStorage, storage.length > 0 else { return }

            let selection = textView.selectedRange()
            let full = storage.string as NSString
            let paragraph = full.paragraphRange(for: NSRange(
                location: min(selection.location, full.length),
                length: 0
            ))
            let displayRange = NSRange(
                location: paragraph.location,
                length: paragraph.length > 0 && paragraph.upperBound <= full.length
                    && full.character(at: paragraph.upperBound - 1) == 10
                    ? paragraph.length - 1
                    : paragraph.length
            )
            guard displayRange.location + displayRange.length <= storage.length else { return }

            let markdown = markdownLine(from: storage, range: displayRange)
            let rendered = renderedLine(from: markdown)
            let current = storage.attributedSubstring(from: displayRange)
            usesMarkdownStyling = usesMarkdownStyling || Self.markdownNeedsRichRendering(markdown)

            guard !current.isEqual(to: rendered) else { return }

            let localSelectionLocation = max(0, selection.location - displayRange.location)
            let localSelectionEnd = max(
                localSelectionLocation,
                selection.location + selection.length - displayRange.location
            )
            isApplying = true
            storage.replaceCharacters(in: displayRange, with: rendered)
            isApplying = false

            // Most edits occur at the caret. Clamping against the rendered
            // line keeps the caret at the end after delimiters disappear and
            // preserves ordinary mid-line edits without a full text reset.
            let newLocation = displayRange.location + min(localSelectionLocation, rendered.length)
            let newEnd = displayRange.location + min(localSelectionEnd, rendered.length)
            textView.setSelectedRange(NSRange(
                location: newLocation,
                length: max(0, newEnd - newLocation)
            ))
        }

        private func markdownForLiveEdit(from textView: NSTextView) -> String {
            // Plain note taking should stay on the NSTextView fast path. Full
            // markdown serialization walks every attribute run, which is only
            // needed after the user has used rich editor commands or opened
            // notes that already contain markdown structure.
            guard usesMarkdownStyling else {
                return textView.string
            }
            return serializedMarkdown(from: textView)
        }

        private static func markdownNeedsRichRendering(_ markdown: String) -> Bool {
            markdown
                .components(separatedBy: .newlines)
                .contains { line in
                    line.hasPrefix("# ")
                        || line.hasPrefix("- ")
                        || line.hasPrefix("- [ ] ")
                        || line.hasPrefix("- [x] ")
                        || line.hasPrefix("- [X] ")
                        || line.contains("*")
                        || line.contains("`")
                        || line.contains("[")
                }
        }

        private func parseLine(_ line: String) -> (displayText: String, attributes: [NSAttributedString.Key: Any]) {
            if line.hasPrefix("# ") {
                return (
                    String(line.dropFirst(2)),
                    [
                        .font: headingFont,
                        .foregroundColor: bodyColor,
                        .paragraphStyle: paragraphStyle(spacing: 14, lineHeightMultiple: 1.02)
                    ]
                )
            }
            if line.hasPrefix("- [ ] ") {
                return ("☐ " + line.dropFirst(6), bodyAttributes())
            }
            if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") {
                return ("☑ " + line.dropFirst(6), bodyAttributes())
            }
            if line.hasPrefix("- ") {
                return ("• " + line.dropFirst(2), bodyAttributes())
            }
            return (line, bodyAttributes())
        }

        private func inlineAttributedString(
            from markdown: String,
            attributes: [NSAttributedString.Key: Any]
        ) -> NSAttributedString {
            let result = NSMutableAttributedString()
            let source = markdown as NSString
            let references = MeetingNoteImages.references(in: markdown)
            if !references.isEmpty {
                var offset = 0
                for reference in references {
                    if reference.range.location > offset {
                        result.append(inlineAttributedString(from: source.substring(with: NSRange(location: offset, length: reference.range.location - offset)), attributes: attributes))
                    }
                    let attachment: NSTextAttachment
                    if let cached = imageAttachments[reference.id] {
                        if let image = imageCache[reference.id] {
                            let scale = min(1, CGFloat(reference.width ?? 500) / max(image.size.width, 1))
                            let desired = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                            if cached.bounds != desired {
                                let resized = NSTextAttachment()
                                resized.image = image
                                resized.bounds = desired
                                imageAttachments[reference.id] = resized
                                attachment = resized
                            } else { attachment = cached }
                        } else { attachment = cached }
                    } else {
                        attachment = NSTextAttachment()
                        attachment.image = imageCache[reference.id] ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Image unavailable")
                        if let image = imageCache[reference.id] {
                            let scale = min(1, CGFloat(reference.width ?? 500) / max(image.size.width, 1))
                            attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
                        } else {
                            attachment.bounds = NSRect(x: 0, y: 0, width: 32, height: 32)
                            loadImage(reference.id)
                        }
                        imageAttachments[reference.id] = attachment
                    }
                    let imageText = NSMutableAttributedString(attachment: attachment)
                    imageText.addAttributes(attributes, range: NSRange(location: 0, length: imageText.length))
                    imageText.addAttribute(.muesliMarkdownImage, value: reference.markdown, range: NSRange(location: 0, length: imageText.length))
                    result.append(imageText)
                    offset = reference.range.upperBound
                }
                if offset < source.length {
                    result.append(inlineAttributedString(from: source.substring(from: offset), attributes: attributes))
                }
                return result
            }
            if !renderMarkdownFormatting {
                return NSAttributedString(string: markdown, attributes: attributes)
            }
            let parsed = MarkdownInlineParser.parse(markdown)
            let baseFont = attributes[.font] as? NSFont ?? bodyFont

            for run in parsed.runs {
                let text = String(parsed[run.range].characters)
                guard !text.isEmpty else { continue }

                var runAttributes = attributes
                var font = baseFont
                let intent = run.inlinePresentationIntent
                let isStrong = intent?.contains(.stronglyEmphasized) == true
                let isEmphasized = intent?.contains(.emphasized) == true
                let isCode = intent?.contains(.code) == true

                if isCode {
                    font = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                    runAttributes[.muesliMarkdownCode] = true
                }
                if isEmphasized {
                    font = italicVersion(of: font)
                    runAttributes[.muesliMarkdownEmphasis] = true
                }
                if isStrong {
                    font = boldVersion(of: font)
                    runAttributes[.muesliMarkdownStrong] = true
                }
                runAttributes[.font] = font
                if let link = run.link {
                    runAttributes[.link] = link
                }
                append(text, to: result, attributes: runAttributes)
            }
            return result
        }

        private func append(
            _ string: String,
            to result: NSMutableAttributedString,
            attributes: [NSAttributedString.Key: Any]
        ) {
            guard !string.isEmpty else { return }
            result.append(NSAttributedString(string: string, attributes: attributes))
        }

        private func applyHeading(in textView: NSTextView) {
            let ranges = paragraphRanges(for: textView)
            guard let storage = textView.textStorage else { return }
            let removeHeading = ranges.allSatisfy { range in
                range.length > 0 && lineIsHeading(storage: storage, range: range)
            }
            isApplying = true
            for range in ranges {
                if removeHeading {
                    storage.addAttributes(bodyAttributes(), range: range)
                } else {
                    storage.addAttributes([
                        .font: headingFont,
                        .foregroundColor: bodyColor,
                        .paragraphStyle: paragraphStyle(spacing: 14, lineHeightMultiple: 1.02)
                    ], range: range)
                }
            }
            isApplying = false
        }

        private func toggleBold(in textView: NSTextView) {
            let selectedRange = textView.selectedRange()
            if selectedRange.length == 0 {
                var attributes = textView.typingAttributes
                let currentFont = attributes[.font] as? NSFont ?? bodyFont
                attributes[.font] = isBold(currentFont) ? bodyFont : boldVersion(of: currentFont)
                textView.typingAttributes = attributes
                return
            }
            guard let storage = textView.textStorage else { return }
            let shouldUnbold = selectionIsBold(in: storage, range: selectedRange)
            isApplying = true
            storage.enumerateAttribute(.font, in: selectedRange) { value, range, _ in
                let currentFont = value as? NSFont ?? bodyFont
                let replacement = shouldUnbold ? regularVersion(of: currentFont) : boldVersion(of: currentFont)
                storage.addAttribute(.font, value: replacement, range: range)
            }
            isApplying = false
        }

        private func insertLinePrefix(_ prefix: String, in textView: NSTextView) {
            let ranges = paragraphRanges(for: textView)
            let full = textView.string as NSString
            let prefixRanges = ranges.map { range in
                let line = full.substring(with: range)
                let oldLength = ["• ", "☐ ", "☑ "].contains { line.hasPrefix($0) } ? 2 : 0
                return NSRange(location: range.location, length: oldLength)
            }

            isApplying = true
            var totalDelta = 0
            for range in prefixRanges.reversed() {
                textView.replaceCharacters(in: range, with: prefix)
                totalDelta += (prefix as NSString).length - range.length
            }
            isApplying = false

            guard let firstRange = ranges.first, let lastRange = ranges.last else { return }
            if ranges.count == 1 {
                textView.setSelectedRange(NSRange(location: firstRange.upperBound + totalDelta, length: 0))
            } else {
                let originalEnd = lastRange.location + lastRange.length
                textView.setSelectedRange(NSRange(location: firstRange.location, length: originalEnd + totalDelta - firstRange.location))
            }
        }

        private func continueListIfNeeded(in textView: NSTextView, affectedCharRange: NSRange) {
            let full = textView.string as NSString
            let paragraphRange = full.paragraphRange(for: affectedCharRange)
            let line = full.substring(with: paragraphRange).trimmingCharacters(in: .newlines)
            let prefix: String?
            if line.hasPrefix("• ") {
                prefix = line == "• " ? nil : "\n• "
            } else if line.hasPrefix("☐ ") {
                prefix = line == "☐ " ? nil : "\n☐ "
            } else if line.hasPrefix("☑ ") {
                prefix = line == "☑ " ? nil : "\n☐ "
            } else {
                prefix = "\n"
            }
            isHandlingNewline = true
            defer { isHandlingNewline = false }
            if prefix == nil {
                // Exiting empty list item — delete the marker line, leave a plain newline
                let exitText = paragraphRange.upperBound < full.length ? "\n" : ""
                textView.insertText(exitText, replacementRange: paragraphRange)
            } else {
                textView.insertText(prefix!, replacementRange: affectedCharRange)
            }
        }

        private func paragraphRanges(for textView: NSTextView) -> [NSRange] {
            let selectedRange = textView.selectedRange()
            let full = textView.string as NSString
            guard full.length > 0 else { return [NSRange(location: 0, length: 0)] }
            return full.paragraphRanges(for: selectedRange).map { range in
                var contentsEnd = 0
                full.getParagraphStart(nil, end: nil, contentsEnd: &contentsEnd, for: range)
                return NSRange(location: range.location, length: max(contentsEnd - range.location, 0))
            }
        }

        func serializedMarkdown(from textView: NSTextView) -> String {
            guard let storage = textView.textStorage else { return textView.string }
            var lines: [String] = []
            let full = storage.string as NSString
            let fullRange = NSRange(location: 0, length: full.length)
            full.enumerateSubstrings(in: fullRange, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
                lines.append(self.markdownLine(from: storage, range: range))
            }
            if storage.string.hasSuffix("\n") {
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }

        private func markdownLine(from storage: NSTextStorage, range: NSRange) -> String {
            if !renderMarkdownFormatting { return markdownInline(from: storage, contentRange: range) }
            let raw = (storage.string as NSString).substring(with: range)
            let prefix: String
            let content: String
            if raw.hasPrefix("☐ ") {
                prefix = "- [ ] "
                content = String(raw.dropFirst(2))
            } else if raw.hasPrefix("☑ ") {
                prefix = "- [x] "
                content = String(raw.dropFirst(2))
            } else if raw.hasPrefix("• ") {
                prefix = "- "
                content = String(raw.dropFirst(2))
            } else if lineIsHeading(storage: storage, range: range) {
                prefix = "# "
                content = raw
            } else {
                prefix = ""
                content = raw
            }
            let rawLength = (raw as NSString).length
            let contentLength = (content as NSString).length
            let contentRange = NSRange(location: range.location + rawLength - contentLength, length: contentLength)
            return prefix + markdownInline(from: storage, contentRange: contentRange)
        }

        private func markdownInline(from storage: NSTextStorage, contentRange: NSRange) -> String {
            guard contentRange.length > 0 else { return "" }
            var output = ""
            let isHeading = lineIsHeading(storage: storage, range: contentRange)
            storage.enumerateAttributes(in: contentRange) { attrs, range, _ in
                if let image = attrs[.muesliMarkdownImage] as? String {
                    let text = (storage.string as NSString).substring(with: range)
                    output += text.replacingOccurrences(of: "\u{fffc}", with: image)
                    return
                }
                let substring = (storage.string as NSString).substring(with: range)
                let font = attrs[.font] as? NSFont ?? bodyFont
                let isStrong = attrs[.muesliMarkdownStrong] as? Bool == true
                    || (!isHeading && isBold(font))
                let isEmphasized = attrs[.muesliMarkdownEmphasis] as? Bool == true
                let isCode = attrs[.muesliMarkdownCode] as? Bool == true

                var rendered = substring
                if isCode {
                    rendered = "`\(rendered)`"
                } else if isStrong && isEmphasized {
                    rendered = "***\(rendered)***"
                } else if isStrong {
                    rendered = "**\(rendered)**"
                } else if isEmphasized {
                    rendered = "*\(rendered)*"
                }

                if let link = attrs[.link] as? URL {
                    rendered = "[\(rendered)](\(link.absoluteString))"
                } else if let link = attrs[.link] as? String {
                    rendered = "[\(rendered)](\(link))"
                }
                output += rendered
            }
            return output
        }

        private func lineIsHeading(storage: NSTextStorage, range: NSRange) -> Bool {
            guard range.length > 0 else { return false }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            return abs((font?.pointSize ?? 0) - headingFont.pointSize) < 0.1
        }

        private func selectionIsBold(in storage: NSTextStorage, range: NSRange) -> Bool {
            guard range.length > 0 else { return false }
            var allBold = true
            storage.enumerateAttribute(.font, in: range) { value, _, stop in
                let font = value as? NSFont ?? bodyFont
                if !isBold(font) {
                    allBold = false
                    stop.pointee = true
                }
            }
            return allBold
        }

        private func isBold(_ font: NSFont) -> Bool {
            NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }

        private func boldVersion(of font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }

        private func regularVersion(of font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
        }

        private func italicVersion(of font: NSFont) -> NSFont {
            NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }

        private func paragraphStyle(spacing: CGFloat, lineHeightMultiple: CGFloat) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 4
            style.paragraphSpacing = spacing
            style.lineHeightMultiple = lineHeightMultiple
            return style
        }
    }
}

/// Moves an attachment as one undoable text edit, preserving its original
/// attributes and reference instead of re-importing or copying the image.
enum NoteImageMove {
    static func selectedImageBounds(in view: NSTextView) -> NSRect? {
        let range = view.selectedRange()
        guard range.length == 1, let storage = view.textStorage,
              range.location != NSNotFound, range.upperBound <= storage.length,
              storage.attribute(.muesliMarkdownImage, at: range.location, effectiveRange: nil) is String,
              let manager = view.layoutManager, let container = view.textContainer else { return nil }
        let glyph = manager.glyphIndexForCharacter(at: range.location)
        guard glyph < manager.numberOfGlyphs else { return nil }
        return manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
    }

    static func imageRange(in view: NSTextView, at point: NSPoint) -> NSRange? {
        guard let manager = view.layoutManager, let container = view.textContainer,
              let storage = view.textStorage, storage.length > 0, manager.numberOfGlyphs > 0 else { return nil }
        let local = NSPoint(x: point.x - view.textContainerOrigin.x, y: point.y - view.textContainerOrigin.y)
        let insertion = view.characterIndexForInsertion(at: point)
        for index in [insertion, insertion - 1] where index >= 0 && index < storage.length {
            guard storage.attribute(.muesliMarkdownImage, at: index, effectiveRange: nil) is String else { continue }
            let glyph = manager.glyphIndexForCharacter(at: index)
            guard glyph < manager.numberOfGlyphs else { continue }
            if manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) {
                return NSRange(location: index, length: 1)
            }
        }
        return nil
    }

    @discardableResult
    static func move(in view: NSTextView, source: NSRange, destination: Int) -> Bool {
        guard view.isEditable, let storage = view.textStorage,
              source.length == 1, source.location != NSNotFound,
              source.location >= 0, source.upperBound <= storage.length,
              destination >= 0, destination <= storage.length,
              storage.attribute(.muesliMarkdownImage, at: source.location, effectiveRange: nil) is String,
              destination < source.location || destination > source.upperBound else { return false }
        let image = storage.attributedSubstring(from: source)
        let replacementRange: NSRange
        let replacement = NSMutableAttributedString()
        if destination < source.location {
            replacementRange = NSRange(location: destination, length: source.upperBound - destination)
            replacement.append(image)
            replacement.append(storage.attributedSubstring(from: NSRange(location: destination, length: source.location - destination)))
        } else {
            replacementRange = NSRange(location: source.location, length: destination - source.location)
            replacement.append(storage.attributedSubstring(from: NSRange(location: source.upperBound, length: destination - source.upperBound)))
            replacement.append(image)
        }
        let imageLocation = destination < source.location ? destination : destination - source.length
        view.breakUndoCoalescing()
        return replace(in: view, range: replacementRange, with: replacement,
                       selection: NSRange(location: imageLocation, length: source.length), undoSelection: source)
    }

    @discardableResult
    static func replace(in view: NSTextView, range: NSRange,
                                with replacement: NSAttributedString, selection: NSRange,
                                undoSelection: NSRange) -> Bool {
        guard let storage = view.textStorage, range.location >= 0, range.upperBound <= storage.length else { return false }
        // This edit registers its own attributed undo below; NSTextView must not
        // also register a plain-text inverse for the same range.
        let allowsUndo = view.allowsUndo
        view.allowsUndo = false
        let allowed = view.shouldChangeText(in: range, replacementString: replacement.string)
        view.allowsUndo = allowsUndo
        guard allowed else { return false }
        let previous = storage.attributedSubstring(from: range)
        let inverseRange = NSRange(location: range.location, length: replacement.length)
        view.undoManager?.registerUndo(withTarget: view) { target in
            _ = replace(in: target, range: inverseRange, with: previous,
                        selection: undoSelection, undoSelection: selection)
        }
        view.undoManager?.setActionName("Move Image")
        storage.replaceCharacters(in: range, with: replacement)
        view.setSelectedRange(selection)
        view.didChangeText()
        view.setSelectedRange(selection)
        return true
    }
}

private final class PlaceholderTextView: NSTextView {
    var imageHandler: ((NoteImageSource) -> Void)?

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)), isEditable,
           NSPasteboard.general.availableType(from: [.png, .tiff, .fileURL]) != nil {
            return true
        }
        return super.validateMenuItem(menuItem)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isEditable, let bounds = NoteImageMove.selectedImageBounds(in: self),
           NSRect(x: bounds.maxX - 12, y: bounds.maxY - 12, width: 24, height: 24).contains(point),
           let window, let storage = textStorage {
            let range = selectedRange()
            guard let original = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment,
                  let marker = storage.attribute(.muesliMarkdownImage, at: range.location, effectiveRange: nil) as? String,
                  let reference = MeetingNoteImages.references(in: marker).first else { return }
            let before = storage.attributedSubstring(from: range)
            let aspect = bounds.height / max(bounds.width, 1)
            let maxWidth = max(1, min(800, original.image?.size.width ?? 800))
            let minWidth = min(80, maxWidth)
            var width = bounds.width
            while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                let current = convert(next.locationInWindow, from: nil)
                width = min(maxWidth, max(minWidth, bounds.width + current.x - point.x))
                if next.type == .leftMouseUp { break }
                let preview = NSTextAttachment()
                preview.image = original.image
                preview.bounds = NSRect(x: 0, y: 0, width: width, height: width * aspect)
                storage.addAttribute(.attachment, value: preview, range: range)
                needsDisplay = true
                displayIfNeeded()
            }
            storage.replaceCharacters(in: range, with: before)
            var updated = reference
            updated.width = Int(width.rounded())
            let attachment = NSTextAttachment()
            attachment.image = original.image
            attachment.bounds = NSRect(x: 0, y: 0, width: width, height: width * aspect)
            let replacement = NSMutableAttributedString(attributedString: before)
            replacement.addAttribute(.attachment, value: attachment, range: NSRange(location: 0, length: 1))
            replacement.addAttribute(.muesliMarkdownImage, value: updated.markdown, range: NSRange(location: 0, length: 1))
            _ = NoteImageMove.replace(in: self, range: range, with: replacement, selection: range, undoSelection: range)
            return
        }
        guard isEditable, event.clickCount == 1, let window,
              let range = NoteImageMove.imageRange(in: self, at: convert(event.locationInWindow, from: nil)),
              let marker = textStorage?.attribute(.muesliMarkdownImage, at: range.location, effectiveRange: nil) as? String else {
            super.mouseDown(with: event)
            return
        }
        window.makeFirstResponder(self)
        setSelectedRange(range)
        needsDisplay = true
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return }
            let point = next.locationInWindow
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else { continue }
            while let drag = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if drag.type == .leftMouseUp {
                    let location = convert(drag.locationInWindow, from: nil)
                    if bounds.contains(location),
                       textStorage?.attribute(.muesliMarkdownImage, at: range.location, effectiveRange: nil) as? String == marker {
                        _ = NoteImageMove.move(in: self, source: range, destination: characterIndexForInsertion(at: location))
                    }
                    return
                }
            }
            return
        }
    }

    override func paste(_ sender: Any?) {
        if isEditable, let source = Self.imageSource(from: .general) {
            imageHandler?(source)
        } else {
            super.paste(sender)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable, let source = Self.imageSource(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        imageHandler?(source)
        return true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        let types = sender.draggingPasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        if Self.imageSource(from: sender.draggingPasteboard) != nil { return true }
        return super.prepareForDragOperation(sender)
    }

    private static func imageSource(from pasteboard: NSPasteboard) -> NoteImageSource? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "webp"].contains(url.pathExtension.lowercased()) {
            return .file(url)
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) { return .data(data) }
        return nil
    }
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isEditable, let rect = NoteImageMove.selectedImageBounds(in: self), dirtyRect.intersects(rect) {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            outline.lineWidth = 2
            outline.stroke()
            let handle = NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 12, height: 12)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: handle).fill()
        }
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(
            x: textContainerInset.width + 5,
            y: textContainerInset.height
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppFonts.font(size: 16),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        placeholder.draw(at: origin, withAttributes: attributes)
    }
}

private extension Array where Element == NSValue {
    func clamped(to stringLength: Int) -> [NSValue] {
        map { value in
            let range = value.rangeValue
            let location = Swift.min(range.location, stringLength)
            let length = Swift.min(range.length, Swift.max(stringLength - location, 0))
            return NSValue(range: NSRange(location: location, length: length))
        }
    }
}

private extension NSString {
    func paragraphRanges(for range: NSRange) -> [NSRange] {
        let safeRange = NSRange(location: min(range.location, length), length: min(range.length, max(length - range.location, 0)))
        let paragraphRange = self.paragraphRange(for: safeRange)
        var ranges: [NSRange] = []
        var location = paragraphRange.location
        while location < paragraphRange.upperBound {
            let current = self.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(current)
            location = current.upperBound
        }
        return ranges.isEmpty ? [paragraphRange] : ranges
    }
}
