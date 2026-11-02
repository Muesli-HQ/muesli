import AppKit
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision
import MuesliCore

enum ChatFileError: Error, LocalizedError, Equatable {
    case unavailable, changed, unsupported, tooLarge, tooMany, unreadablePDF, unreadableText, unsupportedProvider
    var errorDescription: String? {
        switch self {
        case .unavailable: "An attached file is no longer available. Remove it or attach the original again."
        case .changed: "An attached file changed. Attach it again before sending."
        case .unsupported: "Choose an image, PDF, Markdown (.md or .markdown), or plain-text (.txt) file."
        case .tooLarge: "Use files up to 20 MB each (40 MB total), images up to 100 megapixels, PDFs up to 50 pages, and document text up to 48,000 characters."
        case .tooMany: "Attach up to five files, including up to three images."
        case .unreadablePDF: "This PDF is locked or has no readable text. Choose an unlocked document or an image."
        case .unreadableText: "This text file is empty or unreadable. Save it as UTF-8 and attach it again."
        case .unsupportedProvider: "Image attachments need a vision-capable model through ChatGPT, OpenAI, OpenRouter or Anthropic. PDF, Markdown and plain text work with your current provider."
        }
    }
}

struct ChatImageInput: Sendable {
    let name: String
    let data: Data
    var dataURL: String { "data:image/jpeg;base64," + data.base64EncodedString() }
    var responsesContent: [String: Any] { ["type": "input_image", "image_url": dataURL, "detail": "auto"] }
    var chatContent: [String: Any] { ["type": "image_url", "image_url": ["url": dataURL]] }
    var anthropicContent: [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]]
    }
}

struct PreparedChatFiles: Sendable {
    var context = ""
    var images: [ChatImageInput] = []
    var isEmpty: Bool { context.isEmpty && images.isEmpty }
    static let empty = PreparedChatFiles()
}

/// Called only by MeetingChatWorker. No body evaluation, thumbnail cache, imported
/// file directory, remote Files API, or persisted base64 representation is used.
enum ChatFileReader {
    static let supportedContentTypes: [UTType] = [.image, .pdf, .plainText,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "markdown") ?? .plainText]
    static let maximumContextCharacters = 48_000
    // Bound bytes before decoding, even for invalid UTF-8 or combining characters.
    static let maximumTextBytes = maximumContextCharacters * 4 + 3
    static let maximumFiles = 5
    static let maximumFileBytes: Int64 = 20 * 1_024 * 1_024
    static let maximumTotalBytes: Int64 = 40 * 1_024 * 1_024
    static let maximumRequestBytes = 12 * 1_024 * 1_024
    static func requestData(_ body: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: body)
        guard data.count <= maximumRequestBytes else { throw ChatFileError.tooLarge }
        return data
    }

    static func references(urls: [URL], existing: [ChatFileReference]) throws -> [ChatFileReference] {
        var result = existing
        for originalURL in urls {
            var url = originalURL
            url.removeAllCachedResourceValues()
            try Task.checkCancellation()
            guard url.isFileURL else { throw ChatFileError.unsupported }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
            guard values.isRegularFile == true else { throw ChatFileError.unsupported }
            let size = Int64(values.fileSize ?? 0)
            guard size > 0, size <= maximumFileBytes else { throw ChatFileError.tooLarge }
            let kind: ChatFileReference.Kind
            if ["md", "markdown"].contains(url.pathExtension.lowercased()) { kind = .markdown }
            else if url.pathExtension.lowercased() == "txt" { kind = .text }
            else if values.contentType?.conforms(to: .pdf) == true { kind = .pdf }
            else if values.contentType?.conforms(to: .image) == true { kind = .image }
            else { throw ChatFileError.unsupported }
            if kind == .markdown || kind == .text, size > maximumTextBytes { throw ChatFileError.tooLarge }
            let id = try digest(url)
            // The same bytes selected twice occupy one attachment slot.
            if result.contains(where: { $0.id == id }) { continue }
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            result.removeAll { old in
                var stale = false
                return (try? URL(resolvingBookmarkData: old.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale))?.standardizedFileURL == url.standardizedFileURL
            }
            result.append(.init(id: id, name: String(url.lastPathComponent.prefix(240)), kind: kind, bookmark: bookmark, byteCount: size))
            try validateLimits(result)
        }
        return result
    }

    static func validateLimits(_ files: [ChatFileReference]) throws {
        guard files.count <= maximumFiles, files.filter({ $0.kind == .image }).count <= 3 else { throw ChatFileError.tooMany }
        guard files.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= maximumFileBytes }),
              files.reduce(Int64(0), { $0 + $1.byteCount }) <= maximumTotalBytes else { throw ChatFileError.tooLarge }
    }

    static func withOriginal<T>(_ file: ChatFileReference, _ body: (URL) throws -> T) throws -> T {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: file.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale), url.isFileURL else { throw ChatFileError.unavailable }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ChatFileError.unavailable }
        guard Int64(values.fileSize ?? 0) == file.byteCount, try digest(url) == file.id else { throw ChatFileError.changed }
        let value = try body(url)
        try Task.checkCancellation()
        guard try digest(url) == file.id else { throw ChatFileError.changed }
        return value
    }

    static func validate(_ files: [ChatFileReference]) throws {
        try validateLimits(files)
        for file in files { try withOriginal(file) { _ in () } }
    }

    static func metadataStamp(_ file: ChatFileReference) throws -> String {
        var stale = false
        let url = try URL(resolvingBookmarkData: file.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard Int64(values.fileSize ?? -1) == file.byteCount else { throw ChatFileError.changed }
        return "\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? -1):\(String(describing: values.fileResourceIdentifier))"
    }

    static func prepare(_ files: [ChatFileReference], config: AppConfig) throws -> PreparedChatFiles {
        try validateLimits(files)
        let provider = MeetingSummaryBackendOption.resolved(config.meetingSummaryBackend)
        if files.contains(where: { $0.kind == .image }), ![.chatGPT, .openAI, .openRouter, .anthropic].contains(provider) {
            throw ChatFileError.unsupportedProvider
        }
        var prepared = PreparedChatFiles()
        for file in files {
            try Task.checkCancellation()
            try withOriginal(file) { url in
                switch file.kind {
                case .image:
                    prepared.images.append(.init(name: file.name, data: try image(url)))
                    prepared.context += "\nImage attachment: " + quoted(file.name) + ". Interpret the supplied image; do not infer meeting facts from it.\n"
                case .markdown, .text:
                    let label = file.kind == .markdown ? "Markdown" : "Plain-text"
                    prepared.context += "\n" + label + " attachment: " + quoted(file.name) + "\n" + (try text(url))
                case .pdf:
                    prepared.context += "\nPDF attachment (text/OCR only; layout and embedded images are not supplied): " + quoted(file.name) + "\n" + (try pdf(url))
                }
            }
            guard prepared.context.count <= maximumContextCharacters else { throw ChatFileError.tooLarge }
        }
        return prepared
    }

    private static func text(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(32_768, maximumTextBytes - data.count + 1)), !chunk.isEmpty {
            try Task.checkCancellation()
            guard data.count + chunk.count <= maximumTextBytes else { throw ChatFileError.tooLarge }
            data.append(chunk)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatFileError.unreadableText }
        guard text.count <= maximumContextCharacters else { throw ChatFileError.tooLarge }
        return text
    }

    private static func quoted(_ value: String) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(); var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation(); count += Int64(chunk.count)
            guard count <= maximumFileBytes else { throw ChatFileError.tooLarge }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func image(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000_000 / height else { throw ChatFileError.tooLarge }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2_048,
             kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ChatFileError.unsupported }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ChatFileError.unsupported }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 2 * 1_024 * 1_024 else { throw ChatFileError.tooLarge }
        return data as Data
    }

    private static func pdf(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { throw ChatFileError.unreadablePDF }
        guard document.pageCount <= 50 else { throw ChatFileError.tooLarge }
        var text = ""; var hasReadableText = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let pageText: String = try autoreleasepool {
            guard let page = document.page(at: index) else { throw ChatFileError.unreadablePDF }
            var pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if pageText.isEmpty {
                let preview = page.thumbnail(of: NSSize(width: 1_536, height: 1_536), for: .mediaBox)
                var bounds = CGRect(origin: .zero, size: preview.size)
                if let cg = preview.cgImage(forProposedRect: &bounds, context: nil, hints: nil) {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate; request.automaticallyDetectsLanguage = true
                    try VNImageRequestHandler(cgImage: cg).perform([request])
                    pageText = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                }
            }
                return pageText
            }
            hasReadableText = hasReadableText || !pageText.isEmpty
            text += "\n[Page \(index + 1)]\n" + pageText
            guard text.count <= 48_000 else { throw ChatFileError.tooLarge }
        }
        guard hasReadableText else { throw ChatFileError.unreadablePDF }
        return text
    }
}
