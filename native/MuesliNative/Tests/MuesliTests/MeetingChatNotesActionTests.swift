import Foundation
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@MainActor
@Suite("Meeting chat cited notes actions")
struct MeetingChatNotesActionTests {
    private let generated = "## Decision\nLaunch Friday."
    private let manual = "# Launch\n\nMy written reminder."

    private func fixture() throws -> (MuesliController, DictationStore, MeetingRecord) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-notes-actions-\(UUID())")
        let store = DictationStore(databaseURL: directory.appendingPathComponent("test.db"))
        try store.migrateIfNeeded()
        let id = try store.insertMeeting(title: "Launch", calendarEventID: nil, startTime: Date(), endTime: Date(),
            rawTranscript: "Launch Friday.", formattedNotes: generated, micAudioPath: nil, systemAudioPath: nil)
        try store.updateMeetingManualNotes(id: id, manualNotes: manual)
        let controller = MuesliController(runtime: RuntimePaths(repoRoot: directory, menuIcon: nil, appIcon: nil, bundlePath: nil),
            dictationStore: store, configStore: ConfigStore(supportDirectory: directory))
        return (controller, store, try #require(controller.meeting(id: id)))
    }

    private func citation(for meeting: MeetingRecord, kind: MeetingChatSourceKind, meetingID: Int64? = nil) -> MeetingChatCitation {
        MeetingChatCitation(sourceKey: "S1", meetingID: meetingID ?? meeting.id, title: meeting.title, startDate: Date(),
            kind: kind, excerpt: "My written reminder.", range: .init(location: 10, length: 20), revision: "fixture")
    }

    @Test func manualCitationEditsAndCopiesTheDisplayedNotes() throws {
        let (_, _, meeting) = try fixture()
        let source = citation(for: meeting, kind: .manualNotes)
        #expect(MeetingDetailView.notesContent(for: meeting, citation: source) == "# Launch\n\nMy written reminder.")
        let copied = MeetingDetailView.copyContent(for: meeting, content: .notes, citation: source)
        #expect(copied.hasSuffix("\n# Launch\n\nMy written reminder."))
        #expect(!copied.contains("Launch Friday."))
    }

    @Test func manualCitationCopyPreservesEditedHeadingForUnstructuredMeeting() {
        let meeting = MeetingRecord(id: 7, title: "Launch", startTime: "2026-10-11T10:00:00Z", durationSeconds: 0,
            rawTranscript: "Original transcript", formattedNotes: "", wordCount: 2, folderID: nil, manualNotes: manual)
        let copied = MeetingDetailView.copyContent(for: meeting, content: .notes,
            editedText: "# Launch\n\nEdited reminder.", citation: citation(for: meeting, kind: .manualNotes))
        #expect(copied.hasSuffix("\n# Launch\n\nEdited reminder."))
    }

    @Test func manualCitationSavePreservesGeneratedNotes() throws {
        let (controller, _, meeting) = try fixture()
        MeetingDetailView.saveNotes(for: meeting, notes: "Revised written reminder.",
            citation: citation(for: meeting, kind: .manualNotes), controller: controller)
        let saved = try #require(controller.meeting(id: meeting.id))
        #expect(saved.manualNotes == "Revised written reminder.")
        #expect(saved.formattedNotes == "## Decision\nLaunch Friday.")
    }

    @Test func unrelatedManualCitationDoesNotChangeNotesActions() throws {
        let (controller, _, meeting) = try fixture()
        let otherSource = citation(for: meeting, kind: .manualNotes, meetingID: meeting.id + 1)
        #expect(MeetingDetailView.notesContent(for: meeting, citation: otherSource) == "## Decision\nLaunch Friday.")
        #expect(MeetingDetailView.copyContent(for: meeting, content: .notes, citation: otherSource).hasSuffix("\n## Decision\nLaunch Friday."))
        MeetingDetailView.saveNotes(for: meeting, notes: "Generated revision", citation: otherSource, controller: controller)
        let saved = try #require(controller.meeting(id: meeting.id))
        #expect(saved.manualNotes == "# Launch\n\nMy written reminder.")
        #expect(saved.formattedNotes == "Generated revision")
    }

    @Test func generatedCitationRetainsGeneratedNotesActions() throws {
        let (controller, _, meeting) = try fixture()
        let source = citation(for: meeting, kind: .generatedNotes)
        #expect(MeetingDetailView.notesContent(for: meeting, citation: source) == "## Decision\nLaunch Friday.")
        #expect(MeetingDetailView.copyContent(for: meeting, content: .notes, citation: source).hasSuffix("\n## Decision\nLaunch Friday."))
        MeetingDetailView.saveNotes(for: meeting, notes: "Updated generated notes", citation: source, controller: controller)
        let saved = try #require(controller.meeting(id: meeting.id))
        #expect(saved.formattedNotes == "Updated generated notes")
        #expect(saved.manualNotes == "# Launch\n\nMy written reminder.")
    }
}

@Suite("Meeting chat source grouping")
struct MeetingChatSourceGroupingTests {
    private func citation(_ key: String, meeting: Int64, excerpt: String, location: Int = 0) -> MeetingChatCitation {
        .init(sourceKey: key, meetingID: meeting, title: "Meeting \(meeting)", startDate: Date(timeIntervalSince1970: 1_000),
              kind: .transcript, excerpt: excerpt, range: .init(location: location, length: excerpt.utf16.count),
              timestamp: "00:01:23", revision: "revision-\(meeting)")
    }

    @Test func groupingPreservesCitationNumbersAndExactPassageTargets() {
        let first = citation("S9", meeting: 7, excerpt: "First passage", location: 30)
        let other = citation("S2", meeting: 3, excerpt: "Other meeting", location: 80)
        let third = citation("S15", meeting: 7, excerpt: "Different passage", location: 130)
        let groups = MeetingChatSourceGroup.grouped([first, other, third])
        #expect(groups.map(\.id) == [7, 3])
        #expect(groups[0].passages.map(\.number) == [1, 3])
        #expect(groups[1].passages.map(\.number) == [2])
        #expect(groups[0].passages.map(\.citation) == [first, third])
        #expect(groups[0].passages[1].citation.range.location == 130)
        #expect(groups[0].passages[1].id == "S15")
    }

    @Test func disclosureDistinguishesMeetingCountFromPassageCount() {
        let citations = (1...8).map { citation("S\($0)", meeting: 7, excerpt: "Passage \($0)") }
        #expect(MeetingChatSourceGroup.label(for: citations) == "1 meeting · 8 passages")
        #expect(MeetingChatSourceGroup.label(for: Array(citations.prefix(1))) == "1 meeting · 1 passage")
        #expect(MeetingChatSourceGroup.label(for: citations + [citation("S9", meeting: 8, excerpt: "Other")]) == "2 meetings · 9 passages")
    }

    @Test func previewCollapsesWhitespaceWithoutChangingCitationExcerpt() {
        let original = citation("S1", meeting: 7, excerpt: "First line\n\n  Second\tline")
        let passage = MeetingChatSourceGroup.grouped([original])[0].passages[0]
        #expect(passage.preview == "First line Second line")
        #expect(passage.citation.excerpt == "First line\n\n  Second\tline")
    }
}
