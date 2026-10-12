import Foundation
@testable import MuesliNativeApp

// Compiled synthetic values, never harvested chat contents or live AX objects.
enum TelegramCallDetectionFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let source = CallDetectionSource(
        bundleID: "ru.keepcoder.Telegram", processID: 42,
        processLaunchID: "fixture-launch", surfaceID: "fixture-window", origin: nil
    )

    static func surface(
        source: CallDetectionSource = source,
        observedSource: CallDetectionSource? = nil,
        profile: TelegramCallDetectionProfile = .syntheticV1,
        scope: TelegramCallDetectionScope = .dedicatedCall,
        controls: Set<TelegramCallDetectionControl> = [.endCall, .mute],
        states: [CallDetectionPhase] = [.connected],
        generation: String = "fixture-session",
        roster: CallDetectionRoster = .unknown
    ) -> TelegramCallDetectionSurface {
        TelegramCallDetectionSurface(
            expectedSource: source, observedSource: observedSource ?? source,
            profile: profile, scope: scope, enabledControls: controls,
            states: states, sessionGeneration: generation, roster: roster
        )
    }

    static func read(
        _ surfaces: [TelegramCallDetectionSurface] = [surface()],
        at: Date = now, complete: Bool = true
    ) -> TelegramCallDetectionReadResult {
        .snapshot(TelegramCallDetectionSnapshot(observedAt: at, isComplete: complete, surfaces: surfaces))
    }

    static func changedSource(
        bundleID: String = source.bundleID, pid: Int32 = source.processID,
        launch: String = source.processLaunchID, surface: String = source.surfaceID,
        origin: String? = nil
    ) -> CallDetectionSource {
        CallDetectionSource(bundleID: bundleID, processID: pid,
                            processLaunchID: launch, surfaceID: surface, origin: origin)
    }
}

actor TelegramCallDetectionFixtureProvider {
    private var results: [TelegramCallDetectionReadResult]
    init(_ results: [TelegramCallDetectionReadResult]) { self.results = results }
    func next() -> TelegramCallDetectionReadResult {
        guard !results.isEmpty else { return .unavailable(.noSource) }
        return results.removeFirst()
    }
}

enum TelegramCallDetectionTestFailure: Error { case expectedObservation }

extension TelegramCallDetectionFixtures {
    static func observation(_ result: CallDetectionResult) throws -> CallDetectionObservation {
        guard case .observation(let value) = result else { throw TelegramCallDetectionTestFailure.expectedObservation }
        return value
    }
}

final class TelegramCallDetectionFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func set(_ value: Date) { lock.withLock { self.value = value } }
}
