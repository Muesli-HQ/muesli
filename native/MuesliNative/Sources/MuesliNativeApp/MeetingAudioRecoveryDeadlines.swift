import Foundation

/// A finite set of checks after positive route/failure evidence. No idle timer,
/// HAL inspection or per-buffer work. Bursts share the original window so a
/// noisy driver cannot turn this into perpetual polling.
final class MeetingAudioRecoveryDeadlines: @unchecked Sendable {
    typealias Scheduler = (TimeInterval, DispatchWorkItem) -> Void
    private let lock = NSLock()
    private let offsets: [TimeInterval]
    private let schedule: Scheduler
    private let check: (Bool) -> Void
    private var generation = 0
    private var pending: DispatchWorkItem?

    init(
        offsets: [TimeInterval] = [3, 8, 20, 40, 60],
        scheduler: Scheduler? = nil,
        check: @escaping (Bool) -> Void
    ) {
        precondition(!offsets.isEmpty && offsets[0] > 0)
        precondition(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
        self.offsets = offsets
        self.check = check
        let queue = DispatchQueue(label: "com.muesli.meeting-recovery-deadline")
        self.schedule = scheduler ?? { delay, item in
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    func arm() {
        lock.lock()
        guard pending == nil else { lock.unlock(); return }
        generation += 1
        let token = generation
        let item = makeItem(index: 0, token: token)
        pending = item
        lock.unlock()
        schedule(offsets[0], item)
    }

    func cancel() {
        lock.withLock {
            generation += 1
            pending?.cancel()
            pending = nil
        }
    }

    private func makeItem(index: Int, token: Int) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in self?.fire(index: index, token: token) }
    }

    private func fire(index: Int, token: Int) {
        lock.lock()
        guard generation == token, pending != nil else { lock.unlock(); return }
        let final = index == offsets.count - 1
        lock.unlock()
        check(final)
        lock.lock()
        guard generation == token else { lock.unlock(); return }
        if final {
            pending = nil
            lock.unlock()
        } else {
            let item = makeItem(index: index + 1, token: token)
            pending = item
            lock.unlock()
            schedule(offsets[index + 1] - offsets[index], item)
        }
    }
}
