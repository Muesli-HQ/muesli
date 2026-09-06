import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("ControlCenterSensorAttributionMonitor")
struct ControlCenterSensorAttributionMonitorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("parses active mic and camera bundle attributions")
    func parsesActiveMicAndCameraBundleAttributions() {
        let snapshot = ControlCenterSensorAttributionMonitor.parseSnapshot(
            from: #"2026-05-01 ControlCenter[695] [com.apple.controlcenter:sensor-indicators] Active activity attributions changed to ["cam:com.google.Chrome", "mic:com.google.Chrome"]"#,
            now: now
        )

        #expect(snapshot?.micBundleIDs == ["com.google.Chrome"])
        #expect(snapshot?.cameraBundleIDs == ["com.google.Chrome"])
        #expect(snapshot?.observedAt == now)
    }

    @Test("parses empty active attribution list")
    func parsesEmptyActiveAttributionList() {
        let snapshot = ControlCenterSensorAttributionMonitor.parseSnapshot(
            from: #"2026-05-01 ControlCenter[695] [com.apple.controlcenter:sensor-indicators] Active activity attributions changed to []"#,
            now: now
        )

        #expect(snapshot?.micBundleIDs.isEmpty == true)
        #expect(snapshot?.cameraBundleIDs.isEmpty == true)
        #expect(snapshot?.observedAt == now)
    }

    @Test("active attribution persists until an explicit clear or stream stop")
    func activeAttributionPersistsUntilCleared() throws {
        let active = try #require(ControlCenterSensorAttributionMonitor.parseSnapshot(
            from: #"2026-05-01 ControlCenter[695] [com.apple.controlcenter:sensor-indicators] Active activity attributions changed to ["cam:com.google.Chrome", "mic:com.google.Chrome"]"#,
            now: now
        ))
        let monitor = ControlCenterSensorAttributionMonitor(initialSnapshot: active)

        #expect(monitor.snapshot() == active)

        monitor.stop()
        #expect(monitor.snapshot() == .empty)
    }

    @Test("ignores unrelated sensor log lines")
    func ignoresUnrelatedSensorLogLines() {
        let snapshot = ControlCenterSensorAttributionMonitor.parseSnapshot(
            from: #"2026-05-01 ControlCenter[695] [com.apple.controlcenter:sensor-indicators] Recent activity attributions changed to ["mic:com.google.Chrome"]"#,
            now: now
        )

        #expect(snapshot == nil)
    }
}
