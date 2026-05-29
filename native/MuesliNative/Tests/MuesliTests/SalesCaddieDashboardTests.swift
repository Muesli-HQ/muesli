import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Sales Caddie dashboard")
struct SalesCaddieDashboardTests {
    @Test("health snapshot requires enabled monitors to be running")
    func healthSnapshotMonitorReadiness() {
        let ready = SalesCaddieHealthSnapshot(
            microphoneGranted: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true,
            screenRecordingGranted: false,
            dictationShortcutEnabled: false,
            dictationMonitorRunning: false,
            computerUseShortcutEnabled: true,
            computerUseMonitorRunning: true,
            jessicaShortcutEnabled: true,
            jessicaMonitorRunning: true,
            meetingShortcutEnabled: true,
            meetingMonitorRunning: true,
            salesAssistEnabled: true,
            salesAssistAIEnabled: true,
            salesAgentProvider: "Hosted Jessica",
            cloudSyncEnabled: true,
            supabaseSyncEnabled: false,
            syncMode: "Hosted API",
            workspaceLabel: "skriber-sales",
            userLabel: "Michael",
            libraryUpdatedAt: "2026-05-28T12:00:00Z"
        )
        #expect(ready.allEnabledMonitorsRunning)
        #expect(ready.readyForLiveSalesAssist)
        #expect(ready.anyCloudSyncEnabled)

        var broken = ready
        broken.jessicaMonitorRunning = false
        #expect(!broken.allEnabledMonitorsRunning)
        #expect(broken.readyForLiveSalesAssist)
    }

    @Test("call review summarizes recent sales-call signals")
    func callReviewSummary() {
        let now = ISO8601DateFormatter().date(from: "2026-05-26T12:00:00Z")!
        let meetings = [
            meeting(
                id: 1,
                start: "2026-05-25T12:00:00Z",
                duration: 1800,
                transcript: "How do we get started? What are you using today? We use Freed but this could work. This should save time in our documentation workflow.",
                notes: """
                ## Meeting Summary
                Good call

                ## Action Items
                - Send pricing sheet today
                - Schedule follow-up Friday
                """
            ),
            meeting(
                id: 2,
                start: "2026-05-20T12:00:00Z",
                duration: 900,
                transcript: "I need to talk to my wife and think about it.",
                notes: "## Raw Transcript\nFallback"
            ),
            meeting(
                id: 3,
                start: "2026-04-01T12:00:00Z",
                duration: 900,
                transcript: "Old call with Suki.",
                notes: "## Meeting Summary\nOld"
            ),
        ]

        let summary = SalesCallReviewAnalyzer.summarize(meetings: meetings, now: now)

        #expect(summary.completedCalls == 2)
        #expect(summary.totalMinutes == 45)
        #expect(summary.averageMinutes == 22)
        #expect(summary.structuredNotes == 1)
        #expect(summary.rawTranscriptFallbacks == 1)
        #expect(summary.structuredNoteRate == 50)
        #expect(summary.competitorMentions == 1)
        #expect(summary.buyingSignalMentions == 2)
        #expect(summary.objectionMentions == 2)
        #expect(summary.actionItems.count >= 2)
        #expect(summary.actionItems.contains { $0.title.contains("Send pricing") })
        #expect(summary.callInsights.contains { $0.kind == "competitor" })
        #expect(summary.callInsights.contains { $0.kind == "buying_signal" })
        #expect(summary.callInsights.contains { $0.kind == "objection" })
        #expect(summary.callInsights.contains { $0.kind == "action_item" })
        #expect(summary.scorecards.count == 2)
        #expect(summary.averageSalesScore > 0)
        #expect(summary.followUpDrafts.first?.body.contains("Next step") == true)
        #expect(summary.crmNoteDrafts.first?.note.contains("Sales score") == true)
        #expect(!summary.coachingThemes.isEmpty)
        #expect(!summary.customerMemories.isEmpty)
    }

    @Test("live overlay detector returns multiple prioritized cues")
    func liveOverlayDetectsMultipleCues() {
        var config = AppConfig()
        config.salesAssistEnabledKinds = SalesAssistLiveCue.supportedKinds
        let detector = SalesAssistDetector()

        let alerts = detector.detectAlerts(
            lines: [
                "Prospect: I like this. How do we get started with the trial? I need to talk to my wife because we already use Freed.",
            ],
            config: config
        )

        #expect(alerts.count >= 2)
        #expect(alerts.first?.priority == "high")
        #expect(alerts.contains { $0.kind == "close" || $0.kind == "buying_signal" })
        #expect(alerts.contains { $0.kind == "objection" || $0.kind == "competitor" })
    }

    @Test("live overlay ignores weak or rep-side objection language")
    func liveOverlayIgnoresWeakOrRepSideLanguage() {
        var config = AppConfig()
        config.salesAssistEnabledKinds = SalesAssistLiveCue.supportedKinds
        let detector = SalesAssistDetector()

        let weakProspectAlerts = detector.detectAlerts(
            lines: [
                "Prospect: I was just looking at the notes and the magic edit routing.",
            ],
            config: config
        )
        let repSideAlerts = detector.detectAlerts(
            lines: [
                "Rep: Yeah, consider those paid for and then we can look at the notes.",
            ],
            config: config
        )

        #expect(weakProspectAlerts.isEmpty)
        #expect(repSideAlerts.isEmpty)
    }

    @MainActor
    @Test("sales assist engine buffers transcript and suppresses dismissed cues")
    func salesAssistEngineBuffersAndSuppresses() {
        var config = AppConfig()
        config.salesAssistEnabled = true
        config.salesAssistAIEnabled = false
        config.salesAssistEnabledKinds = SalesAssistLiveCue.supportedKinds
        var emitted: [SalesAssistAlert] = []
        var visible: [[SalesAssistAlert]] = []
        let engine = SalesAssistEngine(
            configProvider: { config },
            alertHandler: { emitted.append($0) },
            activeAlertsChanged: { visible.append($0) }
        )

        engine.handleTranscriptLine("Prospect: I like this. How do we get started with the trial?")

        #expect(emitted.contains { $0.kind == "close" || $0.kind == "buying_signal" })
        let firstVisible = try? #require(visible.last?.first)
        if let firstVisible {
            _ = engine.handleAction(.dismiss, for: firstVisible)
            let emissionCount = emitted.count
            engine.handleTranscriptLine("Prospect: I like this. How do we get started with the trial?")
            #expect(emitted.count == emissionCount)
            #expect(visible.last?.isEmpty == true)
        }
    }

    private func meeting(
        id: Int64,
        start: String,
        duration: Double,
        transcript: String,
        notes: String
    ) -> MeetingRecord {
        MeetingRecord(
            id: id,
            title: "Call \(id)",
            startTime: start,
            durationSeconds: duration,
            rawTranscript: transcript,
            formattedNotes: notes,
            wordCount: transcript.split(separator: " ").count,
            folderID: nil,
            status: .completed
        )
    }
}
