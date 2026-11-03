import Foundation

/// A user-selected original, never an imported copy. Payload bytes and thumbnails
/// are deliberately absent from persisted chat JSON, sync and search projections.
public struct ChatFileReference: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, pdf, markdown, text }
    public let id: String
    public let name: String
    public let kind: Kind
    public let bookmark: Data
    public let byteCount: Int64
    public init(id: String, name: String, kind: Kind, bookmark: Data, byteCount: Int64) {
        self.id = id; self.name = name; self.kind = kind; self.bookmark = bookmark; self.byteCount = byteCount
    }
}

/// Local answer metadata only; no extracted document text or intermediate notes.
public struct ChatDocumentCoverage: Codable, Equatable, Sendable {
    public let fileID: String
    public let totalPages: Int
    public let pagesWithoutText: Int
    public let wasCondensed: Bool
    public init(fileID: String, totalPages: Int, pagesWithoutText: Int, wasCondensed: Bool) {
        self.fileID = fileID; self.totalPages = totalPages
        self.pagesWithoutText = pagesWithoutText; self.wasCondensed = wasCondensed
    }
}
