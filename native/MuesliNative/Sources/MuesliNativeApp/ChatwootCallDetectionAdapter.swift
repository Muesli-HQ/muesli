import CryptoKit
import Foundation

/// Side-effect-free observation only. Default collection never emits an unverified live
/// positive; injected synthetic snapshots exercise the lifecycle pending macOS acceptance.
actor ChatwootCallDetectionAdapter: CallDetectionAdapter {
    nonisolated let service: CallDetectionService = .chatwoot
    private let provider: any ChatwootCallDetectionSnapshotProviding
    private let now: @Sendable () -> Date
    private let timeout: Duration
    private let configuredOrigins: Set<String>
    private var inFlight: (id: UUID, task: Task<Void, Never>)?
    private var requestID: UUID?
    private var session: Session?

    private struct Session {
        let source: CallDetectionSource
        let providerID: UUID
        let documentURLDigest: Data
        let token: String
        var members: [UUID: String] = [:]
    }

    init(provider: any ChatwootCallDetectionSnapshotProviding = ChatwootCallDetectionCollector(),
         configuredOrigins: Set<String> = [], now: @escaping @Sendable () -> Date = { Date() },
         timeout: Duration = .milliseconds(750)) {
        self.provider = provider
        self.now = now
        self.timeout = min(max(timeout, .milliseconds(1)), .seconds(2))
        self.configuredOrigins = Set(configuredOrigins.compactMap(ChatwootCallDetectionOrigin.canonical))
    }

    func observe() async -> CallDetectionResult {
        guard !Task.isCancelled else { return .unavailable(.timedOut) }
        guard inFlight == nil else {
            // Reentrant reads cannot choose which source is current. Revoke this request,
            // keep only one draining read, and retain the last proven identity (not evidence).
            requestID = nil
            inFlight?.task.cancel()
            return .unavailable(.timedOut)
        }
        let id = UUID()
        requestID = id
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let gate = ChatwootCallDetectionDeadline()
        let provider = self.provider
        let read = Task.detached { [weak self] in
            let value = await provider.snapshot(deadline: deadline)
            await self?.finishedRead(id)
            gate.resolve(value)
        }
        inFlight = (id, read)
        let timer = Task.detached {
            do {
                try await clock.sleep(until: deadline)
                gate.resolve(.unavailable(.timedOut))
            } catch { /* cancelled after another winner */ }
        }
        let value = await withTaskCancellationHandler {
            await gate.value()
        } onCancel: {
            gate.resolve(.unavailable(.timedOut))
            read.cancel()
        }
        timer.cancel()
        guard requestID == id else { return .unavailable(.timedOut) }
        requestID = nil
        guard !Task.isCancelled, clock.now < deadline else {
            read.cancel()
            return .unavailable(.timedOut)
        }
        switch value {
        case .unavailable(let reason):
            read.cancel()
            return .unavailable(reason)
        case .snapshot(let snapshot):
            return parse(snapshot)
        }
    }

    private func finishedRead(_ id: UUID) {
        if inFlight?.id == id { inFlight = nil }
    }

    private func parse(_ snapshot: ChatwootCallDetectionSnapshot) -> CallDetectionResult {
        let age = now().timeIntervalSince(snapshot.observedAt)
        guard age.isFinite, (0...5).contains(age) else { return .unavailable(.stale) }
        let source = snapshot.sourceBefore
        guard source == snapshot.sourceAfter, source.processID > 0,
              ChatwootCallDetectionCollector.browserBundleIDs.contains(source.bundleID),
              UUID(uuidString: source.processLaunchID) != nil, UUID(uuidString: source.surfaceID) != nil,
              snapshot.urlBefore == snapshot.urlAfter,
              let origin = ChatwootCallDetectionOrigin.canonical(snapshot.urlBefore),
              source.origin == origin else { return .unavailable(.sourceMismatch) }
        guard snapshot.profile == .syntheticScopedV1 else { return .unavailable(.unsupported) }
        switch snapshot.product {
        case .scopedChatwootProfile: break
        case .configuredOrigin:
            guard configuredOrigins.contains(origin) else { return .unavailable(.unsupported) }
        case .unverified: return .unavailable(.unsupported)
        }
        guard !snapshot.surfaces.isEmpty else { return .unavailable(.noSource) }
        guard snapshot.surfaces.count == 1 else { return .unavailable(.ambiguous) }
        let call = snapshot.surfaces[0]
        guard call.kind == .activeCall else { return .unavailable(.unsupported) }
        let members: Set<UUID>
        switch call.roster {
        case .unknown: members = []
        case .partial(let ids), .complete(let ids): members = ids
        }
        guard members.count <= 256 else { return .unavailable(.unsupported) }
        if call.phase != .connected {
            session = nil
            return .observation(CallDetectionObservation(service: service, source: source,
                callToken: UUID().uuidString, observedAt: snapshot.observedAt,
                phase: call.phase, evidence: [], roster: .unknown))
        }
        guard call.transport == .remoteConnected, call.hasEndControl, call.hasMuteControl else {
            return .unavailable(.unsupported)
        }
        // Same-generation route changes violate the provider's lifecycle proof. Retain
        // only a digest in memory, not URLs/query secrets, and require a new surface ID.
        let documentURLDigest = Data(SHA256.hash(data: Data(snapshot.urlBefore.utf8)))
        if let previous = session, previous.source == source,
           previous.documentURLDigest != documentURLDigest {
            return .unavailable(.sourceMismatch)
        }
        if session?.source != source || session?.providerID != call.sessionID {
            session = Session(source: source, providerID: call.sessionID,
                              documentURLDigest: documentURLDigest, token: UUID().uuidString)
        }
        guard var current = session else { return .unavailable(.unsupported) }
        // Keep opaque IDs stable across partial reads without inventing departures. Bound
        // cumulative members as well as each snapshot; a churn-heavy session fails closed.
        guard Set(current.members.keys).union(members).count <= 256 else { return .unavailable(.unsupported) }
        for member in members where current.members[member] == nil {
            current.members[member] = UUID().uuidString
        }
        let opaqueMembers = Set(members.compactMap { current.members[$0] })
        let roster: CallDetectionRoster
        switch call.roster {
        case .unknown: roster = .unknown
        case .partial: roster = .partial(opaqueMembers)
        case .complete: roster = .complete(opaqueMembers)
        }
        session = current
        return .observation(CallDetectionObservation(service: service, source: source,
            callToken: current.token, observedAt: snapshot.observedAt, phase: .connected,
            evidence: [.scopedCallControls, .connectedState, .verifiedBrowserOrigin], roster: roster))
    }
}
