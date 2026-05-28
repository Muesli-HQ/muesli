import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Pre-call briefing")
struct PreCallBriefingTests {
    @Test("briefing renders modular sections and related call history")
    func modularBriefing() {
        let event = UnifiedCalendarEvent(
            id: "evt-1",
            title: "Nina Bhatti Skriber Demo",
            startDate: Date(timeIntervalSince1970: 1_780_000_000),
            endDate: Date(timeIntervalSince1970: 1_780_003_600),
            isAllDay: false,
            source: .googleCalendar
        )
        let meetings = [
            MeetingRecord(
                id: 10,
                title: "Nina Bhatti Call",
                startTime: "2026-05-20T12:00:00Z",
                durationSeconds: 1200,
                rawTranscript: "Nina asked how do we get started and said she needs to talk to her partner.",
                formattedNotes: "## Action Items\n- Send pricing sheet today",
                wordCount: 15,
                folderID: nil,
                status: .completed
            ),
        ]
        let crmRecord = SalesCRMRecord(
            provider: .hubSpot,
            accountName: "Nina Bhatti Clinic",
            contactName: "Nina Bhatti",
            stage: "Trial",
            owner: "Kaden",
            value: "$399/mo",
            source: "Google",
            lastActivity: "Demo booked",
            openTasks: ["Confirm trial setup"],
            customFields: [:]
        )

        let briefing = SalesPreCallBriefingBuilder.build(
            event: event,
            meetings: meetings,
            modules: SalesPreCallBriefingModule.defaultModules,
            crmProvider: .hubSpot,
            crmRecord: crmRecord
        )

        #expect(briefing.crmStatus == "HubSpot record matched")
        #expect(briefing.sections.count == SalesPreCallBriefingModule.defaultModules.count)
        #expect(briefing.sections.contains { $0.title == "CRM Snapshot" && $0.bullets.contains("Stage: Trial") })
        #expect(briefing.sections.contains { $0.title == "Prior Touchpoints" && $0.body.contains("1 related") })
        #expect(briefing.sections.contains { $0.title == "Risks & Signals" && $0.bullets.contains { $0.contains("Decision-maker") } })
    }

    @Test("briefing digest prefers CRM risks and next actions")
    func compactDigest() {
        let event = UnifiedCalendarEvent(
            id: "evt-3",
            title: "Nina Bhatti Skriber Demo",
            startDate: Date(timeIntervalSince1970: 1_780_000_000),
            endDate: Date(timeIntervalSince1970: 1_780_003_600),
            isAllDay: false,
            source: .googleCalendar
        )
        let crmRecord = SalesCRMRecord(
            provider: .highLevel,
            accountName: "Nina Bhatti Clinic",
            contactName: "Nina Bhatti",
            stage: "Trial",
            owner: "Kaden",
            value: "$399/mo",
            source: "Google",
            lastActivity: "Demo booked",
            openTasks: ["Confirm trial setup"],
            customFields: [:]
        )

        let briefing = SalesPreCallBriefingBuilder.build(
            event: event,
            meetings: [],
            modules: SalesPreCallBriefingModule.defaultModules,
            crmProvider: .highLevel,
            crmRecord: crmRecord
        )
        let digest = briefing.digest(maxBullets: 4)

        #expect(digest.heading == "Pre-call brief")
        #expect(digest.status == "HighLevel record matched")
        #expect(digest.bullets.count == 4)
        #expect(digest.bullets[0] == "Account: Nina Bhatti Clinic")
        #expect(digest.bullets.contains("Stage: Trial"))
    }

    @Test("disabled modules do not render")
    func disabledModules() {
        var modules = SalesPreCallBriefingModule.defaultModules
        modules = modules.map { module in
            var copy = module
            copy.isEnabled = module.kind == .meetingOverview
            return copy
        }

        let event = UnifiedCalendarEvent(
            id: "evt-2",
            title: "Office Demo",
            startDate: Date(),
            endDate: Date().addingTimeInterval(1800),
            isAllDay: false,
            source: .eventKit
        )

        let briefing = SalesPreCallBriefingBuilder.build(
            event: event,
            meetings: [],
            modules: modules,
            crmProvider: .salesforce
        )

        #expect(briefing.sections.count == 1)
        #expect(briefing.sections.first?.title == "Meeting Overview")
        #expect(briefing.crmStatus == "Salesforce ready, no record matched")
    }
}
