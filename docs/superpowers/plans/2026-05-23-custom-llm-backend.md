# Custom LLM Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a customizable "Custom LLM" summary backend that natively supports OpenAI-compatible chat completions and Anthropic Messages endpoints.

**Architecture:** Extend AppConfig configuration properties and JSON serialization to store Custom LLM attributes. Implement Custom LLM client execution with URL auto-resolution and custom parsing helpers, then render configuration inputs in SettingsView.

**Tech Stack:** Swift, SwiftUI, XCTest/Testing framework.

---

### Task 1: Add Custom LLM to Configuration Model

**Files:**
- Modify: `native/MuesliNative/Sources/MuesliNativeApp/Models.swift`
- Modify: `native/MuesliNative/Tests/MuesliTests/ModelsTests.swift`

- [ ] **Step 1: Write failing tests**

Add these tests to `MeetingSummaryBackendTests` and `AppConfigTests` in [ModelsTests.swift](file:///Users/ahegde/projects/muesli/native/MuesliNative/Tests/MuesliTests/ModelsTests.swift):
```swift
    // Under MeetingSummaryBackendTests
    @Test("customLLM option exists and resolves")
    func customLLMOption() {
        #expect(MeetingSummaryBackendOption.all.contains(.customLLM))
        #expect(MeetingSummaryBackendOption.customLLM.backend == "custom_llm")
        #expect(MeetingSummaryBackendOption.resolved("custom_llm") == .customLLM)
    }

    // Under AppConfigTests
    @Test("custom LLM default config values")
    func customLLMDefaults() {
        let config = AppConfig()
        #expect(config.customLLMURL == "")
        #expect(config.customLLMAPIKey == "")
        #expect(config.customLLMModel == "")
        #expect(config.customLLMFormat == "openai")
    }

    @Test("custom LLM serialization round-trip")
    func customLLMSerialization() throws {
        var config = AppConfig()
        config.customLLMURL = "http://localhost:9000"
        config.customLLMAPIKey = "custom-key-xyz"
        config.customLLMModel = "my-custom-model"
        config.customLLMFormat = "anthropic"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

        #expect(decoded.customLLMURL == "http://localhost:9000")
        #expect(decoded.customLLMAPIKey == "custom-key-xyz")
        #expect(decoded.customLLMModel == "my-custom-model")
        #expect(decoded.customLLMFormat == "anthropic")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path native/MuesliNative --filter ModelsTests`
Expected: Compile error because `customLLM` and the `AppConfig` properties do not exist.

- [ ] **Step 3: Implement configuration additions**

Modify `Models.swift`:
1. In `struct MeetingSummaryBackendOption`, add:
```swift
    static let customLLM = MeetingSummaryBackendOption(
        backend: "custom_llm",
        label: "Custom LLM"
    )
```
Update `all` and `resolved` in `MeetingSummaryBackendOption`:
```diff
-    static let all: [MeetingSummaryBackendOption] = [.chatGPT, .openAI, .openRouter, .ollama]
+    static let all: [MeetingSummaryBackendOption] = [.chatGPT, .openAI, .openRouter, .ollama, .customLLM]
```
```diff
     static func resolved(_ backend: String?) -> MeetingSummaryBackendOption {
         guard let backend, let option = all.first(where: { $0.backend == backend }) else {
             return .chatGPT
         }
         return option
     }
```

2. Add the `CustomLLMFormat` enum to `Models.swift`:
```swift
enum CustomLLMFormat: String, Codable, CaseIterable {
    case openAI = "openai"
    case anthropic = "anthropic"

    var label: String {
        switch self {
        case .openAI: return "OpenAI-compatible"
        case .anthropic: return "Anthropic Messages"
        }
    }
}
```

3. In `struct AppConfig`, add properties:
```swift
    var customLLMURL: String = ""
    var customLLMAPIKey: String = ""
    var customLLMModel: String = ""
    var customLLMFormat: String = CustomLLMFormat.openAI.rawValue
```

4. Extend `AppConfig.CodingKeys`:
```swift
        case customLLMURL = "custom_llm_url"
        case customLLMAPIKey = "custom_llm_api_key"
        case customLLMModel = "custom_llm_model"
        case customLLMFormat = "custom_llm_format"
```

5. In `AppConfig.init(from decoder: Decoder)`, decode the new values:
```swift
        customLLMURL = (try? c.decode(String.self, forKey: .customLLMURL)) ?? defaults.customLLMURL
        customLLMAPIKey = (try? c.decode(String.self, forKey: .customLLMAPIKey)) ?? defaults.customLLMAPIKey
        customLLMModel = (try? c.decode(String.self, forKey: .customLLMModel)) ?? defaults.customLLMModel
        customLLMFormat = (try? c.decode(String.self, forKey: .customLLMFormat)) ?? defaults.customLLMFormat
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path native/MuesliNative --filter ModelsTests`
Expected: PASS

- [ ] **Step 5: Commit**

Run:
```bash
git add native/MuesliNative/Sources/MuesliNativeApp/Models.swift native/MuesliNative/Tests/MuesliTests/ModelsTests.swift
git commit -m "feat: add Custom LLM fields to AppConfig and backend option list"
```

---

### Task 2: Implement URL Resolution & Text Extraction Helpers

**Files:**
- Modify: `native/MuesliNative/Sources/MuesliNativeApp/MeetingSummaryClient.swift`
- Modify: `native/MuesliNative/Tests/MuesliTests/MeetingSummaryClientTests.swift`

- [ ] **Step 1: Write failing tests**

Add these tests to `MeetingSummaryClientTests` in [MeetingSummaryClientTests.swift](file:///Users/ahegde/projects/muesli/native/MuesliNative/Tests/MuesliTests/MeetingSummaryClientTests.swift):
```swift
    @Test("resolveCustomLLMURL expands paths correctly")
    func resolveCustomLLMURLTest() {
        var config = AppConfig()
        
        // OpenAI Format defaults and custom overrides
        config.customLLMURL = ""
        let openAIDefault = MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)
        #expect(openAIDefault?.absoluteString == "http://localhost:8080/v1/chat/completions")

        config.customLLMURL = "https://myapi.com"
        let openAICustom = MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)
        #expect(openAICustom?.absoluteString == "https://myapi.com/v1/chat/completions")

        config.customLLMURL = "https://myapi.com/v1/"
        let openAICustomSlash = MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .openAI)
        #expect(openAICustomSlash?.absoluteString == "https://myapi.com/v1/chat/completions")

        // Anthropic Format defaults and custom overrides
        config.customLLMURL = ""
        let anthropicDefault = MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)
        #expect(anthropicDefault?.absoluteString == "https://api.anthropic.com/v1/messages")

        config.customLLMURL = "https://myapi.com/anthropic"
        let anthropicCustom = MeetingSummaryClient.resolveCustomLLMURL(config: config, format: .anthropic)
        #expect(anthropicCustom?.absoluteString == "https://myapi.com/anthropic/v1/messages")
    }

    @Test("extractAnthropicText extracts text from response payload")
    func extractAnthropicTextTest() {
        let payload: [String: Any] = [
            "content": [
                ["type": "text", "text": " Hello world! "]
            ]
        ]
        let extracted = MeetingSummaryClient.extractAnthropicText(from: payload)
        #expect(extracted == "Hello world!")

        let emptyPayload: [String: Any] = [:]
        #expect(MeetingSummaryClient.extractAnthropicText(from: emptyPayload) == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path native/MuesliNative --filter MeetingSummaryClientTests`
Expected: Compile error because `resolveCustomLLMURL` and `extractAnthropicText` are not defined.

- [ ] **Step 3: Implement helper methods**

Implement these methods in `MeetingSummaryClient` in `MeetingSummaryClient.swift`:
```swift
    static func resolveCustomLLMURL(config: AppConfig, format: CustomLLMFormat) -> URL? {
        var urlString = config.customLLMURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if format == .anthropic {
            if urlString.isEmpty {
                return URL(string: "https://api.anthropic.com/v1/messages")!
            }
            if !urlString.hasSuffix("/messages") {
                if urlString.hasSuffix("/") {
                    urlString += "v1/messages"
                } else if urlString.hasSuffix("/v1") {
                    urlString += "/messages"
                } else {
                    urlString += "/v1/messages"
                }
            }
        } else {
            if urlString.isEmpty {
                return URL(string: "http://localhost:8080/v1/chat/completions")!
            }
            if !urlString.hasSuffix("/chat/completions") {
                if urlString.hasSuffix("/") {
                    urlString += "chat/completions"
                } else if urlString.hasSuffix("/v1") {
                    urlString += "/chat/completions"
                } else {
                    urlString += "/v1/chat/completions"
                }
            }
        }
        return URL(string: urlString)
    }

    static func extractAnthropicText(from payload: [String: Any]) -> String? {
        guard let content = payload["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { entry -> String? in
            guard (entry["type"] as? String) == "text",
                  let text = entry["text"] as? String, !text.isEmpty else {
                return nil
            }
            return text
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path native/MuesliNative --filter MeetingSummaryClientTests`
Expected: PASS

- [ ] **Step 5: Commit**

Run:
```bash
git add native/MuesliNative/Sources/MuesliNativeApp/MeetingSummaryClient.swift native/MuesliNative/Tests/MuesliTests/MeetingSummaryClientTests.swift
git commit -m "feat: implement URL resolution and text extraction helpers for custom LLM backend"
```

---

### Task 3: Implement Custom LLM Summarization and Title Generation

**Files:**
- Modify: `native/MuesliNative/Sources/MuesliNativeApp/MeetingSummaryClient.swift`
- Modify: `native/MuesliNative/Tests/MuesliTests/MeetingSummaryClientTests.swift`

- [ ] **Step 1: Write failing tests**

Add these tests to `MeetingSummaryClientTests` in [MeetingSummaryClientTests.swift](file:///Users/ahegde/projects/muesli/native/MuesliNative/Tests/MuesliTests/MeetingSummaryClientTests.swift):
```swift
    @Test("summarize routes to custom LLM backend and falls back if no key")
    func routesToCustomLLM() async throws {
        var config = AppConfig()
        config.meetingSummaryBackend = "custom_llm"
        config.customLLMAPIKey = "" // no key

        let result = try await MeetingSummaryClient.summarize(
            transcript: "Test transcript",
            meetingTitle: "My Custom Meeting",
            config: config
        )

        #expect(result.contains("## Raw Transcript"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path native/MuesliNative --filter MeetingSummaryClientTests`
Expected: Compile error because `summarizeWithCustomLLM` and `generateTitleWithCustomLLM` are not implemented.

- [ ] **Step 3: Implement routing and execution functions**

1. Modify `summarize` in `MeetingSummaryClient.swift`:
```swift
        if backend == MeetingSummaryBackendOption.customLLM.backend {
            generatedNotes = try await summarizeWithCustomLLM(
                transcript: transcript,
                meetingTitle: meetingTitle,
                existingNotes: existingNotes,
                manualNotes: manualNotes,
                config: config,
                template: template,
                visualContext: visualContext
            )
        }
```
Inject this block before the `openAI` routing check or similar.

2. Modify `generateTitle` in `MeetingSummaryClient.swift`:
```swift
        if backend == MeetingSummaryBackendOption.customLLM.backend {
            return await generateTitleWithCustomLLM(transcript: excerpt, config: config)
        }
```
Inject this block before the fallback block.

3. Implement `summarizeWithCustomLLM` and `generateTitleWithCustomLLM` in `MeetingSummaryClient.swift`:
```swift
    private static func summarizeWithCustomLLM(
        transcript: String,
        meetingTitle: String,
        existingNotes: String?,
        manualNotes: String?,
        config: AppConfig,
        template: MeetingTemplateSnapshot,
        visualContext: String? = nil
    ) async throws -> String {
        let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
        let apiKey = config.customLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return rawTranscriptFallback(transcript: transcript, meetingTitle: meetingTitle)
        }

        guard let requestURL = resolveCustomLLMURL(config: config, format: format) else {
            throw MeetingSummaryError.backendFailed(backend: "Custom LLM", statusCode: nil, message: "Invalid custom URL: \(config.customLLMURL)")
        }

        let instructions = summaryInstructions(for: template, existingNotes: existingNotes, manualNotes: manualNotes)
        let userPrompt = summaryUserPrompt(
            transcript: transcript,
            meetingTitle: meetingTitle,
            existingNotes: existingNotes,
            manualNotes: manualNotes,
            visualContext: visualContext
        )
        let configuredModel = config.customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty ? (format == .anthropic ? "claude-3-5-sonnet-20241022" : "custom-model") : configuredModel

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if format == .anthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let body: [String: Any] = [
                "model": model,
                "max_tokens": defaultSummaryMaxOutputTokens,
                "system": instructions,
                "messages": [
                    ["role": "user", "content": userPrompt]
                ]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": instructions],
                    ["role": "user", "content": userPrompt]
                ],
                "max_tokens": defaultSummaryMaxOutputTokens
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try validateHTTPResponse(response, data: data, backend: "Custom LLM")
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let text = (format == .anthropic ? extractAnthropicText(from: json) : extractOpenRouterText(from: json)),
                !text.isEmpty
            else {
                if let message = extractErrorMessage(from: data) {
                    throw MeetingSummaryError.backendFailed(backend: "Custom LLM", statusCode: nil, message: message)
                }
                throw MeetingSummaryError.emptyResponse(backend: "Custom LLM")
            }
            return text
        } catch {
            throw summaryRequestError(backend: "Custom LLM", error: error)
        }
    }

    private static func generateTitleWithCustomLLM(transcript: String, config: AppConfig) async -> String? {
        let format = CustomLLMFormat(rawValue: config.customLLMFormat) ?? .openAI
        let apiKey = config.customLLMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return nil }

        guard let requestURL = resolveCustomLLMURL(config: config, format: format) else { return nil }
        let configuredModel = config.customLLMModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = configuredModel.isEmpty ? (format == .anthropic ? "claude-3-5-sonnet-20241022" : "custom-model") : configuredModel

        if format == .anthropic {
            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let body: [String: Any] = [
                "model": model,
                "max_tokens": 100,
                "system": titleInstructions,
                "messages": [
                    ["role": "user", "content": transcript]
                ]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                if let error = json["error"] as? [String: Any] {
                    fputs("[summary] title generation error: \(error["message"] ?? error)\n", stderr)
                    return nil
                }
                return extractAnthropicText(from: json)?
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            } catch {
                fputs("[summary] title generation failed: \(error)\n", stderr)
                return nil
            }
        } else {
            return await callChatCompletions(
                url: requestURL,
                apiKey: apiKey,
                model: model,
                systemPrompt: titleInstructions,
                userPrompt: transcript,
                maxTokens: 100,
                extraHeaders: [:]
            )
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path native/MuesliNative --filter MeetingSummaryClientTests`
Expected: PASS

- [ ] **Step 5: Commit**

Run:
```bash
git add native/MuesliNative/Sources/MuesliNativeApp/MeetingSummaryClient.swift native/MuesliNative/Tests/MuesliTests/MeetingSummaryClientTests.swift
git commit -m "feat: implement Custom LLM summarization and title generation routines"
```

---

### Task 4: Add Custom LLM Option to Settings UI

**Files:**
- Modify: `native/MuesliNative/Sources/MuesliNativeApp/SettingsView.swift`

- [ ] **Step 1: Implement form fields in UI**

Find where backends are rendered in `SettingsView.swift`. After the `ollama` option, insert:
```swift
                } else if appState.selectedMeetingSummaryBackend == .customLLM {
                    settingsRow("API Format", controlWidth: meetingControlWidth) {
                        settingsMenu(
                            selection: CustomLLMFormat(rawValue: appState.config.customLLMFormat)?.label ?? CustomLLMFormat.openAI.label,
                            options: CustomLLMFormat.allCases.map(\.label)
                        ) { label in
                            if let format = CustomLLMFormat.allCases.first(where: { $0.label == label }) {
                                controller.updateConfig { $0.customLLMFormat = format.rawValue }
                            }
                        }
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Base URL", controlWidth: meetingControlWidth) {
                        PastableTextField(
                            text: appState.config.customLLMURL,
                            placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                                ? "https://api.anthropic.com"
                                : "http://localhost:8080/v1",
                            onChange: { val in controller.updateConfig { $0.customLLMURL = val } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("API Key", controlWidth: meetingControlWidth) {
                        PastableSecureField(
                            text: appState.config.customLLMAPIKey,
                            placeholder: "API Key",
                            onChange: { val in controller.updateConfig { $0.customLLMAPIKey = val } }
                        )
                        .frame(height: 22)
                    }
                    Divider().background(MuesliTheme.surfaceBorder)
                    settingsRow("Model", controlWidth: meetingControlWidth) {
                        settingsModelTextField(
                            currentModel: appState.config.customLLMModel,
                            placeholder: appState.config.customLLMFormat == CustomLLMFormat.anthropic.rawValue
                                ? "claude-3-5-sonnet-20241022"
                                : "custom-model-id"
                        ) { val in controller.updateConfig { $0.customLLMModel = val } }
                    }
                    keyStatusRow(key: appState.config.customLLMAPIKey)
```

- [ ] **Step 2: Run compilation check to verify the UI builds successfully**

Run: `swift test --package-path native/MuesliNative`
Expected: PASS (and successful build without compile issues)

- [ ] **Step 3: Commit**

Run:
```bash
git add native/MuesliNative/Sources/MuesliNativeApp/SettingsView.swift
git commit -m "feat: render Custom LLM configurations in settings view"
```
