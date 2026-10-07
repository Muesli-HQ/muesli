import Foundation

/// Detection only. No capture, caller storage, consent, or messaging dependency.
/// Synthetic support is explicit; live macOS AX call mappings remain unverified.
actor TelegramCallDetectionAdapter: CallDetectionAdapter {
    nonisolated let service: CallDetectionService = .telegram
    typealias SnapshotProvider = TelegramCallDetectionReadGate.Provider

    private let reader: TelegramCallDetectionReadGate
    private let clock: @Sendable () -> Date
    private let timeout: TimeInterval
    private var requestRevision: UInt64 = 0
    private var session: Session?

    init(
        snapshotProvider: @escaping SnapshotProvider = { await TelegramCallDetectionCollector.productionRead() },
        clock: @escaping @Sendable () -> Date = { Date() },
        timeout: TimeInterval = 0.75
    ) {
        reader = TelegramCallDetectionReadGate(provider: snapshotProvider)
        self.clock = clock
        self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 2) : 0.75
    }

    func observe() async -> CallDetectionResult {
        requestRevision &+= 1
        let revision = requestRevision
        guard !Task.isCancelled else { return invalidate(.timedOut) }
        let read = await reader.read(timeout: timeout)
        // A newer busy/cancelled observation must not be undone by older work.
        guard requestRevision == revision else { return .unavailable(.ambiguous) }
        guard !Task.isCancelled else { return invalidate(.timedOut) }
        switch read {
        case .unavailable(let reason): return invalidate(reason)
        case .snapshot(let snapshot):
            let now = clock()
            let age = now.timeIntervalSince(snapshot.observedAt)
            guard now.timeIntervalSince1970.isFinite, snapshot.observedAt.timeIntervalSince1970.isFinite,
                  age.isFinite, age >= 0, age <= 5 else { return invalidate(.stale) }
            guard snapshot.isComplete else { return invalidate(.unsupported) }
            switch TelegramCallDetectionClassifier.classify(snapshot.surfaces) {
            case .unavailable(let reason): return invalidate(reason)
            case .surface(let surface): return observation(surface, at: snapshot.observedAt)
            }
        }
    }

    private func invalidate(_ reason: CallDetectionUnavailableReason) -> CallDetectionResult {
        session = nil
        return .unavailable(reason)
    }

    private func observation(_ surface: TelegramCallDetectionSurface, at: Date) -> CallDetectionResult {
        guard let phase = surface.states.first else { return invalidate(.unsupported) }
        let key = SessionKey(source: surface.observedSource, generation: surface.sessionGeneration)
        var current = session?.key == key ? session! : Session(key: key)
        let rosterKeys: Set<String>
        switch surface.roster {
        case .unknown: rosterKeys = []
        case .partial(let keys), .complete(let keys): rosterKeys = keys
        }
        let additions = rosterKeys.filter { current.participants[$0] == nil }
        guard current.participants.count + additions.count <= 256 else { return invalidate(.unsupported) }
        for participant in additions { current.participants[participant] = UUID().uuidString }
        let opaqueIDs = Set(rosterKeys.compactMap { current.participants[$0] })
        let roster: CallDetectionRoster
        switch surface.roster {
        case .unknown: roster = .unknown
        case .partial: roster = .partial(opaqueIDs)
        case .complete: roster = .complete(opaqueIDs)
        }
        session = phase == .ended ? nil : current
        var evidence: Set<CallDetectionEvidence> = []
        if !surface.enabledControls.isEmpty { evidence.insert(.scopedCallControls) }
        if phase == .connected { evidence.insert(.connectedState) }
        return .observation(CallDetectionObservation(
            service: service, source: surface.observedSource, callToken: current.token,
            observedAt: at, phase: phase, evidence: evidence, roster: roster
        ))
    }

    private struct SessionKey: Equatable {
        let source: CallDetectionSource
        let generation: String
    }

    private struct Session {
        let key: SessionKey
        let token = UUID().uuidString
        var participants: [String: String] = [:]
    }
}
