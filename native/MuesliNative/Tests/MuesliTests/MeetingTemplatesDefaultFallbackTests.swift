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
}
