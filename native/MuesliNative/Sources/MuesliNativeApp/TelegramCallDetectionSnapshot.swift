import Foundation

/// Synthetic profile only. Neither macOS client currently has a verified AX call
/// surface mapping. The production collector never emits this profile.
enum TelegramCallDetectionProfile: Sendable, Equatable {
    case syntheticV1, unverifiedLive
}

enum TelegramCallDetectionScope: Sendable, Equatable {
    case dedicatedCall, chat, voiceMessageRecording, voiceMessagePlayback, settings, callHistory
}

enum TelegramCallDetectionControl: Sendable, Hashable {
    case endCall, mute, unmute, acceptCall, joinCall, redialCall, declineCall
}

struct TelegramCallDetectionSurface: Sendable, Equatable {
    let expectedSource: CallDetectionSource
    let observedSource: CallDetectionSource
    let profile: TelegramCallDetectionProfile
    let scope: TelegramCallDetectionScope
    let enabledControls: Set<TelegramCallDetectionControl>
    let states: [CallDetectionPhase]
    /// Opaque provider generation, never a chat ID/name. Changes on reconnect.
    let sessionGeneration: String
    /// Only explicit provider knowledge; missing AX children cannot prove completeness.
    let roster: CallDetectionRoster
}

struct TelegramCallDetectionSnapshot: Sendable, Equatable {
    let observedAt: Date
    let isComplete: Bool
    let surfaces: [TelegramCallDetectionSurface]
}

enum TelegramCallDetectionReadResult: Sendable, Equatable {
    case snapshot(TelegramCallDetectionSnapshot)
    case unavailable(CallDetectionUnavailableReason)
}

enum TelegramCallDetectionSelection: Sendable, Equatable {
    case surface(TelegramCallDetectionSurface)
    case unavailable(CallDetectionUnavailableReason)
}

enum TelegramCallDetectionClassifier {
    // Native project.pbxproj at 579cebbf; Qt Telegram/CMakeLists.txt at f23c3785.
    // https://github.com/overtake/TelegramSwift
    // https://github.com/telegramdesktop/tdesktop
    // Release identities only; naming a process does not prove an active call.
    static let bundleIDs: Set<String> = [
        "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "org.telegram.desktop",
    ]

    static func validOpaqueKey(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func validSource(_ source: CallDetectionSource) -> Bool {
        bundleIDs.contains(source.bundleID) && source.processID > 0 && source.origin == nil &&
            validOpaqueKey(source.processLaunchID) && validOpaqueKey(source.surfaceID)
    }

    static func classify(_ surfaces: [TelegramCallDetectionSurface]) -> TelegramCallDetectionSelection {
        guard surfaces.count <= 8 else { return .unavailable(.unsupported) }
        for surface in surfaces {
            guard validSource(surface.expectedSource),
                  surface.expectedSource == surface.observedSource else {
                return .unavailable(.sourceMismatch)
            }
        }
        let calls = surfaces.filter { $0.scope == .dedicatedCall }
        guard calls.count <= 1 else { return .unavailable(.ambiguous) }
        guard let call = calls.first, call.profile == .syntheticV1,
              validOpaqueKey(call.sessionGeneration) else { return .unavailable(.unsupported) }
        guard call.states.count == 1 else { return .unavailable(.ambiguous) }
        guard let phase = call.states.first, phase != .unknown else { return .unavailable(.unsupported) }
        let controls = call.enabledControls
        if phase == .connected {
            if controls.contains(.mute) && controls.contains(.unmute) { return .unavailable(.ambiguous) }
            guard controls.contains(.endCall), controls.contains(.mute) || controls.contains(.unmute),
                  controls.isDisjoint(with: [.acceptCall, .joinCall, .redialCall, .declineCall]) else {
                return .unavailable(.unsupported)
            }
        }
        let keys: Set<String>
        switch call.roster {
        case .unknown: keys = []
        case .partial(let ids), .complete(let ids): keys = ids
        }
        guard keys.count <= 128, keys.allSatisfy(validOpaqueKey) else { return .unavailable(.unsupported) }
        return .surface(call)
    }
}
