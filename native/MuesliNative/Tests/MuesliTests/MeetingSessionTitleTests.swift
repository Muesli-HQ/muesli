import Testing
@testable import MuesliNativeApp

@Suite("Meeting processing stage")
struct MeetingProcessingStageTests {
    @Test("audio processing keeps dictation blocked")
    func audioProcessingBlocksDictation() {
        #expect(!MeetingProcessingStage.transcribingAudio.allowsDictation)
        #expect(!MeetingProcessingStage.cleaningAudio.allowsDictation)
    }

    @Test("post-transcription processing allows dictation")
    func postTranscriptionAllowsDictation() {
        #expect(MeetingProcessingStage.generatingTitle.allowsDictation)
        #expect(MeetingProcessingStage.summarizingNotes.allowsDictation)
    }

    @Test("active dictation transcription cannot be replaced by meeting progress")
    func activeDictationTranscriptionStaysBlocked() {
        #expect(!DictationStartAdmissionPolicy.allowsStart(
            dictationState: .transcribing,
            meetingProcessingStage: .generatingTitle
        ))
    }

    @Test("dictation admission follows meeting audio processing boundary")
    func admissionFollowsMeetingAudioProcessingBoundary() {
        #expect(!DictationStartAdmissionPolicy.allowsStart(
            dictationState: .idle,
            meetingProcessingStage: .transcribingAudio
        ))
        #expect(DictationStartAdmissionPolicy.allowsStart(
            dictationState: .idle,
            meetingProcessingStage: .summarizingNotes
        ))
    }

    @Test("cleanup from a blocked hotkey start cannot retire active transcription")
    func blockedStartCleanupIsIgnored() {
        #expect(DictationStartAdmissionPolicy.shouldIgnoreCleanupAfterBlockedStart(
            hasStartedRecording: false,
            isStreaming: false,
            dictationState: .transcribing,
            meetingProcessingStage: .generatingTitle
        ))
        #expect(DictationStartAdmissionPolicy.shouldIgnoreCleanupAfterBlockedStart(
            hasStartedRecording: false,
            isStreaming: false,
            dictationState: .idle,
            meetingProcessingStage: .transcribingAudio
        ))
        #expect(!DictationStartAdmissionPolicy.shouldIgnoreCleanupAfterBlockedStart(
            hasStartedRecording: false,
            isStreaming: false,
            dictationState: .preparing,
            meetingProcessingStage: nil
        ))
        #expect(!DictationStartAdmissionPolicy.shouldIgnoreCleanupAfterBlockedStart(
            hasStartedRecording: true,
            isStreaming: false,
            dictationState: .recording,
            meetingProcessingStage: nil
        ))
    }
}

@Suite("Meeting session title selection")
struct MeetingSessionTitleTests {
    @Test("calendar event title is used when present")
    func calendarEventTitleCandidate() {
        let title = MeetingSession.calendarTitleCandidate(
            originalTitle: "April Town Hall",
            calendarEventID: "calendar-event-123"
        )

        #expect(title == "April Town Hall")
    }

    @Test("blank calendar event title falls through")
    func blankCalendarEventTitleFallsThrough() {
        let title = MeetingSession.calendarTitleCandidate(
            originalTitle: "  \n\t  ",
            calendarEventID: "calendar-event-123"
        )

        #expect(title == nil)
    }

    @Test("non-calendar meeting does not use original title as a calendar title")
    func nonCalendarMeetingFallsThrough() {
        let title = MeetingSession.calendarTitleCandidate(
            originalTitle: "Quick Note",
            calendarEventID: nil
        )

        #expect(title == nil)
    }
}

@Suite("Meeting session recovery policy")
struct MeetingSessionRecoveryPolicyTests {
    @Test("Nemotron falls back to system audio when streaming produced no segments")
    func unifiedNemotronRecoversEmptySystemTranscript() {
        #expect(MeetingSession.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: true,
            hasSystemSegments: false
        ))
    }

    @Test("Nemotron skips redundant system recovery when streaming produced segments")
    func unifiedNemotronKeepsStreamingSystemTranscript() {
        #expect(!MeetingSession.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: true,
            hasSystemSegments: true
        ))
    }

    @Test("batch meeting paths retain their existing system recovery behavior")
    func batchPathStillAttemptsSystemRecovery() {
        #expect(MeetingSession.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: false,
            hasSystemSegments: true
        ))
    }

    @Test("batch meeting paths recover when no system segments exist")
    func batchPathRecoversEmptySystemTranscript() {
        #expect(MeetingSession.shouldAttemptSystemRecovery(
            usesUnifiedNemotronTranscript: false,
            hasSystemSegments: false
        ))
    }
}
