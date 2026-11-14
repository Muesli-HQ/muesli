import ApplicationServices
import Testing
@testable import MuesliNativeApp

@Suite("Browser automation permission")
struct BrowserAutomationPermissionTests {
    @Test("macOS statuses map to the four consent states")
    func statusMapping() {
        #expect(BrowserAutomationPermission.state(forStatus: noErr) == .granted)
        #expect(BrowserAutomationPermission.state(forStatus: OSStatus(errAEEventNotPermitted)) == .denied)
        #expect(BrowserAutomationPermission.state(forStatus: OSStatus(errAEEventWouldRequireUserConsent)) == .undetermined)
        #expect(BrowserAutomationPermission.state(forStatus: OSStatus(procNotFound)) == .unavailable)
    }
}
