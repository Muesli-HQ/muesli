import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("Meeting recovery deadlines")
struct MeetingAudioRecoveryDeadlinesTests {
    @Test("ordinary recording schedules nothing; route bursts share a finite window")
    func finiteEventWindow() {
        var scheduled: [(TimeInterval, DispatchWorkItem)] = []
        var checks: [Bool] = []
        let deadlines = MeetingAudioRecoveryDeadlines(
            offsets: [3, 8, 20], scheduler: { scheduled.append(($0, $1)) },
            check: { checks.append($0) }
        )
        #expect(scheduled.isEmpty)
        deadlines.arm()
        for _ in 0..<100 { deadlines.arm() }
        #expect(scheduled.count == 1)
        scheduled[0].1.perform()
        deadlines.arm()
        #expect(scheduled.count == 2)
        scheduled[1].1.perform()
        scheduled[2].1.perform()
        #expect(scheduled.map(\.0) == [3, 5, 12])
        #expect(checks == [false, false, true])
        #expect(scheduled.count == 3)
        deadlines.arm()
        #expect(scheduled.count == 4)
        deadlines.cancel()
    }

    @Test("cancel rejects late deadlines and allows a fresh event window")
    func cancelledDeadlineCannotAffectNewWindow() {
        var scheduled: [DispatchWorkItem] = []
        var checks = 0
        let deadlines = MeetingAudioRecoveryDeadlines(
            scheduler: { _, item in scheduled.append(item) }, check: { _ in checks += 1 }
        )
        deadlines.arm()
        let stale = scheduled[0]
        deadlines.cancel()
        deadlines.arm()
        stale.perform()
        #expect(checks == 0)
        #expect(scheduled.count == 2)
        scheduled[1].perform()
        #expect(checks == 1)
        deadlines.cancel()
    }
}
