import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingPipelineStatus")
struct MeetingPipelineStatusTests {
    private func makeMeeting(transcript: String = "hello there", notes: String = "## Decision\nShip it", source: MeetingSource = .meeting, status: MeetingStatus = .completed) -> MeetingRecord {
        MeetingRecord(
            id: 1,
            title: "Weekly",
            startTime: "2026-07-01T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: transcript,
            formattedNotes: notes,
            wordCount: 2,
            folderID: nil,
            status: status,
            source: source
        )
    }

    private func failureNotes(_ message: String, manualNotes: String? = nil) -> String {
        MeetingSummaryClient.summaryFailureNotes(
            transcript: "hello there",
            meetingTitle: "Weekly",
            error: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message]),
            manualNotes: manualNotes
        )
    }

    @Test("failure reason is the error text the notes recorded")
    func reasonIsTheStoredErrorText() {
        let notes = failureNotes("Custom LLM could not be reached. A server with the specified hostname could not be found.")
        #expect(MeetingSummaryClient.summaryFailureReason(from: notes)
            == "Custom LLM could not be reached. A server with the specified hostname could not be found.")
    }

    @Test("failure reason stops before written notes and the transcript")
    func reasonExcludesLaterSections() {
        let notes = failureNotes("Server is off.", manualNotes: "- my own note")
        #expect(MeetingSummaryClient.summaryFailureReason(from: notes) == "Server is off.")
    }

    @Test("failure notes saved before the lowercase rebrand still give their reason")
    func reasonFromCapitalizedLead() {
        let notes = failureNotes("Server is off.").replacingOccurrences(
            of: "muesli could not generate", with: "Muesli could not generate"
        )
        #expect(notes.contains("Muesli could not generate"))
        #expect(MeetingSummaryClient.summaryFailureReason(from: notes) == "Server is off.")
    }

    @Test("notes that are not a failure have no reason")
    func structuredNotesHaveNoReason() {
        #expect(MeetingSummaryClient.summaryFailureReason(from: "## Decision\nShip it") == nil)
    }

    @Test("summary stage: structured notes succeed")
    func summarySucceeds() {
        #expect(MeetingPipelineStatus.summary(for: makeMeeting(), isRunning: false) == .succeeded)
    }

    @Test("summary stage: failure notes fail with the stored reason")
    func summaryFails() {
        let meeting = makeMeeting(notes: failureNotes("Server is off."))
        #expect(MeetingPipelineStatus.summary(for: meeting, isRunning: false) == .failed(reason: "Server is off."))
    }

    @Test("summary stage: a running summary wins over the old failure")
    func summaryRunningWins() {
        let meeting = makeMeeting(notes: failureNotes("Server is off."))
        #expect(MeetingPipelineStatus.summary(for: meeting, isRunning: true) == .working)
    }

    @Test("summary stage: notes that were never generated show no chip")
    func summaryNeverAttemptedHasNoChip() {
        #expect(MeetingPipelineStatus.summary(for: makeMeeting(notes: ""), isRunning: false) == nil)
        #expect(MeetingPipelineStatus.summary(for: makeMeeting(notes: "## Raw Transcript\n\nhello"), isRunning: false) == nil)
    }

    @Test("summary stage: a Granola import without a summary shows no chip")
    func summaryGranolaImportWithoutNotesHasNoChip() {
        let meeting = makeMeeting(notes: "", source: .granolaImport)
        #expect(meeting.usesImportedManualNotes)
        #expect(MeetingPipelineStatus.summary(for: meeting, isRunning: false) == nil)
    }

    @Test("summary stage: a failure stored for a meeting with no backend still fails")
    func summaryNotConfiguredFailureStaysFailed() {
        let meeting = makeMeeting(notes: failureNotes("Sign in to ChatGPT to summarize."))
        #expect(MeetingPipelineStatus.summary(for: meeting, isRunning: false)
            == .failed(reason: "Sign in to ChatGPT to summarize."))
    }

    @Test("transcription stage: an import with no transcript shows no chip")
    func transcriptionGranolaImportWithoutTranscriptHasNoChip() {
        let meeting = makeMeeting(transcript: "", source: .granolaImport)
        #expect(MeetingPipelineStatus.transcription(for: meeting, isRunning: false) == nil)
    }

    @Test("transcription stage: a failed meeting with no transcript fails and can retry")
    func transcriptionFailedMeetingWithoutTranscriptFails() {
        let meeting = makeMeeting(transcript: "", notes: "", status: .failed)
        #expect(MeetingPipelineStatus.transcription(for: meeting, isRunning: false)
            == .failed(reason: "No transcript was captured for this meeting."))
    }

    @Test("transcription stage: transcript present succeeds, empty fails, re-transcribing works")
    func transcriptionStates() {
        #expect(MeetingPipelineStatus.transcription(for: makeMeeting(), isRunning: false) == .succeeded)
        #expect(MeetingPipelineStatus.transcription(for: makeMeeting(transcript: "  \n"), isRunning: false)
            == .failed(reason: "No transcript was captured for this meeting."))
        #expect(MeetingPipelineStatus.transcription(for: makeMeeting(transcript: ""), isRunning: true) == .working)
    }
}
