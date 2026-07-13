import Testing
@testable import MuesliNativeApp

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
