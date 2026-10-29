import AppKit
import MuesliCore

@MainActor
enum MedASRTermsPresentation {
    typealias Presenter = (NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Void

    /// Returns immediately. A sheet response, not a nested app-wide modal loop,
    /// records acceptance and resumes the explicit user action.
    static func request(license: MedASRLicense = .shared, present: @escaping Presenter,
                        onAccepted: @escaping () -> Void) {
        if license.isAccepted { onAccepted(); return }
        do {
            let alert = NSAlert()
            alert.messageText = "MedASR terms"
            alert.informativeText = "Review Google's terms before using MedASR."
            alert.addButton(withTitle: "Agree & Continue")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = scrollView(text: try MedASRLicense.agreementText())
            present(alert) { response in
                guard response == .alertFirstButtonReturn else { return }
                do {
                    try license.accept()
                    onAccepted()
                } catch {
                    present(NSAlert(error: error)) { _ in }
                }
            }
        } catch {
            present(NSAlert(error: error)) { _ in }
        }
    }

    static func scrollView(text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 300))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        // Choose the text system explicitly: default views on recent macOS use
        // TextKit 2, which does not expose NSLayoutManager's full-document metrics.
        let content = NSTextView(usingTextLayoutManager: false)
        content.frame = scroll.contentView.bounds
        content.isEditable = false
        content.isRichText = false
        content.isSelectable = true
        content.font = .systemFont(ofSize: 12)
        content.textContainerInset = NSSize(width: 8, height: 8)
        content.isVerticallyResizable = true
        content.isHorizontallyResizable = false
        content.autoresizingMask = [.width]
        content.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        content.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        content.textContainer?.heightTracksTextView = false
        // A finite container yields full glyph metrics before the alert is mounted;
        // CGFloat.greatestFiniteMagnitude can produce an empty used rect in AppKit.
        content.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: 1_000_000)
        content.textContainer?.widthTracksTextView = true
        content.setAccessibilityLabel("Google MedASR terms and use restrictions")
        scroll.documentView = content
        content.string = text
        if let container = content.textContainer, let manager = content.layoutManager {
            manager.ensureLayout(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs))
            let height = manager.usedRect(for: container).height + 2 * content.textContainerInset.height
            content.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, height)))
        }
        return scroll
    }
}
