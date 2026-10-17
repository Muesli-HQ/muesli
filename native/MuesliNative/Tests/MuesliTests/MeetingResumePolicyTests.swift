import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting resume policy")
struct MeetingResumePolicyTests {
    @Test("a completed meeting can be resumed regardless of age")
    func completedCanResumeRegardlessOfAge() {
        #expect(MeetingResumePolicy.canResume(status: .completed))
    }

    @Test("non-completed meetings cannot be resumed")
    func nonCompletedCannotResume() {
        for status in [MeetingStatus.recording, .processing, .noteOnly, .failed] {
            #expect(!MeetingResumePolicy.canResume(status: status))
        }
    }

    @Test("combined transcript keeps the prior text and appends the new with a separator")
    func combinedTranscriptAppends() {
        let combined = MeetingResumePolicy.combinedResumeTranscript(prior: "first half", new: "second half")
        #expect(combined == "first half\(MeetingResumePolicy.resumeSeparator)second half")
        #expect(combined.contains("first half"))
        #expect(combined.contains("second half"))
    }

    @Test("combined transcript returns the prior unchanged when nothing new was captured")
    func combinedTranscriptNoNewContent() {
        #expect(MeetingResumePolicy.combinedResumeTranscript(prior: "only half", new: "   \n ") == "only half")
        #expect(MeetingResumePolicy.combinedResumeTranscript(prior: "only half", new: "") == "only half")
    }

    @Test("combined transcript returns new content without a separator when prior is empty")
    func combinedTranscriptEmptyPrior() {
        #expect(MeetingResumePolicy.combinedResumeTranscript(prior: "", new: "new segment") == "new segment")
        #expect(MeetingResumePolicy.combinedResumeTranscript(prior: "   \n", new: "new segment") == "new segment")
    }

    @Test("resume summary regeneration is skipped when transcript is unchanged")
    func hasNewTranscriptContentOnlyWhenResumeAddsText() {
        #expect(!MeetingResumePolicy.hasNewTranscriptContent(prior: "only half", new: "   \n "))
        #expect(!MeetingResumePolicy.hasNewTranscriptContent(prior: "", new: ""))
        #expect(MeetingResumePolicy.hasNewTranscriptContent(prior: "first half", new: "second half"))
        #expect(MeetingResumePolicy.hasNewTranscriptContent(prior: "", new: "new segment"))
    }

    @Test("no-op resume marks notes stale when transcript sanitation changes saved text")
    func noOpResumeSummaryFreshnessRequiresSavedTranscriptMatch() {
        #expect(MeetingResumePolicy.summaryIsCurrentAfterNoOpResume(
            existingSummaryIsStale: false,
            savedTranscript: "[00:00:01] Example (You): Earlier words",
            resumedTranscript: "[00:00:01] Microphone: Earlier words"
        ) == false)
        #expect(MeetingResumePolicy.summaryIsCurrentAfterNoOpResume(
            existingSummaryIsStale: false,
            savedTranscript: "Earlier words",
            resumedTranscript: "Earlier words"
        ) == true)
        #expect(MeetingResumePolicy.summaryIsCurrentAfterNoOpResume(
            existingSummaryIsStale: true,
            savedTranscript: "Earlier words",
            resumedTranscript: "Earlier words"
        ) == false)
        #expect(MeetingResumePolicy.summaryIsCurrentAfterNoOpResume(
            existingSummaryIsStale: nil,
            savedTranscript: "Earlier words",
            resumedTranscript: "Earlier words"
        ) == nil)
    }

    @Test("combined visual context keeps both sides with a separator")
    func combinedVisualContextAppends() {
        let combined = MeetingResumePolicy.combinedResumeVisualContext(
            prior: "[10:00:00] Safari:\nfirst capture",
            new: "[10:30:00] Zoom:\nsecond capture"
        )
        #expect(combined == "[10:00:00] Safari:\nfirst capture\(MeetingResumePolicy.resumeSeparator)[10:30:00] Zoom:\nsecond capture")
    }

    @Test("combined visual context preserves the surviving side when the other is missing")
    func combinedVisualContextOneSided() {
        #expect(MeetingResumePolicy.combinedResumeVisualContext(prior: "prior capture", new: nil) == "prior capture")
        #expect(MeetingResumePolicy.combinedResumeVisualContext(prior: "prior capture", new: "  \n") == "prior capture")
        #expect(MeetingResumePolicy.combinedResumeVisualContext(prior: nil, new: "new capture") == "new capture")
        #expect(MeetingResumePolicy.combinedResumeVisualContext(prior: "", new: "new capture") == "new capture")
    }

    @Test("combined visual context is nil when neither side captured anything")
    func combinedVisualContextBothEmpty() {
        #expect(MeetingResumePolicy.combinedResumeVisualContext(prior: nil, new: nil) == nil)
        #expect(MeetingResumePolicy.combinedResumeVisualContext(prior: " ", new: "") == nil)
    }

    @Test("combined visual context is capped by dropping the oldest prior content")
    func combinedVisualContextCapped() {
        let prior = String(repeating: "p", count: MeetingResumePolicy.combinedVisualContextLimit)
        let new = String(repeating: "n", count: 5000)
        let combined = MeetingResumePolicy.combinedResumeVisualContext(prior: prior, new: new)
        #expect(combined?.count == MeetingResumePolicy.combinedVisualContextLimit)
        #expect(combined?.hasSuffix(new) == true)
        #expect(combined?.hasPrefix("p") == true)
    }

    private func makeResult(start: Date, end: Date) -> MeetingSessionResult {
        MeetingSessionResult(
            title: "M",
            originalTitle: "M",
            calendarEventID: nil,
            startTime: start,
            endTime: end,
            durationSeconds: end.timeIntervalSince(start),
            rawTranscript: "new segment",
            formattedNotes: "notes",
            retainedRecordingURL: nil,
            retainedRecordingError: nil,
            systemRecordingURL: nil,
            templateSnapshot: MeetingTemplates.auto.snapshot
        )
    }

    @Test("resume override preserves the original start and accumulates recorded duration")
    func resumeOverridePreservesOriginalStartAndAccumulatedDuration() {
        let originalStart = Date(timeIntervalSince1970: 1_000_000)
        let resumeStart = originalStart.addingTimeInterval(3600)      // resumed 1h later
        let resumeEnd = resumeStart.addingTimeInterval(30)            // recorded 30s
        let resumed = makeResult(start: resumeStart, end: resumeEnd)

        let merged = resumed.overriding(
            startTime: originalStart,
            durationSeconds: 180 + resumed.durationSeconds,
            rawTranscript: "old\(MeetingResumePolicy.resumeSeparator)new",
            formattedNotes: "merged"
        )

        #expect(merged.startTime == originalStart)                    // original date preserved, not the resume moment
        #expect(merged.endTime == resumeEnd)                          // end is the resumed stop
        #expect(merged.durationSeconds == 210)                         // recorded duration, not wall-clock gap
        #expect(merged.rawTranscript == "old\(MeetingResumePolicy.resumeSeparator)new")
        #expect(merged.formattedNotes == "merged")
    }

    @Test("override without a start time leaves timing untouched")
    func overrideWithoutStartKeepsTiming() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let result = makeResult(start: start, end: start.addingTimeInterval(45))

        let overridden = result.overriding(rawTranscript: "z", formattedNotes: "w")

        #expect(overridden.startTime == start)
        #expect(overridden.durationSeconds == 45)
        #expect(overridden.rawTranscript == "z")
    }

    @Test("resume overrides preserve or explicitly replace summary freshness")
    func overrideCarriesSummaryFreshness() {
        var result = makeResult(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 2))
        result.summaryIsCurrent = false
        #expect(result.overriding(rawTranscript: "same", formattedNotes: "notes").summaryIsCurrent == false)
        #expect(result.overriding(rawTranscript: "same", formattedNotes: "notes", summaryIsCurrent: true).summaryIsCurrent == true)
        #expect(result.overriding(rawTranscript: "same", formattedNotes: "notes", summaryIsCurrent: false).summaryIsCurrent == false)
    }

    @Test("resume removes automatic prior names only when structured state matches")
    func resumeRemovesOnlyMatchingAutomaticNames() {
        let epoch = UUID()
        let owner = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "owner")
        let guest = MeetingSpeakerKey(epoch: epoch, channel: .system, clusterID: "guest")
        var state = MeetingSpeakerState(epoch: epoch,
            speakers: [
                .init(key: owner, rank: 1, fallbackLabel: "Microphone"),
                .init(key: guest, rank: 2, fallbackLabel: "Speaker 1",
                      assignment: .init(name: "Guest", provenance: .accessibility)),
            ],
            turns: [
                .init(speaker: owner, timestamp: "00:00:01", start: 1, end: 2, text: "Owner words"),
                .init(speaker: guest, timestamp: "00:00:03", start: 3, end: 4, text: "Guest words"),
            ])
        state.applySelfEvidence(accessibility: [], voice: [owner], ownerName: "Example", profileID: UUID())
        let named = state.render()

        let safe = MeetingResumePolicy.resumeTranscriptWithoutAutomaticNames(named, speakerState: state)
        #expect(safe == "[00:00:01] Microphone: Owner words\n[00:00:03] Speaker 1: Guest words")
        let edited = "User-edited words that no longer match structured state"
        #expect(MeetingResumePolicy.resumeTranscriptWithoutAutomaticNames(edited, speakerState: state) == edited)
    }

    @Test("resumed current speaker evidence is retained and can revoke the full transcript")
    func resumedSpeakerEvidenceRemainsRevocable() {
        let epoch = UUID(), token = UUID()
        let owner = MeetingSpeakerKey(epoch: epoch, channel: .microphone, clusterID: "resumed_owner")
        var currentState = MeetingSpeakerState(epoch: epoch,
            speakers: [.init(key: owner, rank: 1, fallbackLabel: "Microphone")],
            turns: [.init(speaker: owner, timestamp: "10:30:00", start: 0, end: 2, text: "Continued words")])
        currentState.applySelfEvidence(accessibility: [], voice: [owner], ownerName: "Example", profileID: UUID())
        let currentTranscript = currentState.render()
        let priorTranscript = "[10:00:00] Speaker 1: Earlier words"
        let safeCurrent = "[10:30:00] Microphone: Continued words"
        let safeCombined = priorTranscript + MeetingResumePolicy.resumeSeparator + safeCurrent
        let combinedState = MeetingResumePolicy.speakerStateForResume(
            priorTranscript: priorTranscript,
            currentTranscript: currentTranscript,
            currentState: currentState
        )
        #expect(combinedState?.render() == priorTranscript + MeetingResumePolicy.resumeSeparator + currentTranscript)

        var result = makeResult(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 2))
        result.rawTranscript = currentTranscript
        result.speakerState = currentState
        result.ownerRecognitionAuthorization = token
        result.speakerAuthorizationFallbackTranscript = safeCurrent
        let merged = result.overriding(rawTranscript: combinedState?.render() ?? "", formattedNotes: "Merged notes",
            fallbackTranscript: safeCombined, speakerState: combinedState)

        #expect(merged.rawTranscript.contains("Example (You): Continued words"))
        #expect(merged.speakerState?.render() == merged.rawTranscript)
        #expect(merged.validatingOwnerAuthorization(nil).rawTranscript == safeCombined)
    }
}
