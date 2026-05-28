import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Supabase sync client")
struct SupabaseSyncClientTests {
    @Test("Meeting records become Supabase meeting payloads")
    func meetingRecordsBecomeSupabasePayloads() throws {
        var config = AppConfig()
        config.supabaseWorkspaceID = "skriber-sales"
        config.salesCaddieInstallID = "install-123"
        config.supabaseUserID = "tommy"

        let meeting = MeetingRecord(
            id: 42,
            title: "Demo with Dr. Smith",
            startTime: "2026-05-27T15:00:00Z",
            durationSeconds: 1800,
            rawTranscript: "Prospect: This looks useful.",
            formattedNotes: "## Summary\nGood demo.",
            wordCount: 4,
            folderID: 9,
            calendarEventID: "cal-123",
            status: .completed,
            manualNotes: "Follow up Friday",
            selectedTemplateID: "sales",
            selectedTemplateName: "Sales Call",
            selectedTemplateKind: .custom,
            selectedTemplatePrompt: "Summarize sales call",
            source: .meeting
        )

        let record = try SupabaseMeetingRecord.record(from: meeting, config: config)

        #expect(record.id == SupabaseSyncClient.stableUUIDString(seed: "meeting|skriber-sales|install-123|42"))
        #expect(record.workspaceID == "skriber-sales")
        #expect(record.localID == "42")
        #expect(record.appInstallID == "install-123")
        #expect(record.userID == "tommy")
        #expect(record.startedAt.hasPrefix("2026-05-27T15:00:00"))
        #expect(record.endedAt?.hasPrefix("2026-05-27T15:30:00") == true)
        #expect(record.metadata["status"] == "completed")
        #expect(record.metadata["calendar_event_id"] == "cal-123")
        #expect(record.metadata["manual_notes"] == "Follow up Friday")
        #expect(record.metadata["template_kind"] == "custom")
    }

    @Test("Stable UUID strings are deterministic and uuid-shaped")
    func stableUUIDStringsAreDeterministic() {
        let first = SupabaseSyncClient.stableUUIDString(seed: "meeting|workspace|install|42")
        let second = SupabaseSyncClient.stableUUIDString(seed: "meeting|workspace|install|42")
        let different = SupabaseSyncClient.stableUUIDString(seed: "meeting|workspace|install|43")

        #expect(first == second)
        #expect(first != different)
        #expect(first.count == 36)
        #expect(first[first.index(first.startIndex, offsetBy: 14)] == "5")
    }

    @Test("Sales assist alerts become call insight payloads")
    func salesAssistAlertsBecomeCallInsights() throws {
        var config = AppConfig()
        config.supabaseWorkspaceID = "skriber-sales"
        config.salesCaddieInstallID = "install-123"
        config.supabaseUserID = "kaden"

        let alert = SalesAssistAlert(
            kind: "objection",
            objection: "Card resistance",
            quote: "Prospect: Why do you need my card?",
            talkTrack: "Explain nothing bills during trial.",
            priority: "high",
            updatedAt: Date(timeIntervalSince1970: 1_779_900_000)
        )

        let record = try SupabaseCallInsightRecord.record(from: alert, localMeetingID: 42, config: config)

        #expect(record.workspaceID == "skriber-sales")
        #expect(record.appInstallID == "install-123")
        #expect(record.userID == "kaden")
        #expect(record.kind == "objection")
        #expect(record.name == "Card resistance")
        #expect(record.metadata["local_meeting_id"] == "42")
        #expect(record.metadata["priority"] == "high")
    }

    @Test("Sales library records become local library snapshot")
    func salesLibraryRecordsBecomeSnapshot() {
        let records = [
            SupabaseSalesLibraryItem(
                id: "11111111-1111-1111-1111-111111111111",
                workspaceID: "skriber-sales",
                kind: "knowledge_base",
                name: "Core KB",
                content: "Skriber sells to small practices.",
                triggerPhrases: [],
                guidance: "",
                priority: 1,
                isEnabled: true,
                updatedAt: "2026-05-27T12:00:00.000Z"
            ),
            SupabaseSalesLibraryItem(
                id: "22222222-2222-2222-2222-222222222222",
                workspaceID: "skriber-sales",
                kind: "objection",
                name: "Too expensive",
                content: "",
                triggerPhrases: ["too expensive", "costs too much"],
                guidance: "Anchor to saved charting time.",
                priority: 2,
                isEnabled: true,
                updatedAt: "2026-05-27T12:01:00.000Z"
            ),
            SupabaseSalesLibraryItem(
                id: "33333333-3333-3333-3333-333333333333",
                workspaceID: "skriber-sales",
                kind: "battlecard",
                name: "Nabla Battlecard",
                content: "",
                triggerPhrases: ["Nabla"],
                guidance: "Ask where Nabla still needs cleanup.",
                priority: 1,
                isEnabled: true,
                updatedAt: "2026-05-27T12:02:00.000Z"
            ),
        ]

        let snapshot = SupabaseSalesLibraryItem.snapshot(from: records)

        #expect(snapshot.knowledgeBase == "Skriber sells to small practices.")
        #expect(snapshot.objections.count == 1)
        #expect(snapshot.objections[0].priority == "high")
        #expect(snapshot.objections[0].triggerPhrases == "too expensive\ncosts too much")
        #expect(snapshot.liveCues.count == 1)
        #expect(snapshot.liveCues[0].kind == "competitor")
        #expect(snapshot.updatedAt == "2026-05-27T12:02:00.000Z")
    }

    @Test("Local sales library becomes Supabase records")
    func localSalesLibraryBecomesSupabaseRecords() throws {
        var config = AppConfig()
        config.supabaseWorkspaceID = "skriber-sales"
        config.salesAssistKnowledgeBaseItemID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        config.salesAssistKnowledgeBase = "Core product notes"
        config.salesAssistObjections = [
            SalesAssistObjection(
                id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                name: "Timing",
                priority: "low",
                triggerPhrases: "not now\nnext month",
                guidance: "Ask what changes next month."
            ),
        ]
        config.salesAssistLiveCues = [
            SalesAssistLiveCue(
                id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
                kind: "buying_signal",
                name: "Ready",
                priority: "high",
                triggerPhrases: "let's do it",
                guidance: "Start setup."
            ),
        ]

        let records = try SupabaseSalesLibraryItem.records(from: config)

        #expect(records.map(\.kind) == ["knowledge_base", "objection", "buying_signal"])
        #expect(records[0].workspaceID == "skriber-sales")
        #expect(records[1].priority == -1)
        #expect(records[1].triggerPhrases == ["not now", "next month"])
        #expect(records[2].priority == 2)
    }
}
