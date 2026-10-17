import AppKit
import SwiftUI

enum MeetingSpeakerSelectionState {
    static func rangeToApply(binding: NSRange, current: NSRange, text: String) -> NSRange? {
        let textLength = (text as NSString).length
        let location = min(max(binding.location, 0), textLength)
        let length = min(max(binding.length, 0), textLength - location)
        let normalized = NSRange(location: location, length: length)
        return normalized == current ? nil : normalized
    }
}

/// Read-only selection over one real turn; NSRange stays in Cocoa's UTF-16 coordinate system.
struct MeetingSpeakerSelectionView: NSViewRepresentable {
    let text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .systemFont(ofSize: 14); view.textColor = .labelColor
        view.drawsBackground = false; view.delegate = context.coordinator
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Transcript block for word selection")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.selection = $selection
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.isUpdating = true
        defer { context.coordinator.isUpdating = false }
        if view.string != text { view.string = text }
        if let range = MeetingSpeakerSelectionState.rangeToApply(
            binding: selection, current: view.selectedRange(), text: text
        ) {
            view.setSelectedRange(range)
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var selection: Binding<NSRange>
        var isUpdating = false
        init(selection: Binding<NSRange>) { self.selection = selection }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let view = notification.object as? NSTextView else { return }
            selection.wrappedValue = view.selectedRange()
        }
    }
}
