import Foundation

/// Detection only: no capture callbacks or consent/identity persistence.
/// Default construction is fail-closed inventory scaffolding, not validated
/// Signal connected-call support. See SignalCallDetectionSystemSnapshotProvider.
actor SignalCallDetectionAdapter: CallDetectionAdapter {
    nonisolated let service = CallDetectionService.signal
    private let provider: any SignalCallDetectionSnapshotProvider
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    private var pendingRead: UUID?
    private var revision: UInt64 = 0
    private var session: Session?

    private struct Session {
        let source: CallDetectionSource
        let generation: String
        let token: String
        var participants: [String: String] = [:]
    }

    init(
        provider: any SignalCallDetectionSnapshotProvider = SignalCallDetectionSystemSnapshotProvider(),
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: TimeInterval = 1
    ) {
        self.provider = provider
        self.now = now
        self.timeout = timeout.isFinite ? min(1, max(0.01, timeout)) : 1
    }

    func observe() async -> CallDetectionResult {
        revision &+= 1
        let requestRevision = revision
        guard !Task.isCancelled else { return unavailable(.timedOut) }
        // A retired AX/provider call can still be executing. Do not accumulate
        // reads or let an overlapping observer resurrect its session.
        guard pendingRead == nil else { return unavailable(.ambiguous) }
        let readID = UUID()
        pendingRead = readID
        let startedAt = now()
        let result = await SignalCallDetectionRead.perform(
            provider: provider, deadline: startedAt.addingTimeInterval(timeout), timeout: timeout,
            onProviderFinished: { await self.finishRead(readID) }
        )
        guard !Task.isCancelled else { return unavailable(.timedOut) }
        guard revision == requestRevision else { return unavailable(.sourceMismatch) }
        switch result {
        case let .unavailable(reason): return unavailable(reason)
        case let .snapshot(snapshot): return consume(snapshot)
        }
    }

    private func finishRead(_ readID: UUID) {
        if pendingRead == readID { pendingRead = nil }
    }

    private func unavailable(_ reason: CallDetectionUnavailableReason) -> CallDetectionResult {
        session = nil
        return .unavailable(reason)
    }

    private func consume(_ snapshot: SignalCallDetectionSnapshot) -> CallDetectionResult {
        let age = now().timeIntervalSince(snapshot.observedAt)
        guard age.isFinite, age >= 0, age <= 5 else { return unavailable(.stale) }
        guard snapshot.profile == .syntheticV1, snapshot.surfaces.count <= 8 else {
            return unavailable(.unsupported)
        }
        let source = snapshot.source
        guard source.bundleID == "org.whispersystems.signal-desktop", source.processID > 0,
              validIdentifier(source.processLaunchID), validIdentifier(source.surfaceID), source.origin == nil else {
            return unavailable(.sourceMismatch)
        }
        let calls = snapshot.surfaces.filter { $0.content == .call }
        guard calls.count <= 1 else { return unavailable(.ambiguous) }
        guard snapshot.surfaces.allSatisfy({ $0.source == source }) else {
            return unavailable(.sourceMismatch)
        }
        guard let call = calls.first else { return unavailable(.noSource) }
        guard call.source == source, validIdentifier(call.callGeneration) else {
            return unavailable(.sourceMismatch)
        }
        guard call.connection == .accepted else { return unavailable(.noSource) }
        guard call.hasHangupControl && call.hasMicrophoneControl else { return unavailable(.unsupported) }

        if session?.source != source || session?.generation != call.callGeneration {
            session = Session(source: source, generation: call.callGeneration, token: UUID().uuidString)
        }
        guard var current = session else { return unavailable(.unsupported) }
        let roster = scopedRoster(call.roster, session: &current)
        session = current
        return .observation(.init(service: .signal, source: source, callToken: current.token,
                                  observedAt: snapshot.observedAt, phase: .connected,
                                  evidence: [.scopedCallControls, .connectedState], roster: roster))
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
    }

    private func scopedRoster(_ roster: CallDetectionRoster, session: inout Session) -> CallDetectionRoster {
        let ids: Set<String>
        let complete: Bool
        switch roster {
        case .unknown: return .unknown
        case let .partial(values): ids = values; complete = false
        case let .complete(values): ids = values; complete = true
        }
        guard ids.count <= 128, ids.allSatisfy(validIdentifier), !(complete && ids.isEmpty) else { return .unknown }
        let missing = ids.filter { session.participants[$0] == nil }
        guard session.participants.count + missing.count <= 512 else { return .unknown }
        for id in missing { session.participants[id] = UUID().uuidString }
        let scoped = Set(ids.compactMap { session.participants[$0] })
        // Keep call-local mappings across partial/unknown snapshots and temporary
        // disappearance. Partial evidence never proves participant departures.
        return complete ? .complete(scoped) : .partial(scoped)
    }
}
