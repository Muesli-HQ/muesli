import Foundation
import MuesliCore

/// Runs one caller lookup per meeting capture attempt.
///
/// A lookup belongs to the capture attempt that started it: its result is
/// attached only to that attempt's meeting, and only while the attempt is still
/// live. Every place a capture ends retires its attempt, so a lookup can never
/// read the next call and attach it to a recording that has already stopped.
/// The caller one capture attempt attached, reported when the attempt ends.
struct CallerAttachment: Hashable, Sendable {
    let meetingID: Int64
    let personID: UUID
}

@MainActor
final class FailedCallerRollbackRegistry {
    private var attachmentsByMeeting: [Int64: Set<CallerAttachment>] = [:]

    func record(_ attachment: CallerAttachment) {
        attachmentsByMeeting[attachment.meetingID, default: []].insert(attachment)
    }

    @discardableResult
    func remove(_ attachment: CallerAttachment) -> Bool {
        guard var attachments = attachmentsByMeeting[attachment.meetingID],
              attachments.remove(attachment) != nil else {
            return false
        }
        attachmentsByMeeting[attachment.meetingID] = attachments.isEmpty ? nil : attachments
        return true
    }

    func pending(for meetingID: Int64) -> Set<CallerAttachment> {
        attachmentsByMeeting[meetingID] ?? []
    }
}

/// Serializes caller detaches per meeting and lets resumed captures wait until
/// the previous detach has committed.
@MainActor
final class CallerDetachTaskRegistry {
    private struct Entry {
        let token: UUID
        let task: Task<Bool, Never>
    }

    private var tasks: [Int64: Entry] = [:]

    func enqueue(meetingID: Int64, operation: @escaping @MainActor () async -> Bool) {
        let previousTask = tasks[meetingID]?.task
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            let previousSucceeded = await previousTask?.value ?? true
            let succeeded = await operation()
            if self?.tasks[meetingID]?.token == token {
                self?.tasks[meetingID] = nil
            }
            return previousSucceeded && succeeded
        }
        tasks[meetingID] = Entry(token: token, task: task)
    }

    var pendingMeetingIDs: Set<Int64> { Set(tasks.keys) }

    func wait(for meetingID: Int64) async -> Bool {
        var succeeded = true
        while let task = tasks[meetingID]?.task {
            let taskSucceeded = await task.value
            succeeded = succeeded && taskSucceeded
        }
        return succeeded
    }
}

@MainActor
final class CallerNameSaveGate {
    private var activeSave: (token: UUID, task: Task<Bool, Never>)?

    func perform(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        while let activeSave {
            _ = await activeSave.task.value
            if self.activeSave?.token == activeSave.token {
                self.activeSave = nil
            }
        }
        let token = UUID()
        let task = Task { @MainActor in await operation() }
        activeSave = (token, task)
        let result = await task.value
        if activeSave?.token == token {
            activeSave = nil
        }
        return result
    }
}

@MainActor
final class CallerIdentityCoordinator {
    /// Delays before each attempt: reads at 0 s, 2 s and 5 s after capture starts.
    static let retryDelays: [Duration] = [.zero, .seconds(2), .seconds(3)]

    private let isEnabled: @MainActor () -> Bool
    private let capture: @Sendable () async -> CallerCaptureResult
    private let attach: @Sendable (CallerHandle, Int64) async -> CallerAttachResult
    private let didAttach: @MainActor (CallerAttachment) -> Void
    private let didConfirmExistingCaller: @MainActor (CallerAttachment) -> Bool
    private let rollBack: @Sendable (UUID, Int64) async -> Bool
    private let didFailRollBack: @MainActor (CallerAttachment) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var active: [ObjectIdentifier: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Serializes only the database attach and any late rollback for a meeting,
    /// so a resumed capture can read Phone immediately while writes stay ordered.
    private var meetingAttaches: [Int64: (token: UUID, task: Task<UUID?, Never>)] = [:]
    /// In-flight lookups, including retired ones still unwinding. Each removes itself when it ends.
    private var pending: [UUID: Task<Void, Never>] = [:]
    /// What each live attempt attached; handed back and dropped when it retires.
    private var attachments: [ObjectIdentifier: CallerAttachment] = [:]

    init(
        isEnabled: @escaping @MainActor () -> Bool,
        capture: @escaping @Sendable () async -> CallerCaptureResult,
        attach: @escaping @Sendable (CallerHandle, Int64) async -> CallerAttachResult,
        didAttach: @escaping @MainActor (CallerAttachment) -> Void,
        didConfirmExistingCaller: @escaping @MainActor (CallerAttachment) -> Bool = { _ in false },
        rollBack: @escaping @Sendable (UUID, Int64) async -> Bool,
        didFailRollBack: @escaping @MainActor (CallerAttachment) -> Void = { _ in },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.isEnabled = isEnabled
        self.capture = capture
        self.attach = attach
        self.didAttach = didAttach
        self.didConfirmExistingCaller = didConfirmExistingCaller
        self.rollBack = rollBack
        self.didFailRollBack = didFailRollBack
        self.sleep = sleep
    }

    func captureSucceeded(
        owner: ObjectIdentifier,
        meetingID: Int64,
        phoneAppWasFrontmost: Bool
    ) {
        guard phoneAppWasFrontmost, isEnabled(), active[owner] == nil else { return }
        let token = UUID()
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.run(owner: owner, token: token, meetingID: meetingID)
        }
        active[owner] = (token, task)
        pending[token] = task
    }

    @discardableResult
    func retire(owner: ObjectIdentifier) -> CallerAttachment? {
        active.removeValue(forKey: owner)?.task.cancel()
        return attachments.removeValue(forKey: owner)
    }

    func retireAll() -> [CallerAttachment] {
        for entry in active.values {
            entry.task.cancel()
        }
        active.removeAll()
        let retiredAttachments = Array(attachments.values)
        attachments.removeAll()
        return retiredAttachments
    }

    #if DEBUG
    var pendingLookupCount: Int { pending.count }

    /// Waits for every lookup started so far, including retired ones. Tests only.
    func settleForTesting() async {
        while let task = pending.values.first {
            await task.value
        }
    }
    #endif

    private func isCurrent(_ owner: ObjectIdentifier, _ token: UUID) -> Bool {
        !Task.isCancelled && active[owner]?.token == token
    }

    private func finish(_ owner: ObjectIdentifier, _ token: UUID) {
        if active[owner]?.token == token {
            active.removeValue(forKey: owner)
        }
    }

    private func run(owner: ObjectIdentifier, token: UUID, meetingID: Int64) async {
        defer {
            finish(owner, token)
            pending.removeValue(forKey: token)
        }
        for delay in Self.retryDelays {
            if delay > .zero {
                do { try await sleep(delay) } catch { return }
            }
            guard isCurrent(owner, token) else { return }
            let result = await capture()
            guard isCurrent(owner, token) else { return }

            switch result {
            case .identified(let handle):
                guard await attachIfCurrent(
                    handle,
                    owner: owner,
                    token: token,
                    meetingID: meetingID
                ) != nil else {
                    return
                }
                return
            case .unavailable(.noActiveCall), .unavailable(.noHandle), .unavailable(.incomplete):
                log("retry \(Self.code(result))")
                continue
            case .unavailable, .ambiguous, .permissionRequired:
                log("stop \(Self.code(result))")
                return
            }
        }
    }

    private func attachIfCurrent(
        _ handle: CallerHandle,
        owner: ObjectIdentifier,
        token: UUID,
        meetingID: Int64
    ) async -> UUID? {
        let previousTask = meetingAttaches[meetingID]?.task
        let operationToken = UUID()
        let task = Task { @MainActor [weak self] () -> UUID? in
            await previousTask?.value
            guard let self, self.isCurrent(owner, token) else { return nil }
            let outcome = await self.attach(handle, meetingID)
            self.log("attach \(Self.code(outcome))")
            let personID: UUID
            switch outcome {
            case .attached(let attachedID), .alreadyPresentCaller(let attachedID):
                personID = attachedID
            case .alreadyPresent, .suppressed, .meetingMissing, .failed:
                return nil
            }
            guard self.isCurrent(owner, token) else {
                guard case .attached = outcome else { return nil }
                // Keep the meeting's next attach behind this rollback, but let
                // its Phone snapshot run while this database operation finishes.
                self.log("rollback late attach")
                let rollbackSucceeded = await self.rollBack(personID, meetingID)
                if !rollbackSucceeded {
                    self.didFailRollBack(CallerAttachment(meetingID: meetingID, personID: personID))
                }
                return nil
            }
            let attachment = CallerAttachment(meetingID: meetingID, personID: personID)
            switch outcome {
            case .attached:
                self.attachments[owner] = attachment
                self.didAttach(attachment)
            case .alreadyPresentCaller:
                if self.didConfirmExistingCaller(attachment) {
                    self.attachments[owner] = attachment
                }
            case .alreadyPresent, .suppressed, .meetingMissing, .failed:
                break
            }
            return personID
        }
        meetingAttaches[meetingID] = (operationToken, task)
        let personID = await task.value
        if meetingAttaches[meetingID]?.token == operationToken {
            meetingAttaches[meetingID] = nil
        }
        return personID
    }

    /// Reason codes only; handles and names never reach logs.
    private func log(_ message: String) {
        fputs("[callers] \(message)\n", stderr)
    }

    private static func code(_ result: CallerCaptureResult) -> String {
        switch result {
        case .identified: return "identified"
        case .unavailable(let reason): return reason.rawValue
        case .ambiguous: return "ambiguous"
        case .permissionRequired: return "permissionRequired"
        }
    }

    private static func code(_ outcome: CallerAttachResult) -> String {
        switch outcome {
        case .attached: return "attached"
        case .alreadyPresent: return "alreadyPresent"
        case .alreadyPresentCaller: return "alreadyPresentCaller"
        case .suppressed: return "suppressed"
        case .meetingMissing: return "meetingMissing"
        case .failed: return "failed"
        }
    }
}
