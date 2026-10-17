import Foundation

public struct MeetingSpeakerColour: Equatable, Sendable {
    public let light: Int
    public let dark: Int
    public init(light: Int, dark: Int) { self.light = light; self.dark = dark }
}

/// An original palette. Labels remain visible because colour alone cannot convey identity.
public enum MeetingSpeakerPalette {
    public static let owner = MeetingSpeakerColour(light: 0x0A5B47, dark: 0x8FE0BD)
    public static let neutral = MeetingSpeakerColour(light: 0x454952, dark: 0xC3C7D0)
    public static let remote: [MeetingSpeakerColour] = [
        .init(light: 0x0B5269, dark: 0x9DDDF0), .init(light: 0x353C89, dark: 0xAABCF9),
        .init(light: 0x6B2F74, dark: 0xEDB6EE), .init(light: 0x744411, dark: 0xF5C79A),
        .init(light: 0x32561B, dark: 0xBEDF88), .init(light: 0x7B2948, dark: 0xE9AFBD)
    ]

    public static func colour(for key: MeetingSpeakerKey?, isSelf: Bool, isPerson: Bool) -> MeetingSpeakerColour {
        if isSelf { return owner }
        guard isPerson, let key else { return neutral }
        // Swift Hasher is randomized between processes. FNV-1a keeps persisted keys stable.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(key.epoch.uuidString)|\(key.channel.rawValue)|\(key.clusterID)".utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return remote[Int(hash % UInt64(remote.count))]
    }
}
