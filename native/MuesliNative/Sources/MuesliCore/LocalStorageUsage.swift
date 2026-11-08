import Foundation

public struct LocalStorageUsage: Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case models, meetingAudio, meetingVideo, feedbackCaptures, database, waveformCache, other
    }
    public struct Entry: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let bytes: Int64
    }
    public var bytes: [Category: Int64] = [:]
    public var models: [Entry] = []
    public var unavailableLocations = 0
    public var freeBytes: Int64?
    public var totalBytes: Int64 { bytes.values.reduce(0, +) }

    /// Read-only scan of known app/model locations. Symlinks are not traversed;
    /// overlapping roots and hard links count once. No file contents are read.
    public static func scan(support: URL, modelRoots: [URL]) -> Self {
        var result = Self()
        let manager = FileManager.default
        var seenPaths: Set<String> = []
        var seenFiles: Set<AnyHashable> = []
        var modelSizes: [String: Int64] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileSizeKey, .fileResourceIdentifierKey]
        let sources = modelRoots.map { ($0, true) } + [(support, false)]
        for (source, isModel) in sources {
            if (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            let root = source.standardizedFileURL.resolvingSymlinksInPath()
            if Task.isCancelled { break }
            guard manager.fileExists(atPath: root.path) else { continue }
            if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in
                result.unavailableLocations += 1
                return true
            }) else { result.unavailableLocations += 1; continue }
            for case let file as URL in walker {
                if Task.isCancelled { break }
                do {
                    let info = try file.resourceValues(forKeys: keys)
                    guard info.isSymbolicLink != true, info.isRegularFile == true,
                          seenPaths.insert(file.standardizedFileURL.path).inserted else { continue }
                    if let identity = info.fileResourceIdentifier as? AnyHashable,
                       !seenFiles.insert(identity).inserted { continue }
                    let size = Int64(info.totalFileAllocatedSize ?? info.fileSize ?? 0)
                    let path = file.standardizedFileURL.resolvingSymlinksInPath().path
                    let relative = String(path.dropFirst(root.path.count + 1))
                    let category = isModel ? Category.models : category(for: relative)
                    result.bytes[category, default: 0] += size
                    if isModel {
                        let name = relative.split(separator: "/").first.map(String.init) ?? file.lastPathComponent
                        modelSizes[name, default: 0] += size
                    }
                } catch { result.unavailableLocations += 1 }
            }
        }
        result.models = modelSizes.map { Entry(name: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
        result.freeBytes = ((try? manager.attributesOfFileSystem(forPath: support.path)[.systemFreeSize]) as? NSNumber)?.int64Value
        return result
    }

    public static func category(for path: String) -> Category {
        if path.hasPrefix("feedback-captures/") { return .feedbackCaptures }
        if path.hasPrefix("meeting-recordings/videos/") {
            return path.hasSuffix(".mp4") ? .meetingVideo : .other
        }
        if path.hasPrefix("meeting-recordings/") { return .meetingAudio }
        if path == "muesli.db" || path.hasPrefix("muesli.db-") { return .database }
        if path.hasPrefix("waveform-cache/") { return .waveformCache }
        return .other
    }
}
