import Foundation

/// Shared by floating and notch presentations. Later delivery cases are rendered but unused in slice 1.
enum FeedbackCapturePillState: Equatable {
    case preparing
    case recording(seconds: Int, deadMicrophone: Bool)
    case discardConfirmation(seconds: Int, deadMicrophone: Bool)
    case processing
    case ready
    case recovered
    case copied(partial: String?)
    case readyToCopy(partial: String?)
    case blocked(permission: String)
    case busy(activity: String)
    case failed(stage: String, message: String, retainedMedia: Bool)

    var isRecording: Bool {
        switch self { case .recording, .discardConfirmation: true; default: false }
    }
    var isComplete: Bool {
        switch self { case .ready, .recovered, .copied, .readyToCopy, .failed: true; default: false }
    }
    var title: String {
        switch self {
        case .preparing: "Preparing Scrawl"
        case .recording(let seconds, _): String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .discardConfirmation: "Discard?"
        case .processing: "Processing"
        case .ready: "Ready"
        case .recovered: "Recovered"
        case .copied(let partial): "Copied" + (partial.map { " · \($0)" } ?? "")
        case .readyToCopy(let partial): "Ready · Copy" + (partial.map { " · \($0)" } ?? "")
        case .blocked(let permission): "Scrawl needs \(permission)"
        case .busy(let activity): "\(activity) first"
        case .failed(let stage, let message, _): "\(stage) failed: \(message)"
        }
    }
    static func microphoneIsDead(lastSample: Date?, startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastSample ?? startedAt) >= 0.6
    }
}
