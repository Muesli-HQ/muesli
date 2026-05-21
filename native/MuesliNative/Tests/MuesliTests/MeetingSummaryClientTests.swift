import Testing
import Foundation
import MuesliCore
@testable import MuesliNativeApp

@Suite("MeetingSummaryClient")
struct MeetingSummaryClientTests {
    private let customTemplate = MeetingTemplateSnapshot(
        id: "custom-follow-up",
        name: "Customer Follow-Up",
        kind: .custom,
        prompt: """
        Use this structure exactly:

        ## Follow-Up Summary
        - Main takeaways

        ## Risks
        - Any risks
        """
    )

    @Test("summarize returns raw transcript fallback when no API key")
    func fallbackWithoutKey() async throws {
        var config = AppConfig()
        config.openAIAPIKey = ""
        config.meetingSummaryBackend = "openai"

        let result = try await MeetingSummaryClient.summarize(
            transcript: "Hello world",
            meetingTitle: "Test",
            config: config
        )

        #expect(result.contains("## Raw Transcript"))
        #expect(result.contains("Hello world"))
    }

    @Test("summary instructions include built-in template structure")
    func promptIncludesBuiltInTemplate() {
        let instructions = MeetingSummaryClient.summaryInstructions(for: MeetingTemplates.auto.snapshot)

        #expect(instructions.contains("You are a meeting notes assistant"))
        #expect(instructions.contains("## Meeting Summary"))
        #expect(instructions.contains("## Action Items"))
    }

    @Test("summary instructions include custom template prompt verbatim")
    func promptIncludesCustomTemplate() {
        let instructions = MeetingSummaryClient.summaryInstructions(for: customTemplate)

        #expect(instructions.contains("## Follow-Up Summary"))
        #expect(instructions.contains("## Risks"))
        #expect(instructions.contains("Do not invent facts"))
    }

    @Test("summary instructions mention preserving current notes when provided")
    func promptMentionsPreservingCurrentNotes() {
        let instructions = MeetingSummaryClient.summaryInstructions(
            for: customTemplate,
            existingNotes: "## Notes\n- Generated follow-up detail",
            manualNotes: "- User added follow-up detail"
        )

        #expect(instructions.contains("Protected written notes"))
        #expect(instructions.contains("Place each written note near the most relevant section"))
        #expect(instructions.contains("Do not rewrite, polish, summarize away, or omit"))
    }

    @Test("summary user prompt includes existing notes context when provided")
    func userPromptIncludesExistingNotes() {
        let prompt = MeetingSummaryClient.summaryUserPrompt(
            transcript: "Transcript body",
            meetingTitle: "Customer Call",
            existingNotes: "## Notes\n- User added detail"
        )

        #expect(prompt.contains("Current generated notes to preserve and reformat:"))
        #expect(prompt.contains("User added detail"))
        #expect(prompt.contains("Raw transcript:\nTranscript body"))
    }

    @Test("summary user prompt includes protected written notes separately")
    func userPromptIncludesProtectedWrittenNotes() {
        let prompt = MeetingSummaryClient.summaryUserPrompt(
            transcript: "Transcript body",
            meetingTitle: "Customer Call",
            existingNotes: "## Notes\n- Generated detail",
            manualNotes: "- User typed decision"
        )

        #expect(prompt.contains("Current generated notes to preserve and reformat:"))
        #expect(prompt.contains("Protected written notes typed by the user during the meeting"))
        #expect(prompt.contains("- User typed decision"))
    }

    @Test("final notes retain manual notes verbatim")
    func finalNotesRetainManualNotesVerbatim() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: "## Summary\n- Shipped the plan",
            manualNotes: "- Decision: ship today\n- [ ] Follow up with Priy"
        )

        #expect(result.contains("## Summary"))
        #expect(result.contains("### Written notes"))
        #expect(result.contains("- Decision: ship today"))
        #expect(result.contains("- [ ] Follow up with Priy"))
    }

    @Test("final notes do not append written notes already placed in summary")
    func finalNotesSkipAlreadyPlacedManualNotes() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: "## Decisions\n- Decision: ship today",
            manualNotes: "- Decision: ship today"
        )

        #expect(result == "## Decisions\n- Decision: ship today")
    }

    @Test("final notes retain missing numbered written notes without duplicating placed ones")
    func finalNotesRetainMissingNumberedManualNotes() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: "## Decisions\n1. First decision",
            manualNotes: "1. First decision\n2. Second decision"
        )

        #expect(result == "## Decisions\n1. First decision\n\n### Written notes\n\n2. Second decision")
    }

    @Test("final notes match manual notes across list marker changes")
    func finalNotesMatchManualNotesAcrossListMarkers() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: """
            ## Decisions
            - Decision: ship today
            - Follow up with Priy
            1. First decision
            """,
            manualNotes: """
            • Decision: ship today
            - [ ] Follow up with Priy
            1) First decision
            2) Second decision
            """
        )

        #expect(result == "## Decisions\n- Decision: ship today\n- Follow up with Priy\n1. First decision\n\n### Written notes\n\n2) Second decision")
    }

    @Test("short written notes are not dropped by section title substring matches")
    func shortManualNotesDoNotFalseMatchSectionTitles() {
        let result = MeetingSummaryClient.notesByRetainingManualNotes(
            generatedNotes: "## Next steps\n- Follow up with Priy",
            manualNotes: "Next steps"
        )

        #expect(result == "## Next steps\n- Follow up with Priy\n\n### Written notes\n\nNext steps")
    }

    @Test("fallback summary retains manual notes")
    func fallbackSummaryRetainsManualNotes() async throws {
        var config = AppConfig()
        config.openAIAPIKey = ""
        config.meetingSummaryBackend = "openai"

        let result = try await MeetingSummaryClient.summarize(
            transcript: "Hello world",
            meetingTitle: "Test",
            config: config,
            existingNotes: "- Manual decision",
            manualNotesToRetain: "- Manual decision"
        )

        #expect(result.contains("## Raw Transcript"))
        #expect(result.contains("### Written notes"))
        #expect(result.contains("- Manual decision"))
    }

    @Test("summary user prompt includes meeting context when provided")
    func userPromptIncludesMeetingContext() {
        let prompt = MeetingSummaryClient.summaryUserPrompt(
            transcript: "Transcript body",
            meetingTitle: "Customer Call",
            visualContext: """
            [10:30:00] Google Chrome:
            App context:
            App: Google Chrome (example.com/customer)

            OCR visual text:
            Renewal risk
            """
        )

        #expect(prompt.contains("Meeting context captured during the meeting:"))
        #expect(prompt.contains("App context:"))
        #expect(prompt.contains("OCR visual text:"))
        #expect(prompt.contains("Raw transcript:\nTranscript body"))
    }

    @Test("summarize routes to OpenRouter when configured")
    func routesToOpenRouter() async throws {
        var config = AppConfig()
        config.openRouterAPIKey = ""
        config.meetingSummaryBackend = "openrouter"

        let result = try await MeetingSummaryClient.summarize(
            transcript: "Test transcript",
            meetingTitle: "My Meeting",
            config: config
        )

        // No key → falls back to raw transcript
        #expect(result.contains("## Raw Transcript"))
    }

    @Test("summary failure notes make backend failure visible")
    func summaryFailureNotesAreExplicit() {
        let error = MeetingSummaryError.backendFailed(
            backend: "OpenRouter",
            statusCode: 400,
            message: "No endpoints found for model retired/example"
        )

        let result = MeetingSummaryClient.summaryFailureNotes(
            transcript: "Raw words",
            meetingTitle: "Customer Review",
            error: error,
            manualNotes: "- User typed this during the meeting"
        )

        #expect(result.contains("## Summary failed"))
        #expect(result.contains("OpenRouter could not generate meeting notes."))
        #expect(result.contains("Status 400"))
        #expect(result.contains("selected model may be unavailable or retired"))
        #expect(result.contains("### Written notes"))
        #expect(result.contains("- User typed this during the meeting"))
        #expect(result.contains("## Raw Transcript"))
        #expect(result.contains("Raw words"))
    }

    @Test("summary backend errors describe retired or unavailable models")
    func summaryBackendErrorDescriptionMentionsModelAvailability() {
        let error = MeetingSummaryError.emptyResponse(backend: "OpenRouter")

        #expect(error.localizedDescription.contains("OpenRouter returned an empty response"))
        #expect(error.localizedDescription.contains("unavailable or incompatible"))
    }

    @Test("generateTitle returns nil without API key")
    func titleWithoutKey() async {
        var config = AppConfig()
        config.openAIAPIKey = ""
        config.meetingSummaryBackend = "openai"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "We discussed the quarterly review",
            config: config
        )

        #expect(title == nil)
    }

    @Test("title excerpt samples opening middle and closing transcript")
    func titleExcerptSamplesMeetingBreadth() {
        let transcript = [
            String(repeating: "opening setup ", count: 80),
            String(repeating: "middle product strategy ", count: 80),
            String(repeating: "closing storage roadmap ", count: 80),
        ].joined(separator: "\n\n")

        let excerpt = MeetingSummaryClient.titleTranscriptExcerpt(from: transcript, segmentLength: 120)

        #expect(excerpt.contains("Opening excerpt:"))
        #expect(excerpt.contains("Middle excerpt:"))
        #expect(excerpt.contains("Closing excerpt:"))
        #expect(excerpt.contains("opening setup"))
        #expect(excerpt.contains("middle product strategy"))
        #expect(excerpt.contains("closing storage roadmap"))
    }

    @Test("short title excerpt keeps full transcript")
    func shortTitleExcerptKeepsFullTranscript() {
        let transcript = "Short discussion about customer onboarding"

        let excerpt = MeetingSummaryClient.titleTranscriptExcerpt(from: transcript, segmentLength: 120)

        #expect(excerpt == transcript)
    }

    @Test("generateTitle returns nil for OpenRouter without key")
    func titleOpenRouterWithoutKey() async {
        var config = AppConfig()
        config.openRouterAPIKey = ""
        config.meetingSummaryBackend = "openrouter"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Sprint planning discussion",
            config: config
        )

        #expect(title == nil)
    }

    @Test("empty summary backend resolves to ChatGPT")
    func defaultsToChatGPT() {
        var config = AppConfig()
        config.meetingSummaryBackend = ""

        let backend = MeetingSummaryBackendOption.resolved(
            config.meetingSummaryBackend.isEmpty ? nil : config.meetingSummaryBackend
        )

        #expect(backend == .chatGPT)
    }

    @Test("summarize routes to Ollama when configured")
    func routesToOllama() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "ollama"
        config.ollamaURL = "http://localhost:1" // invalid port to force connection failure

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "My Meeting",
                config: config
            )
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            let summaryError = error as? MeetingSummaryError
            #expect(summaryError != nil)
            if case .requestFailed(let backend, _) = summaryError! {
                #expect(backend == "Ollama")
            } else {
                #expect(Bool(false), "Expected requestFailed error, got \(String(describing: error))")
            }
        }
    }

    @Test("generateTitle returns nil for Ollama when unreachable")
    func titleOllamaUnreachable() async {
        var config = AppConfig()
        config.meetingSummaryBackend = "ollama"
        config.ollamaURL = "http://localhost:1"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Sprint planning discussion",
            config: config
        )

        #expect(title == nil)
    }

    @Test("generateTitle returns nil for Ollama with invalid URL")
    func titleOllamaInvalidURL() async {
        var config = AppConfig()
        config.meetingSummaryBackend = "ollama"
        config.ollamaURL = "not a valid url"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Sprint planning discussion",
            config: config
        )

        #expect(title == nil)
    }

    @Test("summarize with Ollama uses default model when none configured")
    func ollamaUsesDefaultModel() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "ollama"
        config.ollamaModel = ""
        config.ollamaURL = "http://localhost:1"

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test",
                meetingTitle: "Title",
                config: config
            )
        } catch {
            // The request fails because port 1 is invalid, but the model
            // defaulting is tested by the fact that no empty-model error is thrown
            let summaryError = error as? MeetingSummaryError
            #expect(summaryError != nil)
        }
    }

    // MARK: - Dust backend

    private func dustJSON(_ string: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    @Test("summarize falls back to raw transcript when Dust credentials are missing")
    func dustFallbackWithoutCredentials() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "dust"

        let result = try await MeetingSummaryClient.summarize(
            transcript: "Hello world",
            meetingTitle: "Test",
            config: config
        )

        #expect(result.contains("## Raw Transcript"))
        #expect(result.contains("Hello world"))
    }

    @Test("summarize falls back to raw transcript when Dust credentials are incomplete")
    func dustFallbackWithPartialCredentials() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "dust"
        config.dustAPIKey = "sk-test"
        // workspace ID and agent ID intentionally left empty

        let result = try await MeetingSummaryClient.summarize(
            transcript: "Hello world",
            meetingTitle: "Test",
            config: config
        )

        #expect(result.contains("## Raw Transcript"))
    }

    @Test("generateTitle returns nil for Dust without credentials")
    func dustTitleNilWithoutCredentials() async {
        var config = AppConfig()
        config.meetingSummaryBackend = "dust"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Sprint planning discussion",
            config: config
        )

        #expect(title == nil)
    }

    @Test("summarize surfaces a Dust error when the host is unreachable")
    func dustSummarizeThrowsOnUnreachableHost() async throws {
        setenv("DUST_BASE_URL", "http://localhost:1", 1)
        defer { unsetenv("DUST_BASE_URL") }

        var config = AppConfig()
        config.meetingSummaryBackend = "dust"
        config.dustAPIKey = "sk-test"
        config.dustWorkspaceID = "ws-test"
        config.dustAgentID = "agent-test"

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "My Meeting",
                config: config
            )
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            let summaryError = error as? MeetingSummaryError
            #expect(summaryError != nil)
            if case .requestFailed(let backend, _) = summaryError! {
                #expect(backend == "Dust")
            } else {
                #expect(Bool(false), "Expected requestFailed error, got \(String(describing: error))")
            }
        }
    }

    @Test("DustResponseParser extracts a completed agent answer")
    func dustParserExtractsAnswer() throws {
        let json = try dustJSON("""
        {
          "conversation": {
            "sId": "conv_abc",
            "content": [
              [{"type": "user_message", "content": "raw transcript"}],
              [{"type": "agent_message", "status": "succeeded", "content": "# Notes\\n- shipped"}]
            ]
          }
        }
        """)

        #expect(MeetingSummaryClient.DustResponseParser.agentOutcome(in: json) == .answer("# Notes\n- shipped"))
    }

    @Test("DustResponseParser reports a still-running agent message")
    func dustParserReportsRunning() throws {
        let json = try dustJSON("""
        {"conversation": {"content": [
          [{"type": "user_message", "content": "x"}],
          [{"type": "agent_message", "status": "created"}]
        ]}}
        """)

        #expect(MeetingSummaryClient.DustResponseParser.agentOutcome(in: json) == .running)
    }

    @Test("DustResponseParser reports missing when no agent message exists")
    func dustParserReportsMissing() throws {
        let json = try dustJSON("""
        {"conversation": {"content": [[{"type": "user_message", "content": "x"}]]}}
        """)

        #expect(MeetingSummaryClient.DustResponseParser.agentOutcome(in: json) == .missing)
    }

    @Test("DustResponseParser surfaces a failed agent run")
    func dustParserReportsFailure() throws {
        let json = try dustJSON("""
        {"conversation": {"content": [
          [{"type": "agent_message", "status": "failed", "error": {"message": "tool timeout"}}]
        ]}}
        """)

        #expect(MeetingSummaryClient.DustResponseParser.agentOutcome(in: json) == .failed("tool timeout"))
    }

    @Test("DustResponseParser picks the latest version within a rank")
    func dustParserPicksLatestVersion() throws {
        let json = try dustJSON("""
        {"conversation": {"content": [
          [{"type": "user_message", "content": "x"}],
          [
            {"type": "agent_message", "status": "created"},
            {"type": "agent_message", "status": "succeeded", "content": "final answer"}
          ]
        ]}}
        """)

        #expect(MeetingSummaryClient.DustResponseParser.agentOutcome(in: json) == .answer("final answer"))
    }

    @Test("DustResponseParser extracts the conversation ID from sId")
    func dustParserExtractsConversationID() throws {
        let json = try dustJSON("""
        {"conversation": {"sId": "conv_xyz", "content": []}}
        """)

        #expect(MeetingSummaryClient.DustResponseParser.conversationID(in: json) == "conv_xyz")
    }

    @Test("DustResponseParser handles a numeric id and an unwrapped conversation")
    func dustParserHandlesUnwrappedConversation() throws {
        let json = try dustJSON("""
        {"id": 4321, "content": [[{"type": "agent_message", "status": "succeeded", "content": "notes"}]]}
        """)

        #expect(MeetingSummaryClient.DustResponseParser.conversationID(in: json) == "4321")
        #expect(MeetingSummaryClient.DustResponseParser.agentOutcome(in: json) == .answer("notes"))
    }
}
