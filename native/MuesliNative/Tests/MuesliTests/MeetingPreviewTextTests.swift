import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting preview text")
struct MeetingPreviewTextTests {

    @Test("removes markdown structure from meeting previews")
    func removesMarkdownStructure() {
        let preview = MeetingPreviewText.snippet(from: """
        # Customer Sync

        ## Decisions
        - **Ship** pause controls
        - [ ] Follow up with [Rishab](https://example.com)
        - _Polish_ __meeting__ previews
        """, limit: 120)

        #expect(preview == "Customer Sync Decisions Ship pause controls Follow up with Rishab Polish meeting previews")
    }

    @Test("preserves non-markdown underscores and tildes")
    func preservesIdentifierCharacters() {
        let preview = MeetingPreviewText.snippet(from: """
        ## Implementation Notes
        Use `my_function` for ~50 rows before _polishing_ the summary.
        """, limit: 120)

        #expect(preview == "Implementation Notes Use my_function for ~50 rows before polishing the summary.")
    }

    @Test("falls back when source is empty after cleanup")
    func emptyPreviewFallback() {
        let preview = MeetingPreviewText.snippet(from: """
        ```swift
        let hidden = true
        ```
        """)

        #expect(preview == "No notes yet")
    }

    @Test("legacy literal backslashes in transcript labels stay unchanged")
    func legacySpeakerLabelBackslashIsPreserved() {
        let preview = MeetingPreviewText.snippet(from: #"[00:00:01] Team\: Example: Ship Friday."#)

        #expect(preview == #"[00:00:01] Team\: Example: Ship Friday."#)
    }

    @Test("transcript search previews decode a speaker label only once")
    func searchPreviewPreservesBackslashBeforeColonInSpeakerName() {
        let stored = MeetingSpeakerState.renderTranscriptTurn(
            timestamp: "00:00:01", speaker: "Team\\: Room", text: "Ship Friday."
        )

        let preview = MeetingPreviewText.transcriptSearchField(
            rawTranscript: stored, matching: "team\\: room"
        )

        #expect(preview == #"[00:00:01] Team\: Room: Ship Friday."#)
    }
}
