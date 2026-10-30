import AppKit
import MuesliCore
import Observation

/// UI reads only this snapshot. Refresh on startup, activation and Models mounting;
/// never perform file I/O while building settings or rendering a model card.
@MainActor
@Observable
final class MedASRTermsState {
    private(set) var isAccepted = false
    @ObservationIgnored private var revision = 0

    func refresh(read: @escaping @Sendable () -> Bool = { MedASRLicense.shared.isAccepted }) async {
        revision += 1
        let request = revision
        let accepted = await Task.detached(priority: .userInitiated, operation: read).value
        guard !Task.isCancelled, request == revision else { return }
        if isAccepted != accepted { isAccepted = accepted }
    }

    func didAccept() {
        // An earlier read must not overwrite the completed explicit acceptance.
        revision += 1
        if !isAccepted { isAccepted = true }
    }
}

@MainActor
enum MedASRTermsPresentation {
    typealias Presenter = (NSAlert, @escaping @MainActor (NSApplication.ModalResponse) async -> Void) -> Void

    /// Returns immediately. A sheet response, not a nested app-wide modal loop,
    /// records acceptance and resumes the explicit user action.
    static func request(license: MedASRLicense = .shared, present: @escaping Presenter,
                        onAccepted: @escaping () -> Void) async {
        let accepted = await Task.detached(priority: .userInitiated) { license.isAccepted }.value
        guard !Task.isCancelled else { return }
        if accepted { onAccepted(); return }
        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try MedASRLicense.agreementText()
            }.value
            guard !Task.isCancelled else { return }
            let alert = NSAlert()
            alert.messageText = "MedASR terms"
            alert.informativeText = "Review Google's terms before using MedASR."
            alert.addButton(withTitle: "Agree & Continue")
            alert.addButton(withTitle: "Cancel")
            alert.accessoryView = scrollView(text: text)
            present(alert) { response in
                guard response == .alertFirstButtonReturn else { return }
                do {
                    try await Task.detached(priority: .userInitiated) { try license.accept() }.value
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
        content.font = AppFonts.font(size: 12)
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
