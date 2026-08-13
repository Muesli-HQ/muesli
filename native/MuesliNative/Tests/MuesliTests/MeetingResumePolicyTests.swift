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
}
