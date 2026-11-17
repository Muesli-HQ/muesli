import AppKit
import SwiftUI
import AIElementsSwift
import MuesliCore

struct MeetingChatAttachmentPreview: View {
    let file: ChatFileReference
    let coordinator: MeetingChatCoordinator
    var allowsPreview = true
    var onRemove: (() -> Void)? = nil
    @State private var thumbnail: NSImage?

    private var isVisual: Bool { file.kind == .pdf || file.kind == .image }
    private var detail: String {
        let kind = switch file.kind { case .pdf: "PDF"; case .image: "Image"; case .markdown: "Markdown"; case .text: "Text" }
        return kind + " · " + ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)
    }
    var body: some View {
        AIAttachmentPreview(title: file.name, detail: detail, icon: file.kind == .image ? .image : .fileText,
            preview: allowsPreview ? thumbnail.map { Image(nsImage: $0) } : nil,
            showsPreview: isVisual, onRemove: onRemove)
            .help(file.name + " · " + detail)
            .task(id: allowsPreview ? file.id : nil) {
                guard allowsPreview, isVisual else { thumbnail = nil; return }
                let data = await coordinator.fileThumbnail(file)
                guard !Task.isCancelled else { return }
                thumbnail = data.flatMap { NSImage(data: $0) }
            }
            .onDisappear { thumbnail = nil }
    }
}
