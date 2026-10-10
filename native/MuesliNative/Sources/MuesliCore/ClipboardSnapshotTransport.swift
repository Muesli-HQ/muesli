import Foundation

/// Private, versioned pipe protocol shared by the app and its bundled helper.
/// Phase markers carry no clipboard content. The binary plist avoids base64's
/// expansion when preserving image pasteboards with several representations.
public enum ClipboardSnapshotTransport {
    public static let ready = Data("MCS2R".utf8)
    public static let payloadReady: UInt8 = 0x50
    public static let maximumDataBytes = 128 * 1024 * 1024
    public static let maximumWireBytes = 136 * 1024 * 1024
    public static let maximumItems = 128
    public static let maximumFlavorsPerItem = 64
    public static let maximumTypeBytes = 1024
}

public struct ClipboardSnapshotPayload: Codable, Sendable {
    public struct Flavor: Codable, Sendable {
        public let type: String
        public let data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public let changeCount: Int
    public let items: [[Flavor]]

    public init(changeCount: Int, items: [[Flavor]]) {
        self.changeCount = changeCount
        self.items = items
    }
}
