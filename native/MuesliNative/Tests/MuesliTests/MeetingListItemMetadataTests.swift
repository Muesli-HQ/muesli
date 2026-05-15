import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting list item metadata")
struct MeetingListItemMetadataTests {
    @Test("friendly date uses relative day labels and local-style time")
    func friendlyDateLabels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(ISO8601DateFormatter().date(from: "2026-05-14T21:00:00Z"))

        #expect(MeetingListItemMetadata.friendlyDate(
            "2026-05-14T17:40:17Z",
            now: now,
            calendar: calendar
        ) == "Today, 5:40 PM")
        #expect(MeetingListItemMetadata.friendlyDate(
            "2026-05-13T15:00:00Z",
            now: now,
            calendar: calendar
        ) == "Yesterday, 3:00 PM")
        #expect(MeetingListItemMetadata.friendlyDate(
            "2025-11-05T16:00:00Z",
            now: now,
            calendar: calendar
        ) == "Nov 5, 2025, 4:00 PM")
    }

    @Test("participant line extracts attendee names and emails from notes")
    func participantLine() {
        let meeting = makeMeeting(formattedNotes: """
        ## Summary

        Discussed the rollout.

        ## Attendees

        - Sam Gaddis <sam@runpoint.ai>
        - Jonathan Layton <jonathan.layton@runpoint.ai>
        - ops@example.com

        ## Source

        - Granola note ID: `not_123`
        """)

        #expect(MeetingListItemMetadata.participantLine(from: meeting) == "Sam Gaddis <sam@runpoint.ai>, Jonathan Layton <jonathan.layton@runpoint.ai> +1 more")
        #expect(MeetingListItemMetadata.fullParticipantLine(from: meeting) == "Sam Gaddis <sam@runpoint.ai>, Jonathan Layton <jonathan.layton@runpoint.ai>, ops@example.com")
    }

    @Test("participant extraction ignores prose placeholders")
    func participantExtractionIgnoresProsePlaceholders() {
        let meeting = makeMeeting(formattedNotes: """
        ## Attendees

        No attendees captured
        The discussion focused on pipeline progress.
        - Sam Gaddis <sam@runpoint.ai>
        """)

        #expect(MeetingListItemMetadata.fullParticipantLine(from: meeting) == "Sam Gaddis <sam@runpoint.ai>")
    }

    @Test("notes preview skips generic headings and attendee/source sections")
    func notesPreviewSkipsMetadataSections() {
        let meeting = makeMeeting(formattedNotes: """
        ## Meeting Summary

        The team reviewed import progress and next steps.

        ## Attendees

        - Sam <sam@runpoint.ai>

        ## Source

        - Granola note ID: `not_123`
        """)

        #expect(MeetingListItemMetadata.notesPreview(from: meeting, limit: 120) == "The team reviewed import progress and next steps.")
    }

    private func makeMeeting(formattedNotes: String) -> MeetingRecord {
        MeetingRecord(
            id: 1,
            title: "Test Meeting",
            startTime: "2026-05-14T17:40:17Z",
            durationSeconds: 1800,
            rawTranscript: "Transcript",
            formattedNotes: formattedNotes,
            wordCount: 2,
            folderID: nil
        )
    }
}
