import AppKit
import CoreText
import ImageIO

/// Uses the official app artwork (assets/muesli_app_icon.png) for offline exports.
/// Keep the bundled copy identical when the official artwork changes.
enum MeetingExportBranding {
    static let websiteURL = URL(string: "https://muesli.works")!
    static let logoData: Data = {
        guard let url = Bundle.module.url(forResource: "muesli-export-logo", withExtension: "png"),
              let data = try? Data(contentsOf: url) else {
            preconditionFailure("Missing bundled official Muesli export logo")
        }
        return data
    }()

    // Markdown has no page overlay. Embed the logo rather than referring to a
    // network URL or a sidecar file that can be lost when the export is shared.
    static var markdownFooter: String {
        "\n\n" + """
        ---

        <img src="data:image/png;base64,\(logoData.base64EncodedString())" alt="Muesli logo" width="24" height="24" />

        [Exported with Muesli](\(websiteURL.absoluteString))
        """
    }

    static func removingFooter(from markdown: String) -> String {
        guard markdown.hasSuffix(markdownFooter) else { return markdown }
        return String(markdown.dropLast(markdownFooter.count))
    }

    /// Replays the printed PDF pages and adds branding inside the bottom margin,
    /// leaving the selectable content and its pagination intact.
    static func writeBrandedPDF(from source: URL, to destination: URL) throws {
        guard let document = CGPDFDocument(source as CFURL), document.numberOfPages > 0,
              let imageSource = CGImageSourceCreateWithData(logoData as CFData, nil),
              let logo = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let label = NSAttributedString(string: "Exported with Muesli", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 9, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.45, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(label)
        let linkWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var bounds = page.getBoxRect(.mediaBox)
            context.beginPage(mediaBox: &bounds)
            context.drawPDFPage(page)
            context.saveGState()
            context.setAlpha(0.7)
            context.draw(logo, in: CGRect(x: bounds.minX + 72, y: bounds.minY + 27, width: 18, height: 18))
            context.restoreGState()
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: bounds.minX + 96, y: bounds.minY + 33)
            CTLineDraw(line, context)
            context.setURL(websiteURL as CFURL, for: CGRect(
                x: bounds.minX + 96, y: bounds.minY + 30, width: linkWidth, height: 14))
            context.endPage()
        }
        context.closePDF()
    }
}
