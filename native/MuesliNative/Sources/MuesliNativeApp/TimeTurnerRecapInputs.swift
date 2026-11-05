import Foundation
import MuesliCore

/// Screen history is deliberately not a toggle: every recap includes that source
/// class. New optional classes require explicit opt-in; legacy meetings stay on.
typealias TimeTurnerRecapInput = MuesliHistoryKind

extension MuesliHistoryKind {
    var configKey: WritableKeyPath<AppConfig, Bool> {
        switch self {
        case .meetings: \.recapIncludeMeetings
        case .dictations: \.recapIncludeDictations
        case .commands: \.recapIncludeCommands
        case .quill: \.recapIncludeQuill
        case .cotypist: \.recapIncludeCotypist
        case .chat: \.recapIncludeChat
        }
    }
    static func selected(_ config: AppConfig) -> [Self] { allCases.filter { config[keyPath: $0.configKey] } }
}
