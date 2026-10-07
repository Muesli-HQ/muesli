import Dispatch
import Foundation

/// Observation-only adapter. It has no recording, consent or messaging dependency.
/// The default collector is fail-closed until a native LINE AX schema is verified.
actor LINECallDetectionAdapter: CallDetectionAdapter {
    nonisolated let service = CallDetectionService.line
    private let provider: any LINECallDetectionSnapshotProviding
    private let now: @Sendable () -> Date
    private let timeout: Duration
    private var latestRequest = UUID()
    private var flight: UUID?
    private var activeGate: LINECallDetectionReadGate?
    private var session: Session?

    private struct Session {
        let source: CallDetectionSource
        let generation: String
        let token: String
        let observedAt: Date
    }

    init(
        provider: any LINECallDetectionSnapshotProviding = LINECallDetectionCollector(),
        now: @escaping @Sendable () -> Date = { Date() },
        timeout: Duration = .milliseconds(500)
    ) {
        self.provider = provider
        self.now = now
        self.timeout = timeout
    }

    func observe() async -> CallDetectionResult {
        let request = UUID()
        latestRequest = request
        guard !Task.isCancelled, timeout > .zero else { return lose(.timedOut) }
        if let activeGate {
            // Logical observations overlap even when the provider just finished.
            activeGate.resolve(.unavailable(.ambiguous))
            self.activeGate = nil
            return lose(.ambiguous)
        }
        // Retain a cancelled provider flight until it actually returns.
        if flight != nil { return lose(.timedOut) }

        let id = UUID()
        let gate = LINECallDetectionReadGate()
        flight = id
        activeGate = gate
        let clock = ContinuousClock()
        let started = clock.now
        let provider = self.provider
        let timeout = self.timeout
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let read = Task {
                    guard !Task.isCancelled else { self.finished(id); return }
                    let result = await provider.snapshot()
                    self.finished(id)
                    gate.resolve(result)
                }
                let timer = Task {
                    do {
                        try await Task.sleep(for: timeout)
                        gate.resolve(.unavailable(.timedOut))
                    } catch { /* The winning read cancelled the timer. */ }
                }
                gate.attach(read: read, timer: timer)
            }
        } onCancel: {
            gate.resolve(.unavailable(.timedOut))
        }
        if activeGate === gate { activeGate = nil }
        guard latestRequest == request else { return .unavailable(.ambiguous) }
        // A delayed timer or cancellation callback cannot allow a late positive.
        guard !Task.isCancelled, started.duration(to: clock.now) < timeout else {
            return lose(.timedOut)
        }
        switch result {
        case .unavailable(let reason): return lose(reason)
        case .snapshot(let snapshot): return evaluate(snapshot)
        }
    }

    private func finished(_ id: UUID) {
        if flight == id { flight = nil }
    }

    private func lose(_ reason: CallDetectionUnavailableReason) -> CallDetectionResult {
        session = nil
        return .unavailable(reason)
    }

    private func evaluate(_ snapshot: LINECallDetectionSnapshot) -> CallDetectionResult {
        let source = snapshot.sourceBeforeRead
        guard source == snapshot.sourceAfterRead,
              source.bundleID == "jp.naver.line.mac", source.processID > 0,
              !source.processLaunchID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.surfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.origin == nil else { return lose(.sourceMismatch) }
        let age = now().timeIntervalSince(snapshot.observedAt)
        guard age.isFinite, age >= 0, age <= 5 else { return lose(.stale) }
        guard !snapshot.surfaces.isEmpty else { return lose(.noSource) }
        guard snapshot.surfaces.count == 1 else { return lose(.ambiguous) }
        let surface = snapshot.surfaces[0]
        guard surface.kind == .connected,
              surface.controls.isSuperset(of: [.endCall, .mute]),
              !surface.callGeneration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              validRoster(surface.roster) else { return lose(.unsupported) }
        let gap = session.map { snapshot.observedAt.timeIntervalSince($0.observedAt) }
        if session?.source != source || session?.generation != surface.callGeneration
            || gap.map({ !$0.isFinite || $0 < 0 || $0 > 5 }) == true {
            session = Session(source: source, generation: surface.callGeneration,
                              token: UUID().uuidString, observedAt: snapshot.observedAt)
        }
        guard let current = session else { return lose(.unsupported) }
        session = Session(source: source, generation: surface.callGeneration,
                          token: current.token, observedAt: snapshot.observedAt)
        return .observation(.init(service: .line, source: source, callToken: current.token,
                                  observedAt: snapshot.observedAt, phase: .connected,
                                  evidence: [.scopedCallControls, .connectedState], roster: surface.roster))
    }

    private func validRoster(_ roster: CallDetectionRoster) -> Bool {
        switch roster {
        case .unknown: return true
        case .partial(let ids), .complete(let ids):
            return !ids.isEmpty && ids.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }
}

/// Lock-protected one-shot completion, including cancellation before install.
/// Loser tasks are cancelled and detached from this gate on resolution.
private final class LINECallDetectionReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: LINECallDetectionCollection?
    private var continuation: CheckedContinuation<LINECallDetectionCollection, Never>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<LINECallDetectionCollection, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func attach(read: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        if result != nil {
            lock.unlock()
            cancelOutsideExecutor([timer, read])
        } else {
            tasks = [timer, read]
            lock.unlock()
        }
    }

    func resolve(_ result: LINECallDetectionCollection) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        continuation?.resume(returning: result)
        cancelOutsideExecutor(tasks)
    }

    private func cancelOutsideExecutor(_ tasks: [Task<Void, Never>]) {
        // Task.cancel invokes arbitrary provider cancellation handlers synchronously.
        // A bounded observer must never execute those on its actor or caller.
        DispatchQueue.global(qos: .utility).async {
            for task in tasks { task.cancel() }
        }
    }

}
