import Foundation

public enum MuesliHistoryKind: String, CaseIterable, Codable, Sendable {
    case meetings, dictations, commands, quill, cotypist, chat, vidshots
    public var settingID: String { "recap_include_" + rawValue }
    public var label: String {
        switch self {
        case .meetings: "Meetings"
        case .dictations: "Dictations"
        case .commands: "Computer Use commands"
        case .quill: "Quill"
        case .cotypist: "Accepted Cotypist text"
        case .chat: "Saved chats"
        case .vidshots: "Vidshots"
        }
    }
}
