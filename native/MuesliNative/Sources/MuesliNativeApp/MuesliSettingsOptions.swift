import Foundation

struct MeetingDetectionAppOption: Identifiable {
    let bundleID: String
    let name: String
    let icon: String

    var id: String { bundleID }
}

enum OnDeviceCleanupModel: Identifiable {
    case gguf(PostProcessorOption)
    case gemma4(Gemma4LiteRTModel)

    var id: String {
        switch self {
        case let .gguf(option): option.id
        case let .gemma4(model): model.repoID
        }
    }

    var label: String {
        switch self {
        case let .gguf(option): option.label
        case let .gemma4(model): model.label
        }
    }

    var quilLabel: String {
        switch self {
        case let .gguf(option): option.quilLabel
        case let .gemma4(model): model.label
        }
    }

    var quilBackend: TranscriptCleanupBackendOption {
        switch self {
        case .gguf: .local
        case .gemma4: .gemma4LiteRT
        }
    }

    var quilModelID: String {
        switch self {
        case let .gguf(option): option.id
        case let .gemma4(model): model.repoID
        }
    }
}

extension MuesliSettings {
    static let meetingDetectionAppOptions: [MeetingDetectionAppOption] = [
        MeetingDetectionAppOption(bundleID: "com.google.Chrome", name: "Chrome", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "company.thebrowser.Browser", name: "Arc", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.apple.Safari", name: "Safari", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.microsoft.edgemac", name: "Edge", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.brave.Browser", name: "Brave", icon: "globe"),
        MeetingDetectionAppOption(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", icon: "message.fill"),
        MeetingDetectionAppOption(bundleID: "us.zoom.xos", name: "Zoom", icon: "video.fill"),
        MeetingDetectionAppOption(bundleID: "com.microsoft.teams2", name: "Teams", icon: "person.2.fill"),
        MeetingDetectionAppOption(bundleID: "com.apple.FaceTime", name: "FaceTime", icon: "video.fill"),
        MeetingDetectionAppOption(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", icon: "phone.fill"),
    ]
}

extension MuesliSettings {
    static let accentPresets: [(hex: String, name: String)] = [
        ("2563eb", "Blue"),
        ("ef4444", "Red"),
        ("f59e0b", "Amber"),
        ("10b981", "Green"),
        ("8b5cf6", "Purple"),
        ("ec4899", "Pink"),
        ("1e1e2e", "Dark"),
    ]
}
