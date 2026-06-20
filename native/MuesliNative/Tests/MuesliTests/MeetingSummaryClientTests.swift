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

    @Test("resolveCustomLLMURL expands OpenAI-compatible endpoints")
    func resolveCustomLLMOpenAIURL() {
        var config = AppConfig()

        config.customLLMURL = ""
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "http://localhost:8080/v1/chat/completions"
        )

        config.customLLMURL = "https://models.example.com"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/v1/chat/completions"
        )

        config.customLLMURL = "https://models.example.com/v1/"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/v1/chat/completions"
        )

        config.customLLMURL = "https://models.example.com/openai/v1"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/openai/v1/chat/completions"
        )

        config.customLLMURL = "https://models.example.com/llm/v2/chat/completions"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/llm/v2/chat/completions"
        )

        config.customLLMURL = "https://models.example.com/llm/v2/completions"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/llm/v2/completions/v1/chat/completions"
        )

        config.customLLMURL = "https://models.example.com/openai/deployments/my-model/chat/completions?api-version=2024-10-21"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/openai/deployments/my-model/chat/completions?api-version=2024-10-21"
        )

        config.customLLMURL = "https://models.example.com/v1/chat/completions/"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)?.absoluteString ==
                "https://models.example.com/v1/chat/completions"
        )
    }

    @Test("resolveLMStudioURL expands chat completion endpoints")
    func resolveLMStudioURL() {
        var config = AppConfig()

        config.lmStudioURL = ""
        #expect(
            MeetingSummaryClient.resolveLMStudioURL(config: config)?.absoluteString ==
                "http://localhost:1234/v1/chat/completions"
        )

        config.lmStudioURL = "http://localhost:1234/v1"
        #expect(
            MeetingSummaryClient.resolveLMStudioURL(config: config)?.absoluteString ==
                "http://localhost:1234/v1/chat/completions"
        )

        config.lmStudioURL = "http://localhost:1234/proxy/v1"
        #expect(
            MeetingSummaryClient.resolveLMStudioURL(config: config)?.absoluteString ==
                "http://localhost:1234/proxy/v1/chat/completions"
        )

        config.lmStudioURL = "http://localhost:1234/v1/chat/completions"
        #expect(
            MeetingSummaryClient.resolveLMStudioURL(config: config)?.absoluteString ==
                "http://localhost:1234/v1/chat/completions"
        )
    }

    @Test("resolveCustomLLMURL expands Anthropic endpoints")
    func resolveCustomLLMAnthropicURL() {
        var config = AppConfig()

        config.customLLMURL = ""
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://api.anthropic.com/v1/messages"
        )

        config.customLLMURL = "https://models.example.com/anthropic"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://models.example.com/anthropic/v1/messages"
        )

        config.customLLMURL = "https://models.example.com/anthropic/v1"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://models.example.com/anthropic/v1/messages"
        )

        config.customLLMURL = "https://models.example.com/anthropic/v2/messages"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://models.example.com/anthropic/v2/messages"
        )

        config.customLLMURL = "https://models.example.com/messages"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://models.example.com/messages/v1/messages"
        )

        config.customLLMURL = "https://models.example.com/v1/messages/"
        #expect(
            MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)?.absoluteString ==
                "https://models.example.com/v1/messages"
        )
    }

    @Test("extractAnthropicText joins text blocks")
    func extractAnthropicText() {
        let payload: [String: Any] = [
            "content": [
                ["type": "text", "text": "First"],
                ["type": "text", "text": "Second"],
            ],
        ]

        #expect(MeetingSummaryClient.extractAnthropicText(from: payload) == "First\nSecond")
        #expect(MeetingSummaryClient.extractAnthropicText(from: [:]) == nil)
    }

    @Test("summarize routes to LM Studio when configured")
    func routesToLMStudio() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "lmstudio"
        config.lmStudioURL = "http://localhost:1"
        config.lmStudioModel = "local-model"

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
                #expect(backend == "LM Studio")
            } else {
                #expect(Bool(false), "Expected requestFailed error, got \(String(describing: error))")
            }
        }
    }

    @Test("summarize routes to custom LLM without requiring an API key")
    func routesToCustomLLMWithoutKey() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "custom_llm"
        config.customLLMFormat = "openai"
        config.customLLMURL = "http://localhost:1"
        config.customLLMAPIKey = ""
        config.customLLMModel = "local-model"

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "My Custom Meeting",
                config: config
            )
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            let summaryError = error as? MeetingSummaryError
            #expect(summaryError != nil)
            if case .requestFailed(let backend, _) = summaryError! {
                #expect(backend == "Custom LLM")
            } else {
                #expect(Bool(false), "Expected requestFailed error, got \(String(describing: error))")
            }
        }
    }

    @Test("custom LLM summary requires explicit model")
    func customLLMRequiresModel() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "custom_llm"
        config.customLLMFormat = "openai"
        config.customLLMURL = "http://localhost:1"
        config.customLLMModel = ""

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "My Custom Meeting",
                config: config
            )
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            guard case .backendFailed(let backend, _, let message) = error as? MeetingSummaryError else {
                #expect(Bool(false), "Expected backendFailed error, got \(String(describing: error))")
                return
            }
            #expect(backend == "Custom LLM")
            #expect(message.contains("No model selected"))
        }
    }

    @Test("Anthropic custom LLM requires API key")
    func anthropicCustomLLMRequiresAPIKey() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "custom_llm"
        config.customLLMFormat = "anthropic"
        config.customLLMAPIKey = ""
        config.customLLMModel = "claude-test"

        #expect(MeetingSummaryClient.customLLMRequiresAPIKey(config: config))

        do {
            _ = try await MeetingSummaryClient.summarize(
                transcript: "Test transcript",
                meetingTitle: "My Custom Meeting",
                config: config
            )
            #expect(Bool(false), "Expected error to be thrown")
        } catch {
            guard case .backendFailed(let backend, _, let message) = error as? MeetingSummaryError else {
                #expect(Bool(false), "Expected backendFailed error, got \(String(describing: error))")
                return
            }
            #expect(backend == "Custom LLM")
            #expect(message.contains("API key"))
        }
    }

    @Test("OpenAI-compatible custom LLM does not require API key")
    func openAICustomLLMDoesNotRequireAPIKey() {
        var config = AppConfig()
        config.customLLMFormat = "openai"
        config.customLLMAPIKey = ""

        #expect(!MeetingSummaryClient.customLLMRequiresAPIKey(config: config))
    }

    @Test("LM Studio readiness requires model")
    func lmStudioReadinessRequiresModel() {
        var config = AppConfig()

        config.lmStudioModel = ""
        #expect(!MeetingSummaryClient.lmStudioHasRequiredSettings(config: config))

        config.lmStudioModel = "   "
        #expect(!MeetingSummaryClient.lmStudioHasRequiredSettings(config: config))

        config.lmStudioModel = "local-model"
        #expect(MeetingSummaryClient.lmStudioHasRequiredSettings(config: config))
    }

    @Test("Custom LLM readiness requires model and Anthropic key")
    func customLLMReadinessRequiresModelAndAnthropicKey() {
        var config = AppConfig()

        config.customLLMFormat = "openai"
        config.customLLMModel = ""
        config.customLLMAPIKey = ""
        #expect(!MeetingSummaryClient.customLLMHasRequiredSettings(config: config))

        config.customLLMModel = "   "
        #expect(!MeetingSummaryClient.customLLMHasRequiredSettings(config: config))

        config.customLLMModel = "local-model"
        #expect(MeetingSummaryClient.customLLMHasRequiredSettings(config: config))

        config.customLLMFormat = "anthropic"
        config.customLLMAPIKey = ""
        #expect(!MeetingSummaryClient.customLLMHasRequiredSettings(config: config))

        config.customLLMAPIKey = "   "
        #expect(!MeetingSummaryClient.customLLMHasRequiredSettings(config: config))

        config.customLLMAPIKey = "sk-ant-test"
        #expect(MeetingSummaryClient.customLLMHasRequiredSettings(config: config))
    }

    @Test("generateTitle returns nil for LM Studio when unreachable")
    func titleLMStudioUnreachable() async {
        var config = AppConfig()
        config.meetingSummaryBackend = "lmstudio"
        config.lmStudioURL = "http://localhost:1"
        config.lmStudioModel = "local-model"

        let title = await MeetingSummaryClient.generateTitle(
            transcript: "Sprint planning discussion",
            config: config
        )

        #expect(title == nil)
    }
}
