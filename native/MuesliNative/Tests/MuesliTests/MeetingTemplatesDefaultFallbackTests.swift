import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Meeting template default fallback")
struct MeetingTemplatesDefaultFallbackTests {

    private func makeCustom(id: String, name: String) -> CustomMeetingTemplate {
        CustomMeetingTemplate(id: id, name: name, prompt: "Body for \(name)", icon: "square.and.pencil")
    }

    @Test("falls back to configured default when no id provided")
    func fallsBackToConfiguredDefaultWhenNoIDProvided() {
        let resolved = MeetingTemplates.resolveDefinition(
            id: nil,
            customTemplates: [makeCustom(id: "custom-1", name: "My Notes")],
            defaultTemplateID: "custom-1"
        )
        #expect(resolved.id == "custom-1")
    }

    @Test("explicit id beats configured default")
    func explicitIDBeatsConfiguredDefault() {
        let resolved = MeetingTemplates.resolveDefinition(
            id: "one-to-one",
            customTemplates: [makeCustom(id: "custom-1", name: "My Notes")],
            defaultTemplateID: "custom-1"
        )
        #expect(resolved.id == "one-to-one")
    }

    @Test("bare auto id defers to configured default")
    func bareAutoIDDefersToConfiguredDefault() {
        let resolved = MeetingTemplates.resolveDefinition(
            id: MeetingTemplates.autoID,
            customTemplates: [makeCustom(id: "custom-1", name: "My Notes")],
            defaultTemplateID: "custom-1"
        )
        #expect(resolved.id == "custom-1")
    }

    @Test("invalid default degrades to Auto")
    func invalidDefaultDegradesToAuto() {
        let resolved = MeetingTemplates.resolveDefinition(
            id: nil,
            customTemplates: [],
            defaultTemplateID: "does-not-exist"
        )
        #expect(resolved.id == MeetingTemplates.autoID)
    }

    @Test("nil default preserves Auto behaviour")
    func nilDefaultPreservesAutoBehaviour() {
        let resolved = MeetingTemplates.resolveDefinition(
            id: nil,
            customTemplates: [],
            defaultTemplateID: nil
        )
        #expect(resolved.id == MeetingTemplates.autoID)
    }

    private func makeMeeting(
        selectedTemplateID: String? = nil,
        selectedTemplateName: String? = nil,
        selectedTemplateKind: MeetingTemplateKind? = nil,
        selectedTemplatePrompt: String? = nil
    ) -> MeetingRecord {
        MeetingRecord(
            id: 1,
            title: "Design sync",
            startTime: "2026-07-01T10:00:00Z",
            durationSeconds: 60,
            rawTranscript: "hello",
            formattedNotes: "",
            wordCount: 1,
            folderID: nil,
            selectedTemplateID: selectedTemplateID,
            selectedTemplateName: selectedTemplateName,
            selectedTemplateKind: selectedTemplateKind,
            selectedTemplatePrompt: selectedTemplatePrompt
        )
    }

    @Test("legacy meeting with no template fields uses configured default")
    func legacyMeetingUsesConfiguredDefault() {
        let snapshot = MeetingTemplates.snapshot(
            for: makeMeeting(),
            customTemplates: [makeCustom(id: "custom-1", name: "My Notes")],
            defaultTemplateID: "custom-1"
        )
        #expect(snapshot.id == "custom-1")
    }

    @Test("partial record with stored id beats configured default")
    func partialRecordWithStoredIDBeatsDefault() {
        let snapshot = MeetingTemplates.snapshot(
            for: makeMeeting(selectedTemplateID: "one-to-one"),
            customTemplates: [makeCustom(id: "custom-1", name: "My Notes")],
            defaultTemplateID: "custom-1"
        )
        #expect(snapshot.id == "one-to-one")
    }

    @Test("fully stamped Auto snapshot ignores configured default")
    func fullyStampedAutoSnapshotIgnoresDefault() {
        let storedName = "Stored Auto"
        let storedPrompt = "Stored prompt"
        let snapshot = MeetingTemplates.snapshot(
            for: makeMeeting(
                selectedTemplateID: MeetingTemplates.autoID,
                selectedTemplateName: storedName,
                selectedTemplateKind: .auto,
                selectedTemplatePrompt: storedPrompt
            ),
            customTemplates: [makeCustom(id: "custom-1", name: "My Notes")],
            defaultTemplateID: "custom-1"
        )
        #expect(snapshot.id == MeetingTemplates.autoID)
        #expect(snapshot.name == storedName)
        #expect(snapshot.kind == .auto)
        #expect(snapshot.prompt == storedPrompt)
    }
}
