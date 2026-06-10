import Foundation
import os

enum MeetingMicHealthState: String, Codable, Equatable {
    case healthy
    case waitingForAudio
    case micCallbacksMissing
    case micAllZeroWhileSystemActive

    var userMessage: String? {
        switch self {
        case .healthy, .waitingForAudio:
            return nil
        case .micCallbacksMissing:
            return "Microphone audio is not reaching Muesli. This meeting transcript may miss your side."
        case .micAllZeroWhileSystemActive:
            return "Microphone audio is silent. This meeting transcript may miss your side."
        }
    }
}

struct MeetingMicHealthTransition: Codable, Equatable {
    let timestamp: Date
    let state: MeetingMicHealthState
    let reason: String
}

struct MeetingMicHealthSnapshot: Codable {
    let state: MeetingMicHealthState
    let rawMic: AudioSampleStatsSnapshot
    let systemAudio: AudioSampleStatsSnapshot
    let firstRawMicCallbackAt: Date?
    let firstNonZeroMicAt: Date?
    let firstSystemAudioAt: Date?
    let lastRawMicCallbackAt: Date?
    let lastNonZeroMicAt: Date?
    let lastSystemAudioAt: Date?
    let transitions: [MeetingMicHealthTransition]

    var warningMessage: String? {
        state.userMessage
    }
}

final class MeetingMicHealthTracker {
    private struct State {
        var healthState: MeetingMicHealthState = .waitingForAudio
        var rawMicStats = AudioSampleStats()
        var systemAudioStats = AudioSampleStats()
        var firstRawMicCallbackAt: Date?
        var firstNonZeroMicAt: Date?
        var firstSystemAudioAt: Date?
        var lastRawMicCallbackAt: Date?
        var lastNonZeroMicAt: Date?
        var lastSystemAudioAt: Date?
        var lastRawMicWasEffectivelyZero = true
        var activeSystemSamplesWhileMicMissing = 0
        var activeSystemSamplesWhileMicZero = 0
        var transitions: [MeetingMicHealthTransition] = []
    }

    private static let sampleRate = 16_000
    private static let activeSystemPeakThreshold = 0.01
    private static let nonZeroMicPeakThreshold = 0.0001
    private static let zeroRatioThreshold = 0.999
    private static let degradedConfirmationSamples = sampleRate * 3
    private static let micCallbackStaleThreshold: TimeInterval = 1.0
    private static let maxTransitions = 32

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func noteRawMicSamples(_ samples: [Int16], now: Date = Date()) -> MeetingMicHealthSnapshot {
        lock.withLock { state in
            state.rawMicStats.addInt16(samples)
            state.firstRawMicCallbackAt = state.firstRawMicCallbackAt ?? now
            state.lastRawMicCallbackAt = now
            state.activeSystemSamplesWhileMicMissing = 0

            let stats = statsForSamples(samples)
            let zeroRatio = stats.sampleCount > 0
                ? Double(stats.zeroSampleCount) / Double(stats.sampleCount)
                : 1
            let hasSignal = stats.peak > Self.nonZeroMicPeakThreshold
                || zeroRatio < Self.zeroRatioThreshold
            state.lastRawMicWasEffectivelyZero = !hasSignal
            if hasSignal {
                state.firstNonZeroMicAt = state.firstNonZeroMicAt ?? now
                state.lastNonZeroMicAt = now
                state.activeSystemSamplesWhileMicMissing = 0
                state.activeSystemSamplesWhileMicZero = 0
                transitionLocked(&state, to: .healthy, reason: "raw_mic_signal_detected", now: now)
            }
            return snapshotLocked(state)
        }
    }

    func noteSystemSamples(_ samples: [Int16], now: Date = Date()) -> MeetingMicHealthSnapshot {
        lock.withLock { state in
            state.systemAudioStats.addInt16(samples)
            let stats = statsForSamples(samples)
            guard stats.peak > Self.activeSystemPeakThreshold else {
                return snapshotLocked(state)
            }

            state.firstSystemAudioAt = state.firstSystemAudioAt ?? now
            state.lastSystemAudioAt = now

            if state.lastRawMicCallbackAt == nil {
                state.activeSystemSamplesWhileMicMissing += samples.count
                if state.activeSystemSamplesWhileMicMissing >= Self.degradedConfirmationSamples {
                    transitionLocked(&state, to: .micCallbacksMissing, reason: "system_audio_active_without_mic_callbacks", now: now)
                }
            } else if state.lastRawMicWasEffectivelyZero {
                state.activeSystemSamplesWhileMicZero += samples.count
                if state.activeSystemSamplesWhileMicZero >= Self.degradedConfirmationSamples {
                    transitionLocked(&state, to: .micAllZeroWhileSystemActive, reason: "system_audio_active_with_zero_mic", now: now)
                }
            } else if let lastRawMicCallbackAt = state.lastRawMicCallbackAt,
                      now.timeIntervalSince(lastRawMicCallbackAt) >= Self.micCallbackStaleThreshold {
                state.activeSystemSamplesWhileMicMissing += samples.count
                if state.activeSystemSamplesWhileMicMissing >= Self.degradedConfirmationSamples {
                    transitionLocked(&state, to: .micCallbacksMissing, reason: "system_audio_active_after_mic_callbacks_stopped", now: now)
                }
            } else {
                state.activeSystemSamplesWhileMicMissing = 0
                state.activeSystemSamplesWhileMicZero = 0
            }
            return snapshotLocked(state)
        }
    }

    func snapshot() -> MeetingMicHealthSnapshot {
        lock.withLock { snapshotLocked($0) }
    }

    private func transitionLocked(
        _ state: inout State,
        to nextState: MeetingMicHealthState,
        reason: String,
        now: Date
    ) {
        guard state.healthState != nextState else { return }
        state.healthState = nextState
        state.transitions.append(MeetingMicHealthTransition(timestamp: now, state: nextState, reason: reason))
        if state.transitions.count > Self.maxTransitions {
            state.transitions.removeFirst(state.transitions.count - Self.maxTransitions)
        }
    }

    private func snapshotLocked(_ state: State) -> MeetingMicHealthSnapshot {
        MeetingMicHealthSnapshot(
            state: state.healthState,
            rawMic: state.rawMicStats.snapshot(),
            systemAudio: state.systemAudioStats.snapshot(),
            firstRawMicCallbackAt: state.firstRawMicCallbackAt,
            firstNonZeroMicAt: state.firstNonZeroMicAt,
            firstSystemAudioAt: state.firstSystemAudioAt,
            lastRawMicCallbackAt: state.lastRawMicCallbackAt,
            lastNonZeroMicAt: state.lastNonZeroMicAt,
            lastSystemAudioAt: state.lastSystemAudioAt,
            transitions: state.transitions
        )
    }

    private func statsForSamples(_ samples: [Int16]) -> AudioSampleStatsSnapshot {
        var stats = AudioSampleStats()
        stats.addInt16(samples)
        return stats.snapshot()
    }
}
