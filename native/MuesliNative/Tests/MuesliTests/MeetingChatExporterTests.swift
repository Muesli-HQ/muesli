import Foundation
import PDFKit
import Testing
@testable import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting chat prompts and export")
struct MeetingChatExporterTests {
    private func turn() -> MeetingChatTurn {
        let citation = MeetingChatCitation(sourceKey: "S1", meetingID: 1, title: "Planning", startDate: Date(timeIntervalSince1970: 1_000), kind: .manualNotes,
            excerpt: "Launch Friday 🌻", range: .init(location: 0, length: 15), revision: "r1")
        return .init(id: UUID(), sessionID: UUID(), ordinal: 0, question: "What did we decide?", scope: .init(), state: .completed,
            originalAnswer: "Launch Friday [[S1]]", editableDraft: "Edited Friday [[S1]]", citations: [citation], provider: "test", model: "test")
    }
    private func session() -> MeetingChatSession { .init(id: UUID(), title: "Launch", scope: .init(), createdAt: Date(), updatedAt: Date(), contextStartOrdinal: 0) }
    @Test func copyAndMarkdownRetainReferencesAndLabelEditedDrafts() {
        let original = MeetingChatExporter.markdown(turn: turn(), session: session(), useEditedDraft: false)
        #expect(original.contains("Launch Friday [1]"))
        #expect(original.contains("Written notes"))
        #expect(original.contains("Launch Friday 🌻"))
        #expect(!original.contains("Edited draft"))
        let edited = MeetingChatExporter.markdown(turn: turn(), session: session(), useEditedDraft: true)
        #expect(edited.contains("Edited draft"))
        #expect(edited.contains("Edited Friday [1]"))
        #expect(!edited.contains("00:00:"))
        #expect(MeetingChatExporter.plainText(turn: turn(), session: session(), useEditedDraft: false).contains("Planning"))
    }
    @Test func quickPromptsPrepareEditableTextAndAskForUnknownIdentity() {
        let prompt = MeetingChatQuickAction.draftFollowUp.prepare(scope: .init(), now: Date(), calendar: .current, userDisplayName: nil)
        #expect(prompt.isDraft)
        #expect(prompt.text.contains("Draft"))
        let personal = MeetingChatQuickAction.myNextSteps.prepare(scope: .init(), now: Date(), calendar: .current, userDisplayName: nil)
        #expect(personal.needsParticipantName)
    }
    @Test func weeklyRecapUsesCalendarDaysAcrossDSTAndIntersectsScope() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!
        let prepared = MeetingChatQuickAction.weeklyRecap.prepare(scope: .init(), now: now, calendar: calendar, userDisplayName: nil)
        #expect(calendar.dateComponents([.day], from: prepared.scope.startDate!, to: prepared.scope.endDateExclusive!).day == 7)
        #expect(prepared.scope.endDateExclusive!.timeIntervalSince(prepared.scope.startDate!) == 167 * 3_600)
        let later = calendar.date(byAdding: .day, value: -1, to: now)!
        let narrowed = MeetingChatQuickAction.weeklyRecap.prepare(scope: .init(startDate: later), now: now, calendar: calendar, userDisplayName: nil)
        #expect(narrowed.scope.startDate == later)
    }
    @Test @MainActor func pdfPaginationIncludesSourceReferences() throws {
        var value = turn(); value.originalAnswer = (0..<120).map { "Decision \($0): launch Friday [[S1]]." }.joined(separator: "\n\n")
        let markdown = MeetingChatExporter.markdown(turn: value, session: session(), useEditedDraft: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-export-\(UUID()).pdf")
        try MeetingExporter.writePDF(attributed: MeetingExporter.buildAttributedString(from: markdown), to: url)
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount > 1)
        #expect(document.string?.contains("Planning") == true)
        #expect(document.string?.contains("Written notes") == true)
    }
    @Test @MainActor func cancelDoesNotWriteAFile() throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-chat-export-\(UUID()).md")
        try MeetingChatExporter.save(markdown: "Unwritten", destination: nil, pdf: false)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
