import EventKit
import Testing
@testable import MuesliNativeApp

@Suite("Calendar permission recovery")
@MainActor
struct CalendarPermissionStateTests {
    @Test("An empty calendar snapshot stays loading until its first read completes")
    func initialCalendarRead() {
        var refresh = CalendarSourceRefreshState()
        #expect(refresh.isLoading)
        #expect(refresh.needsInitialRefresh)
        refresh.begin()
        #expect(refresh.isLoading)
        #expect(!refresh.needsInitialRefresh)
        refresh.finish(completed: true)
        #expect(!refresh.isLoading)
        #expect(!refresh.needsInitialRefresh)
    }

    @Test("A refresh after granting access hides the old empty snapshot until completion")
    func refreshAfterGrant() {
        var refresh = CalendarSourceRefreshState()
        refresh.begin()
        refresh.finish(completed: true)
        refresh.begin()
        #expect(refresh.hasLoaded)
        #expect(refresh.isLoading)
        refresh.finish(completed: true)
        #expect(!refresh.isLoading)
    }

    @Test("Overlapping reads stay loading until every Settings refresh completes")
    func overlappingCalendarReads() {
        var refresh = CalendarSourceRefreshState()
        refresh.begin()
        refresh.begin()
        refresh.finish(completed: true)
        #expect(refresh.isLoading)
        refresh.finish(completed: true)
        #expect(!refresh.isLoading)
    }

    @Test("A cancelled first read can retry without treating its snapshot as an empty result")
    func cancelledCalendarRead() {
        var refresh = CalendarSourceRefreshState()
        refresh.begin()
        refresh.finish(completed: false)
        #expect(refresh.isLoading)
        #expect(refresh.needsInitialRefresh)
    }

    @MainActor
    private final class Harness {
        var status: EKAuthorizationStatus = .notDetermined
        var requests = 0
        lazy var permission = CalendarPermissionState(
            readStatus: { self.status },
            requestFullAccess: {
                self.requests += 1
                self.status = .fullAccess
                return true
            }
        )
    }

    @Test("Displaying or refreshing a skipped permission never prompts")
    func skippedPermission() {
        let h = Harness()
        h.permission.refresh()
        #expect(h.permission.canRequest)
        #expect(!h.permission.granted)
        #expect(h.requests == 0)
    }

    @Test("An explicit request grants access immediately")
    func grantAfterSkippingOnboarding() async {
        let h = Harness()
        await h.permission.requestAccess()
        #expect(h.requests == 1)
        #expect(h.permission.granted)
        #expect(!h.permission.requesting)
        #expect(h.permission.errorMessage == nil)
    }

    @Test("Denied, restricted, or write-only permissions require Privacy Settings",
          arguments: [EKAuthorizationStatus.denied, .restricted, .writeOnly])
    func requiresPrivacySettings(status: EKAuthorizationStatus) async {
        let h = Harness()
        h.status = status
        #expect(!h.permission.canRequest)
        #expect(!h.permission.granted)
        await h.permission.requestAccess()
        #expect(h.requests == 0)
    }

    @Test("Returning from Privacy Settings observes both grants and revocations",
          arguments: [EKAuthorizationStatus.fullAccess, .authorized])
    func externalPermissionChange(grantedStatus: EKAuthorizationStatus) {
        let h = Harness()
        _ = h.permission
        h.status = grantedStatus
        h.permission.refresh()
        #expect(h.permission.granted)
        h.status = .denied
        h.permission.refresh()
        #expect(!h.permission.granted)
        #expect(!h.permission.canRequest)
        #expect(h.requests == 0)
    }

    @Test("A refused system prompt updates the action to Privacy Settings")
    func refusedPrompt() async {
        let h = Harness()
        let permission = CalendarPermissionState(readStatus: { h.status }, requestFullAccess: {
            h.status = .denied
            return false
        })
        await permission.requestAccess()
        #expect(!permission.granted)
        #expect(!permission.canRequest)
        #expect(!permission.requesting)
    }

    @Test("Request errors clear the busy state and can recover after an external grant")
    func requestFailure() async {
        struct RequestError: Error {}
        let h = Harness()
        let permission = CalendarPermissionState(readStatus: { h.status }, requestFullAccess: {
            throw RequestError()
        })
        await permission.requestAccess()
        #expect(!permission.requesting)
        #expect(permission.errorMessage != nil)
        h.status = .fullAccess
        permission.refresh()
        #expect(permission.granted)
        #expect(permission.errorMessage == nil)
    }

    @Test("Repeated clicks while a prompt is pending only request once")
    func repeatedRequests() async {
        let h = Harness()
        var pending: CheckedContinuation<Bool, Never>?
        let permission = CalendarPermissionState(readStatus: { h.status }, requestFullAccess: {
            h.requests += 1
            return await withCheckedContinuation { pending = $0 }
        })
        let task = Task { await permission.requestAccess() }
        while pending == nil { await Task.yield() }
        #expect(permission.requesting)
        await permission.requestAccess()
        #expect(h.requests == 1)
        h.status = .fullAccess
        pending?.resume(returning: true)
        await task.value
        #expect(permission.granted)
        #expect(!permission.requesting)
    }
}
