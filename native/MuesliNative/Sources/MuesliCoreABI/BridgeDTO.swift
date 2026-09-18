import Foundation
import MuesliCore

/// Versioned UTF-8 JSON request for one insert. Only fields owned by the shared
/// `DictationStore` model cross the boundary; Windows-only fields stay in C#.
struct BridgeInsertRequest: Decodable {
    let text: String
    let durationSeconds: Double
    let appContext: String?
    let source: String?
    let targetAppName: String?
    let targetAppBundleId: String?
    let startedAt: String?
    let endedAt: String?
}

/// One dictation as returned across the boundary. `timestamp` is the verbatim
/// store value (ISO-8601) so the caller controls presentation.
struct BridgeRecord: Codable {
    let id: Int64
    let timestamp: String
    let durationSeconds: Double?
    let rawText: String
    let appContext: String
    let wordCount: Int
    let source: String
    let targetAppName: String?
    let targetAppBundleId: String?

    init(_ record: DictationRecord) {
        self.id = record.id
        self.timestamp = record.timestamp
        self.durationSeconds = record.durationSeconds
        self.rawText = record.rawText
        self.appContext = record.appContext
        self.wordCount = record.wordCount
        self.source = record.source
        self.targetAppName = record.targetAppName
        self.targetAppBundleId = record.targetAppBundleID
    }
}

struct BridgeRecentResponse: Codable {
    let records: [BridgeRecord]
}

/// Versioned text metrics payload. `version` lets Windows reject or adapt to a
/// future metric set instead of misreading it.
struct BridgeTextMetrics: Codable {
    let version: Int
    let wordCount: Int
}
