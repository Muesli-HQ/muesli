import Foundation

/// Observation only. No recording/consent capability; production currently returns unavailable.
actor WeChatCallDetectionAdapter: CallDetectionAdapter {
    nonisolated let service: CallDetectionService = .weChat
    private let provider: any WeChatCallDetectionSnapshotProviding
    private let now: @Sendable () -> Date
    private let timeout: Duration
    private var requestGeneration: UInt64 = 0
    private var connectedSource: CallDetectionSource?
    private var connectedGeneration: String?
    private var connectedToken: String?

    init(
        provider: any WeChatCallDetectionSnapshotProviding = WeChatCallDetectionCollector(),
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: Duration = .seconds(1)
    ) {
        precondition(timeout > .zero && timeout <= .seconds(1))
        self.provider = provider
        self.now = now
        self.timeout = timeout
    }

    func observe() async -> CallDetectionResult {
        requestGeneration &+= 1
        let generation = requestGeneration
        let result = await weChatCallDetectionCollect(provider, timeout: timeout)
        // Actor reentrancy: obsolete callbacks cannot revoke or restore a newer session.
        guard generation == requestGeneration else { return .unavailable(.stale) }
        guard !Task.isCancelled else { return unavailable(.timedOut) }
        switch result {
        case .unavailable(let reason):
            return unavailable(reason)
        case .snapshot(let snapshot):
            let age = now().timeIntervalSince(snapshot.observedAt)
            guard age.isFinite && age >= 0 && age <= 5 else { return unavailable(.stale) }
            guard !snapshot.surfaces.isEmpty else { return unavailable(.noSource) }
            // Never choose a frontmost surface over another possible call.
            guard snapshot.surfaces.count == 1 else { return unavailable(.ambiguous) }
            let surface = snapshot.surfaces[0]
            let source = surface.source
            guard source == surface.expectedSource,
                  source.bundleID == WeChatCallDetectionCollector.bundleID,
                  source.processID > 0, !source.processLaunchID.isEmpty,
                  !source.surfaceID.isEmpty, source.origin == nil,
                  !surface.sessionGeneration.isEmpty else { return unavailable(.sourceMismatch) }
            guard surface.schema == .syntheticV1 else { return unavailable(.unsupported) }
            let phase: CallDetectionPhase
            switch surface.activity {
            case .connected: phase = .connected
            case .ringing: phase = .ringing
            case .connecting: phase = .connecting
            case .ended: phase = .ended
            case .idle, .voiceNoteRecording, .voiceNotePlayback, .unknown: phase = .unknown
            }
            let token: String
            let evidence: Set<CallDetectionEvidence>
            if phase == .connected {
                guard surface.controls.isSuperset(of: [.endCall, .mute]) else { return unavailable(.unsupported) }
                if connectedSource != source || connectedGeneration != surface.sessionGeneration || connectedToken == nil {
                    connectedToken = UUID().uuidString
                }
                connectedSource = source
                connectedGeneration = surface.sessionGeneration
                token = connectedToken!
                evidence = [.scopedCallControls, .connectedState]
            } else {
                clearConnectedSession()
                token = UUID().uuidString
                evidence = []
            }
            return .observation(CallDetectionObservation(
                service: service, source: source, callToken: token, observedAt: snapshot.observedAt,
                phase: phase, evidence: evidence, roster: surface.roster
            ))
        }
    }

    private func clearConnectedSession() {
        connectedSource = nil
        connectedGeneration = nil
        connectedToken = nil
    }
    private func unavailable(_ reason: CallDetectionUnavailableReason) -> CallDetectionResult {
        clearConnectedSession()
        return .unavailable(reason)
    }
}

/// A task group would await even an uncooperative losing provider at teardown.
/// This one-shot race bounds the caller; providers must independently bound underlying work.
private func weChatCallDetectionCollect(
    _ provider: any WeChatCallDetectionSnapshotProviding, timeout: Duration
) async -> WeChatCallDetectionSnapshotResult {
    let race = WeChatCallDetectionRace()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            guard race.install(continuation) else { return }
            let collection = Task { race.resolve(await provider.snapshot()) }
            race.add(collection)
            let deadline = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                race.resolve(.unavailable(.timedOut))
            }
            race.add(deadline)
        }
    } onCancel: {
        race.resolve(.unavailable(.timedOut)) // frozen contract has no separate cancelled reason
    }
}

/// Every mutable field is protected by lock; continuations resume and tasks cancel outside it.
private final class WeChatCallDetectionRace: @unchecked Sendable {
    private let lock = NSLock()
    private var result: WeChatCallDetectionSnapshotResult?
    private var continuation: CheckedContinuation<WeChatCallDetectionSnapshotResult, Never>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<WeChatCallDetectionSnapshotResult, Never>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }
    func add(_ task: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished { tasks.append(task) }
        lock.unlock()
        if finished { task.cancel() }
    }
    func resolve(_ result: WeChatCallDetectionSnapshotResult) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks.removeAll()
        lock.unlock()
        for task in tasks { task.cancel() }
        continuation?.resume(returning: result)
    }
}
