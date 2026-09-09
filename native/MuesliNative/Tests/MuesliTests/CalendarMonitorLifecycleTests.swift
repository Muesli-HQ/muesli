import EventKit
import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Calendar monitor authorization and lifecycle")
@MainActor
struct CalendarMonitorLifecycleTests {
    @MainActor
    private final class Harness {
        let store = EKEventStore()
        let center = NotificationCenter()
        var status: EKAuthorizationStatus = .fullAccess
        var callbacks: [@Sendable (Bool, Error?) -> Void] = []
        var changes = 0
        lazy var monitor = CalendarMonitor(
            store: store,
            authorizationStatus: { [weak self] in self?.status ?? .denied },
            requestAccess: { [weak self] in self?.callbacks.append($0) },
            notificationCenter: center
        )
        func postChange() { center.post(name: .EKEventStoreChanged, object: store) }
        func drainCallbacks() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @Test("without read access start never prompts and can start after a grant",
          arguments: [EKAuthorizationStatus.notDetermined, .restricted, .denied, .writeOnly])
    func deniedThenGranted(status: EKAuthorizationStatus) async {
        let h = Harness()
        h.status = status
        h.monitor.onCalendarChanged = { [weak h] in h?.changes += 1 }
        h.monitor.start()
        h.monitor.start()
        h.postChange()
        #expect(h.callbacks.isEmpty)
        #expect(h.changes == 0)
        h.status = .fullAccess
        h.monitor.start()
        #expect(h.callbacks.count == 1)
        h.callbacks[0](true, nil)
        await h.drainCallbacks()
        h.postChange()
        #expect(h.changes == 1)
        h.monitor.stop()
    }

    @Test("repeated starts do bounded work and stop removes the observer")
    func repeatedStartAndStop() async {
        let h = Harness()
        h.monitor.onCalendarChanged = { [weak h] in h?.changes += 1 }
        h.monitor.start()
        h.monitor.start()
        #expect(h.callbacks.count == 1)
        h.callbacks[0](true, nil)
        await h.drainCallbacks()
        h.monitor.start()
        h.postChange()
        #expect(h.callbacks.count == 1)
        #expect(h.changes == 1)
        h.monitor.stop()
        h.postChange()
        #expect(h.changes == 1)
    }

    @Test("a stale callback cannot restart a stopped or newer monitor")
    func staleCallback() async {
        let h = Harness()
        h.monitor.onCalendarChanged = { [weak h] in h?.changes += 1 }
        h.monitor.start()
        h.monitor.stop()
        h.monitor.start()
        #expect(h.callbacks.count == 2)
        h.callbacks[0](true, nil)
        await h.drainCallbacks()
        h.postChange()
        #expect(h.changes == 0)
        h.callbacks[1](true, nil)
        await h.drainCallbacks()
        h.postChange()
        #expect(h.changes == 1)
        h.monitor.stop()
    }

    @Test("failed or revoked access does not register and permits a later retry",
          arguments: [false, true])
    func failedOrRevoked(revoked: Bool) async {
        let h = Harness()
        h.monitor.onCalendarChanged = { [weak h] in h?.changes += 1 }
        h.monitor.start()
        if revoked { h.status = .denied }
        h.callbacks[0](revoked, nil)
        await h.drainCallbacks()
        h.postChange()
        #expect(h.changes == 0)
        h.status = .fullAccess
        h.monitor.start()
        #expect(h.callbacks.count == 2)
        h.callbacks[1](true, nil)
        await h.drainCallbacks()
        h.postChange()
        #expect(h.changes == 1)
        h.monitor.stop()
    }
}
