import Foundation

/// A user-selected original, never an imported copy. Payload bytes and thumbnails
/// are deliberately absent from persisted chat JSON, sync and search projections.
public struct ChatFileReference: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, pdf }
    public let id: String
    public let name: String
    public let kind: Kind
    public let bookmark: Data
    public let byteCount: Int64
    public init(id: String, name: String, kind: Kind, bookmark: Data, byteCount: Int64) {
        self.id = id; self.name = name; self.kind = kind; self.bookmark = bookmark; self.byteCount = byteCount
    }
}
