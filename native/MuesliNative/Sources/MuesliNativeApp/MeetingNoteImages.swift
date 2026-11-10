import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MeetingNoteImageError: LocalizedError {
    case tooMany, unsupportedProvider, unsupportedImageFormat
    var errorDescription: String? {
        switch self {
        case .tooMany: "A meeting can include up to three note images for summary generation."
        case .unsupportedProvider: "The selected summary model cannot process note images. Choose a vision-capable model or remove the images and try again."
        case .unsupportedImageFormat: "The image format is not supported by summary providers. Use a PNG, JPEG, GIF, or WebP image."
        }
    }
}

/// Local assets referenced by meeting-note Markdown. The UUID is deliberately
/// opaque: notes may sync, but image bytes do not currently sync with them.
enum MeetingNoteImages {
    static let maximumImageBytes = 20 * 1_024 * 1_024
    static let maximumStoredBytes = maximumImageBytes
    static let maximumImageCount = 3
    // Leaves room for three base64 images and meeting text within provider limits.
    static let maximumSummaryImageBytes = 1_500_000
    private static let pattern = try! NSRegularExpression(
        pattern: #"!\[Image\]\(muesli-note-image:([0-9A-Fa-f-]{36})(?:\?width=([0-9]{1,4}))?\)"#
    )

    struct Reference: Equatable {
        let id: UUID
        let range: NSRange
        var width: Int? = nil
        var markdown: String { "![Image](muesli-note-image:\(id.uuidString)\(width.map { "?width=\($0)" } ?? ""))" }
    }

    static func references(in markdown: String) -> [Reference] {
        guard markdown.contains("![Image](muesli-note-image:") else { return [] }
        let full = markdown as NSString
        return pattern.matches(in: markdown, range: NSRange(location: 0, length: full.length)).compactMap {
            guard let id = UUID(uuidString: full.substring(with: $0.range(at: 1))) else { return nil }
            let widthRange = $0.range(at: 2)
            let width = widthRange.location == NSNotFound ? nil : Int(full.substring(with: widthRange))
            return Reference(id: id, range: $0.range, width: width)
        }
    }

    static func url(for id: UUID, supportDirectory: URL = AppIdentity.supportDirectoryURL) -> URL {
        let folder = supportDirectory.appendingPathComponent("Meeting Note Images", isDirectory: true)
        let original = folder.appendingPathComponent(id.uuidString + ".image", isDirectory: false)
        if FileManager.default.fileExists(atPath: original.path) { return original }
        return folder.appendingPathComponent(id.uuidString + ".jpg", isDirectory: false)
    }

    /// Decoding and conversion must run on a worker queue, not the UI thread.
    static func save(_ data: Data, supportDirectory: URL = AppIdentity.supportDirectoryURL) throws -> Reference {
        guard !data.isEmpty, data.count <= maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 100_000_000 / height else { throw ChatFileError.tooLarge }
        let reference = Reference(id: UUID(), range: NSRange(location: 0, length: 0))
        let destinationURL = supportDirectory.appendingPathComponent("Meeting Note Images", isDirectory: true)
            .appendingPathComponent(reference.id.uuidString + ".image")
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: destinationURL, options: .atomic)
        return reference
    }

    static func inputs(in markdown: String, supportDirectory: URL = AppIdentity.supportDirectoryURL) throws -> [ChatImageInput] {
        let refs = references(in: markdown)
        var seen = Set<UUID>()
        let unique = refs.filter { seen.insert($0.id).inserted }
        guard unique.count <= maximumImageCount else { throw MeetingNoteImageError.tooMany }
        return try unique.map { reference in
            let fileURL = url(for: reference.id, supportDirectory: supportDirectory)
            guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe), !data.isEmpty,
                  data.count <= maximumStoredBytes else { throw ChatFileError.unavailable }
            return try summaryImage(data)
        }
    }

    /// A bounded provider-compatible representation; never modifies the stored original.
    static func summaryImage(_ data: Data) throws -> ChatImageInput {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ChatFileError.unavailable
        }
        let mediaType = CGImageSourceGetType(source).flatMap { UTType($0 as String) }?.preferredMIMEType
        if data.count <= maximumSummaryImageBytes, let mediaType,
           ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mediaType) {
            return ChatImageInput(name: "Meeting note image", data: data, mediaType: mediaType)
        }
        for dimension in [2048, 1536, 1024, 768] {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceThumbnailMaxPixelSize: dimension,
                 kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ChatFileError.unsupported }
            for quality in [0.85, 0.7, 0.5, 0.3] {
                let result = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { throw ChatFileError.unsupported }
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ChatFileError.unsupported }
                if result.length <= maximumSummaryImageBytes {
                    return ChatImageInput(name: "Meeting note image", data: result as Data, mediaType: "image/jpeg")
                }
            }
        }
        throw ChatFileError.tooLarge
    }

    /// Copy only referenced assets, and rewrite their opaque local URLs to paths
    /// relative to the exported Markdown file.
    static func exportMarkdown(_ markdown: String, to destination: URL,
                               supportDirectory: URL = AppIdentity.supportDirectoryURL) throws -> String {
        let refs = references(in: markdown)
        guard !refs.isEmpty else { return markdown }
        let folderName = destination.deletingPathExtension().lastPathComponent + "-assets"
        let folder = destination.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
        var copied = Set<UUID>()
        var extensions: [UUID: String] = [:]
        var created: [URL] = []
        let folderExisted = FileManager.default.fileExists(atPath: folder.path)
        do {
        for reference in refs where copied.insert(reference.id).inserted {
            let source = url(for: reference.id, supportDirectory: supportDirectory)
            guard FileManager.default.fileExists(atPath: source.path),
                  let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let type = CGImageSourceGetType(imageSource).flatMap({ UTType($0 as String) }) else { continue }
            let ext = type.preferredFilenameExtension ?? "image"
            extensions[reference.id] = ext
            let target = folder.appendingPathComponent(reference.id.uuidString + "." + ext)
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
                created.append(target)
            }
        }
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            if !folderExisted { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
        let result = NSMutableString(string: markdown)
        let safe = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?()"))
        let encodedFolder = folderName.addingPercentEncoding(withAllowedCharacters: safe) ?? folderName
        for reference in refs.reversed() {
            let replacement = extensions[reference.id].map { "![Image](\(encodedFolder)/\(reference.id.uuidString).\($0))" }
                ?? "*[Image unavailable on this device]*"
            result.replaceCharacters(in: reference.range, with: replacement)
        }
        return result as String
    }
}
