import Foundation
import Testing
import MuesliCore
@testable import MuesliNativeApp

@Suite("Quill assistant")
struct QuillAssistantTests {
    @Test func expandedHistoryReloadsForFollowUpsAndLateQuestions() {
        var turn = QuillHistoryTurn(id: UUID(), question: nil, answer: "Answer", timestamp: "test", backend: "test", model: "test")
        let initial = QuillTimelineLoadKey(expanded: true, turnCount: 1, preview: [turn])
        turn.question = "Late question"
        #expect(initial != QuillTimelineLoadKey(expanded: true, turnCount: 1, preview: [turn]))
        #expect(initial != QuillTimelineLoadKey(expanded: true, turnCount: 2, preview: [turn]))
        #expect(QuillTimelineLoadKey(expanded: false, turnCount: 3, preview: []) !=
            QuillTimelineLoadKey(expanded: true, turnCount: 3, preview: []))
    }

    @Test func quillCleanupSuppressesDebugContentLogging() async {
        await TranscriptCleanupDebugLogger.$suppressContentLogging.withValue(true) {
            #expect(!TranscriptCleanupDebugLogger.isEnabled)
            let coordinator = TranscriptionCoordinator()
            _ = await coordinator.finalizeQuillQuestion("Synthetic question", backend: .parakeetUnified, config: AppConfig())
            #expect(TranscriptCleanupDebugLogger.suppressContentLogging)
        }
        #expect(!TranscriptCleanupDebugLogger.suppressContentLogging)
    }

    @Test func opaqueClipboardSelectionRequiresRangeForEditing() {
        #expect(!QuillAssistantTargetPolicy.isEditable(role: "AXTextArea", valueWritable: true,
            selectionWritable: true, explicitlyEditable: true, usesClipboardFallback: true, hasSelectionRange: false))
        #expect(QuillAssistantTargetPolicy.isEditable(role: "AXTextArea", valueWritable: true,
            selectionWritable: true, explicitlyEditable: true, usesClipboardFallback: true, hasSelectionRange: true))
    }

    @Test func freshQuillSettingsUseNativeGemmaAndKeepExplicitLegacySelections() throws {
        let defaults = AppConfig()
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(defaults.quilBackend == TranscriptCleanupBackendOption.gemma4LiteRT.backend)
        #expect(decoded.quilBackend == defaults.quilBackend)
        #expect(decoded.quilModel == Gemma4LiteRTModel.e2b.repoID)
        let legacy = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"quil_backend":"local"}"#.utf8))
        #expect(legacy.quilBackend == TranscriptCleanupBackendOption.local.backend)
    }

    @Test func oversizedSelectionStillAllowsAnswerButNeverPartialEdit() throws {
        for backend in [TranscriptCleanupBackendOption.gemma4LiteRT, .hosted(.openAI)] {
            let bounded = request(selection: String(repeating: "a", count: 25_000)).bounded(for: backend)
            #expect(bounded.selectionTruncated)
            #expect(try bounded.prompt().contains("\"selection_truncated\":true"))
            #expect(bounded.targetID == nil)
            #expect(bounded.tools.count == 1)
            try QuilModelPolicy.validate(selectedText: bounded.selectedText, backend: backend, model: "test")
            #expect(try bounded.decode(name: "reply", arguments: #"{"text":"Answer"}"#) == .reply("Answer"))
            #expect(throws: QuillAssistantError.self) {
                try bounded.decode(name: "replace_selection", arguments: #"{"text":"Edit","target_id":"current"}"#)
            }
        }
    }

    @Test func disconnectUsesNativeModelOrDisablesQuill() {
        for available in [Gemma4LiteRTModel.e2b, nil] {
            var config = AppConfig()
            config.enableQuilMode = true
            QuillAssistantModelPolicy.applyDisconnectedProviderFallback(to: &config, availableModel: available)
            #expect(config.quilBackend == TranscriptCleanupBackendOption.gemma4LiteRT.backend)
            #expect(config.quilModel == Gemma4LiteRTModel.e2b.rawValue)
            #expect(config.enableQuilMode == (available != nil))
        }
    }

    @Test func questionFinalizationSharesDictationDictionary() async {
        let coordinator = TranscriptionCoordinator()
        var config = AppConfig()
        config.customWords = [.init(word: "muesly", replacement: "muesli", matchingThreshold: 1)]
        let result = await coordinator.finalizeQuillQuestion("Ask muesly", backend: .parakeetUnified, config: config)
        #expect(result == "Ask muesli")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUESLI_QUILL_SYNTHETIC_AUDIO"] != nil))
    func repeatedLocalQuestionTranscription() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MUESLI_QUILL_SYNTHETIC_AUDIO"])
        let coordinator = TranscriptionCoordinator()
        try await coordinator.preloadRequired(backend: .parakeetUnified, enablePostProcessor: false, includeMeetingHelpers: false)
        let audio = try WavReader.readFloatMonoWAV(from: URL(fileURLWithPath: path))
        for _ in 0..<3 {
            let start = Date()
            let recognition = try coordinator.makeQuillQuestionRecognition(backend: .parakeetUnified,
                config: AppConfig(), directAudio: true, onUpdate: { _ in }, onFailure: { _ in })
            recognition.append(audio.samples)
            let text = try await recognition.finish(recordedURL: URL(fileURLWithPath: path))
            print("Synthetic selected-ASR question seconds=\(Date().timeIntervalSince(start))")
            #expect(text.lowercased().contains("capital"))
        }
    }

    func request(selection: String = "", target: String? = "current") -> QuillAssistantRequest {
        .init(instruction: "What does this mean?", selectedText: selection, targetID: target, context: nil, history: [])
    }
    @Test func readableSelectionIsNotAnEditTarget() {
        #expect(!QuillAssistantTargetPolicy.isEditable(role: "AXTextArea", valueWritable: false,
            selectionWritable: false, explicitlyEditable: false))
        #expect(!QuillAssistantTargetPolicy.isEditable(role: "AXSlider", valueWritable: true,
            selectionWritable: false, explicitlyEditable: false))
        #expect(QuillAssistantTargetPolicy.isEditable(role: "AXTextField", valueWritable: true,
            selectionWritable: false, explicitlyEditable: false))
        #expect(QuillAssistantTargetPolicy.isEditable(role: "AXWebArea", valueWritable: false,
            selectionWritable: false, explicitlyEditable: true))
    }
    @Test func focusDoesNotForceEditing() throws {
        let selected = request(selection: "A paragraph")
        #expect(try selected.decode(name: "reply", arguments: #"{"text":"An explanation."}"#) == .reply("An explanation."))
        #expect(selected.tools.compactMap { $0["name"] as? String } == ["reply", "replace_selection"])
        #expect(request().tools.compactMap { $0["name"] as? String } == ["reply", "insert_text"])
        #expect(request(target: nil).tools.compactMap { $0["name"] as? String } == ["reply"])
    }
    @Test func editsRequireCurrentTargetAndCorrectOperation() throws {
        let args = #"{"text":"New text","target_id":"current"}"#
        #expect(try request().decode(name: "insert_text", arguments: args) == .insert("New text"))
        #expect(try request(selection: "Old").decode(name: "replace_selection", arguments: args) == .replace("New text"))
        #expect(throws: (any Error).self) { try request(target: nil).decode(name: "insert_text", arguments: args) }
        #expect(throws: (any Error).self) { try request(target: "new").decode(name: "insert_text", arguments: args) }
        #expect(throws: (any Error).self) { try request(selection: "Old").decode(name: "insert_text", arguments: args) }
        #expect(throws: (any Error).self) { try request().decode(name: "replace_selection", arguments: args) }
        #expect(throws: (any Error).self) { try request().decode(name: "shell", arguments: args) }
    }
    @Test func rejectsMalformedOrMultipleCalls() throws {
        #expect(throws: (any Error).self) { try request().decode(name: "reply", arguments: #"{"text":"answer","target_id":"current"}"#) }
        #expect(throws: (any Error).self) { try request().decode(name: "reply", arguments: #"{"text":" "}"#) }
        #expect(throws: (any Error).self) { try request().decodeNative(#"{"tool_calls":[]}"#) }
        let call: [String: Any] = ["function": ["name": "insert_text", "arguments": ["text": "Hello", "target_id": "current"]]]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: ["tool_calls": [call, call]]), as: UTF8.self)
        #expect(throws: (any Error).self) { try request().decodeNative(raw) }
    }
    @Test func nativeToolDialectsAndTruncation() throws {
        let chat = Data(#"{"choices":[{"finish_reason":"tool_calls","message":{"tool_calls":[{"function":{"name":"insert_text","arguments":"{\"text\":\"Hello\",\"target_id\":\"current\"}"}}]}}]}"#.utf8)
        #expect(try QuillAssistantClient.decode(chat, request: request(), anthropic: false, ollama: false) == .insert("Hello"))
        let anthropic = Data(#"{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"reply","input":{"text":"Answer"}}]}"#.utf8)
        #expect(try QuillAssistantClient.decode(anthropic, request: request(), anthropic: true, ollama: false) == .reply("Answer"))
        let truncated = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"Partial"}}]}"#.utf8)
        #expect(throws: (any Error).self) { try QuillAssistantClient.decode(truncated, request: request(), anthropic: false, ollama: false) }
        let ollama = Data(#"{"done":true,"done_reason":"stop","message":{"content":"Answer"}}"#.utf8)
        #expect(try QuillAssistantClient.decode(ollama, request: request(), anthropic: false, ollama: true) == .reply("Answer"))
    }
    @Test func quillDoesNotChangeMeetingAnswerFormat() throws {
        let base = MeetingTextGenerationRequest(system: "system", user: "user", config: AppConfig())
        var wire = MeetingNativeToolRequest(base: base, inputItems: Data("[]".utf8),
            tools: Data("[]".utf8), allowTools: true)
        #expect(try MeetingNativeToolTransport.requestBody(wire, stream: false)["text"] != nil)
        wire.requiresMeetingAnswerFormat = false
        let body = try MeetingNativeToolTransport.requestBody(wire, stream: false)
        #expect(body["text"] == nil)
        #expect(body["tool_choice"] as? String == "auto")
    }

    @Test func boundedPortableHistoryAndExplicitReset() throws {
        var conversation = QuillAssistantConversation()
        for index in 0..<20 { conversation.append(instruction: "Question \(index)", response: String(repeating: "a", count: 3000)) }
        #expect(conversation.turns.count == 2)
        #expect(conversation.turns.last?.instruction == "Question 19")
        let next = QuillAssistantRequest(instruction: "Explain that further", selectedText: "", targetID: nil, context: nil, history: conversation.turns)
        #expect(try next.prompt().contains("Question 19"))
        #expect(next.tools.count == 1)
        conversation.reset()
        #expect(conversation.turns.isEmpty)
    }
}
