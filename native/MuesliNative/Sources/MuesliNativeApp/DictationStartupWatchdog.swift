import Foundation

enum DictationStartupOwner: String, Sendable {
    case dictation, quill, computerUse = "computer_use"
}

enum DictationStartupPhase: String, Sendable {
    case queued, selectingInput = "selecting_input", audioControls = "audio_controls"
    case configuringRecorder = "configuring_recorder", preparingRecorder = "preparing_recorder"
    case startingRecorder = "starting_recorder", awaitingFirstBuffer = "awaiting_first_buffer", capturing, cleanup
}

enum DictationStartupOutcome: String, Sendable {
    case ready, warning, failed, cancelled, stopped
    case released, retryBlocked = "retry_blocked"
}

struct DictationStartupContext: Sendable {
    enum Route: String, Sendable { case speaker, headphones, unknown }
    enum Input: String, Sendable { case automatic, explicit, unknown }
    var route: Route = .unknown
    var input: Input = .unknown
}

enum DictationCaptureFailureReason: String, Sendable {
    case none, recorderError = "recorder_error", stillStopping = "still_stopping"
    case deviceUnavailable = "device_unavailable", ioStoppedAbnormally = "io_stopped_abnormally"
    case queueStoppedUnexpectedly = "queue_stopped_unexpectedly"
}

struct DictationStartupReport: Sendable {
    // Used only for local session ownership. Never included in telemetry.
    let sessionID: UUID
    let owner: DictationStartupOwner
    let outcome: DictationStartupOutcome
    let phase: DictationStartupPhase
    let elapsedMilliseconds: Int
    let warningAfterMilliseconds: Int
    let context: DictationStartupContext
    var failureReason: DictationCaptureFailureReason = .none

    var eventName: String {
        switch outcome {
        case .warning: return "dictation.microphone.startup.warning"
        case .failed where failureReason != .none: return "dictation.microphone.capture.failed"
        case .released: return "dictation.microphone.startup.released"
        case .retryBlocked: return "dictation.microphone.startup.retry_blocked"
        default: return "dictation.microphone.startup.finished"
        }
    }

    /// A strict allowlist: no audio, text, levels, recording duration, paths,
    /// device names/IDs, session IDs, or arbitrary error strings can enter it.
    var telemetryParameters: [String: String] {
        ["startup.schema_version": "2", "startup.owner": owner.rawValue,
         "startup.outcome": outcome.rawValue, "startup.phase": phase.rawValue,
         "startup.elapsed_ms": String(elapsedMilliseconds),
         "startup.warning_after_ms": String(warningAfterMilliseconds), "startup.failure_reason": failureReason.rawValue,
         "startup.route": context.route.rawValue, "startup.input_selection": context.input.rawValue]
    }
}

enum DictationMicrophoneStartupError: Int, LocalizedError, CustomNSError {
    // Code 1 was the retired startup timeout. Do not reuse it.
    case stillStopping = 2
    case deviceUnavailable = 3
    case ioStoppedAbnormally = 4
    case queueStoppedUnexpectedly = 5

    static var errorDomain: String { "MuesliMicrophoneStartup" }
    var errorCode: Int { rawValue }
    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: return "The selected microphone is no longer available. Check your input device and try again."
        case .ioStoppedAbnormally: return "Core Audio reported that microphone capture stopped unexpectedly. Try again or select another microphone."
        case .queueStoppedUnexpectedly: return "Microphone capture stopped unexpectedly. Try again or select another microphone."
        case .stillStopping: return "The previous microphone startup is still stopping. Restart muesli if it does not finish."
        }
    }
    var reason: DictationCaptureFailureReason {
        switch self {
        case .stillStopping: return .stillStopping
        case .deviceUnavailable: return .deviceUnavailable
        case .ioStoppedAbnormally: return .ioStoppedAbnormally
        case .queueStoppedUnexpectedly: return .queueStoppedUnexpectedly
        }
    }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "Microphone startup failed."] }
}

/// One advisory timer, independent of the capture queue. A warning never ends
/// an attempt: slow starts can still become ready. Only events or user actions
/// terminate it. There is no polling or per-buffer work.
final class DictationStartupWatchdog: @unchecked Sendable {
    typealias Scheduler = (TimeInterval, @escaping @Sendable () -> Void) -> Void
    static let defaultWarningDelay: TimeInterval = 3 // Warning presentation only; never a failure deadline.

    private struct Entry {
        let id: UUID
        let beganAt: UInt64
        var phase: DictationStartupPhase = .queued
        var context = DictationStartupContext()
        var outcome: DictationStartupOutcome?
        var readyElapsedMilliseconds: Int?
        var firstBufferSeen = false
        var startReturned = false
        var needsRelease = false
        var warned = false
        var failureReason: DictationCaptureFailureReason = .none
    }

    private let lock = NSLock()
    private var entry: Entry?
    private let warningDelay: TimeInterval
    private let owner: DictationStartupOwner
    private let schedule: Scheduler
    private let now: @Sendable () -> UInt64
    var onReport: ((DictationStartupReport) -> Void)?

    init(warningDelay: TimeInterval = defaultWarningDelay, owner: DictationStartupOwner = .dictation,
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         schedule: Scheduler? = nil) {
        precondition(warningDelay.isFinite && warningDelay > 0 && warningDelay <= 60)
        self.warningDelay = warningDelay
        self.owner = owner
        self.now = now
        let queue = DispatchQueue(label: "com.muesli.microphone-startup-warning")
        self.schedule = schedule ?? { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    @discardableResult
    func begin(_ id: UUID) -> Bool {
        let isNew = lock.withLock {
            guard entry?.id != id else { return false }
            entry = Entry(id: id, beganAt: now())
            return true
        }
        if isNew { schedule(warningDelay) { [weak self] in self?.expire(id) } }
        return isNew
    }

    func phase(_ phase: DictationStartupPhase, session id: UUID, context: DictationStartupContext? = nil) {
        lock.withLock {
            guard entry?.id == id, entry?.outcome == nil else { return }
            entry?.phase = phase
            if let context { entry?.context = context }
        }
    }

    @discardableResult
    func firstBuffer(_ id: UUID) -> Bool {
        var report: DictationStartupReport?
        let accepted = lock.withLock {
            guard var current = entry, current.id == id, current.outcome == nil,
                  !current.firstBufferSeen else { return false }
            current.firstBufferSeen = true
            if current.startReturned {
                current.readyElapsedMilliseconds = elapsedMilliseconds(current)
                current.phase = .capturing
                current.outcome = .ready
                report = makeReport(current, outcome: .ready)
            }
            entry = current
            return true
        }
        if let report { onReport?(report) }
        return accepted
    }

    @discardableResult
    func startReturned(_ id: UUID) -> Bool {
        var report: DictationStartupReport?
        let accepted = lock.withLock {
            guard var current = entry, current.id == id, current.outcome == nil else { return false }
            current.startReturned = true
            current.phase = .awaitingFirstBuffer
            if current.firstBufferSeen {
                current.readyElapsedMilliseconds = elapsedMilliseconds(current)
                current.phase = .capturing
                current.outcome = .ready
                report = makeReport(current, outcome: .ready)
            }
            entry = current
            return true
        }
        if let report { onReport?(report) }
        return accepted
    }

    func accepts(_ id: UUID) -> Bool {
        lock.withLock { entry?.id == id && (entry?.outcome == nil || entry?.outcome == .ready) }
    }

    func isPending(_ id: UUID) -> Bool {
        lock.withLock { entry?.id == id && entry?.outcome == nil }
    }

    func finish(_ id: UUID?, outcome: DictationStartupOutcome, failureReason: DictationCaptureFailureReason = .none) {
        let report: DictationStartupReport? = lock.withLock {
            guard var current = entry, current.id == id,
                  current.outcome == nil || current.outcome == .ready else { return nil }
            let shouldReport = current.outcome == nil || outcome == .failed
            current.needsRelease = current.outcome == nil || outcome == .failed
            current.outcome = outcome
            current.failureReason = failureReason
            entry = current
            return shouldReport ? makeReport(current, outcome: outcome) : nil
        }
        if let report { onReport?(report) }
    }

    func released(_ id: UUID) { reportLifecycle(id, outcome: .released) }
    func retryBlocked(_ id: UUID) { reportLifecycle(id, outcome: .retryBlocked) }

    private func reportLifecycle(_ id: UUID, outcome: DictationStartupOutcome) {
        let report: DictationStartupReport? = lock.withLock {
            guard var current = entry, current.id == id,
                  current.needsRelease, current.outcome != nil, current.outcome != .ready,
                  current.outcome != .released else { return nil }
            if outcome == .released { current.phase = .cleanup; current.outcome = .released; entry = current }
            return makeReport(current, outcome: outcome)
        }
        if let report { onReport?(report) }
    }

    private func expire(_ id: UUID) {
        let report: DictationStartupReport? = lock.withLock {
            guard var current = entry, current.id == id, current.outcome == nil,
                  !current.warned else { return nil }
            current.warned = true
            entry = current
            return makeReport(current, outcome: .warning)
        }
        if let report { onReport?(report) }
    }

    private func elapsedMilliseconds(_ entry: Entry) -> Int {
        // After readiness this field remains startup latency, never dictation
        // duration, even if a device fails much later in the recording.
        if let readyElapsedMilliseconds = entry.readyElapsedMilliseconds { return readyElapsedMilliseconds }
        let tick = now()
        let elapsed = tick >= entry.beganAt ? (tick - entry.beganAt) / 1_000_000 : 0
        return Int(min(elapsed, 60_000))
    }

    private func makeReport(_ entry: Entry, outcome: DictationStartupOutcome) -> DictationStartupReport {
        return DictationStartupReport(sessionID: entry.id, owner: owner, outcome: outcome,
            phase: entry.phase, elapsedMilliseconds: elapsedMilliseconds(entry),
            warningAfterMilliseconds: Int(warningDelay * 1_000), context: entry.context, failureReason: entry.failureReason)
    }
}
