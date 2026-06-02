import Testing
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

    @Test("note preview resumes after metadata section when prose follows")
    func notePreviewResumesAfterMetadataSection() {
        let preview = MeetingPreviewText.noteSnippet(from: """
        ## Attendees

        No attendees captured

        The team reviewed pipeline progress and next steps.
        """, limit: 120)

        #expect(preview == "The team reviewed pipeline progress and next steps.")
    }
}
