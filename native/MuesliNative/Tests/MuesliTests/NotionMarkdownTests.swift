import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

/// Pure tests for the 2026-03-11 data-sources migration: the Markdown body builder
/// (`NotionTarget.bodyMarkdown`) and the request-body shapes (`createDatabaseBody`,
/// `createPageBody`). No network.
@Suite("Notion markdown + payload shapes")
struct NotionMarkdownTests {

    private func meeting(notes: String?, manual: String?, transcript: String?) -> ExportRecord {
        ExportRecord(
            kind: .meeting, localID: 1, updatedAt: 0, existingRemoteID: nil,
            title: "Standup", notesMarkdown: notes, manualNotes: manual, transcript: transcript,
            startTime: nil, appContext: nil, meetingType: "1:1"
        )
    }

    private func dictation(text: String?) -> ExportRecord {
        ExportRecord(
            kind: .dictation, localID: 2, updatedAt: 0, existingRemoteID: nil,
            title: "Note", notesMarkdown: nil, manualNotes: nil, transcript: text,
            startTime: nil, appContext: nil, meetingType: nil
        )
    }

    // MARK: - bodyMarkdown

    @Test("meeting body puts notes, then manual notes, then a collapsible transcript toggle in order")
    func meetingBodyOrder() {
        let md = NotionTarget.bodyMarkdown(meeting(
            notes: "## Summary\n- point",
            manual: "remember to follow up",
            transcript: "hello world transcript"
        ))
        let expected = """
        ## Summary
        - point

        ## Manual notes

        remember to follow up

        <details>
        <summary>Transcript</summary>

        hello world transcript

        </details>
        """
        #expect(md == expected)

        // Ordering: notes before manual notes before the transcript toggle.
        let notesIdx = md.range(of: "## Summary")!.lowerBound
        let manualIdx = md.range(of: "## Manual notes")!.lowerBound
        let toggleIdx = md.range(of: "<summary>Transcript</summary>")!.lowerBound
        #expect(notesIdx < manualIdx)
        #expect(manualIdx < toggleIdx)
    }

    @Test("meeting body omits missing sections")
    func meetingBodyOmitsMissing() {
        let md = NotionTarget.bodyMarkdown(meeting(notes: "## Notes", manual: nil, transcript: nil))
        #expect(md == "## Notes")
        #expect(!md.contains("Manual notes"))
        #expect(!md.contains("<details>"))
    }

    @Test("dictation body is just the text with no transcript toggle")
    func dictationBodyNoToggle() {
        let md = NotionTarget.bodyMarkdown(dictation(text: "quick spoken note"))
        #expect(md == "quick spoken note")
        #expect(!md.contains("<details>"))
        #expect(!md.contains("Transcript"))
    }

    // MARK: - createDatabaseBody shape

    @Test("createDatabaseBody nests properties under initial_data_source and keeps title/icon at top level")
    func createDatabaseBodyShape() {
        let body = NotionClient.createDatabaseBody(parentPageID: "page-abc", title: "Abdo’s Muesli Notes")

        // Always a shared-page parent (internal tokens can't create at the workspace root).
        let parent = body["parent"] as? [String: Any]
        #expect(parent?["type"] as? String == "page_id")
        #expect(parent?["page_id"] as? String == "page-abc")

        // Title stays at the database top level.
        #expect(body["title"] != nil)
        #expect(body["icon"] != nil)

        // Properties MUST nest under initial_data_source (not top-level).
        #expect(body["properties"] == nil)
        let initial = body["initial_data_source"] as? [String: Any]
        let props = initial?["properties"] as? [String: Any]
        #expect(props?["Name"] != nil)
        #expect(props?["Type"] != nil)
        #expect(props?["Meeting type"] != nil)
        #expect(props?["Created by"] != nil)

        // Body must serialize (no non-JSON types).
        #expect((try? JSONSerialization.data(withJSONObject: body)) != nil)
    }

    @Test("createDatabaseBody with a parent page uses page_id parent")
    func createDatabaseBodyParentPage() {
        let body = NotionClient.createDatabaseBody(parentPageID: "page-abc", title: "T")
        let parent = body["parent"] as? [String: Any]
        #expect(parent?["type"] as? String == "page_id")
        #expect(parent?["page_id"] as? String == "page-abc")
    }

    // MARK: - createPageBody shape

    @Test("createPageBody uses a data_source_id parent and carries the markdown body (no children)")
    func createPageBodyShape() {
        let body = NotionClient.createPageBody(
            dataSourceID: "ds-1",
            properties: ["Name": ["title": []]],
            markdown: "## Hi",
            icon: NotionClient.muesliIcon
        )
        let parent = body["parent"] as? [String: Any]
        #expect(parent?["type"] as? String == "data_source_id")
        #expect(parent?["data_source_id"] as? String == "ds-1")
        #expect(body["markdown"] as? String == "## Hi")
        #expect(body["children"] == nil)
        #expect(body["icon"] != nil)
        #expect((try? JSONSerialization.data(withJSONObject: body)) != nil)
    }
}
