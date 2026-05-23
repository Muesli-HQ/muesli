# Design Spec: Custom LLM Backend for Meeting Summaries

Provide a unified "Custom LLM" backend configuration option in Muesli to support generic OpenAI-compatible endpoints (e.g., DeepSeek, Groq, LM Studio, vLLM) and Anthropic Messages endpoints natively.

## User Review Required

> [!NOTE]
> This design introduces a single new `customLLM` option to the summary backend configuration dropdown, accompanied by setting fields for API Format, Base URL, API Key, and Model ID.

## Proposed Changes

### Component: Models and Configuration

#### [MODIFY] [Models.swift](file:///Users/ahegde/projects/muesli/native/MuesliNative/Sources/MuesliNativeApp/Models.swift)

- Add a new static `customLLM` property to `MeetingSummaryBackendOption`:
  ```swift
  static let customLLM = MeetingSummaryBackendOption(
      backend: "custom_llm",
      label: "Custom LLM"
  )
  ```
- Append `.customLLM` to the static `all` array in `MeetingSummaryBackendOption`.
- Add `CustomLLMFormat` enum representing `.openAI` and `.anthropic` APIs.
- Add properties to `AppConfig`:
  - `customLLMURL: String = ""`
  - `customLLMAPIKey: String = ""`
  - `customLLMModel: String = ""`
  - `customLLMFormat: String = CustomLLMFormat.openAI.rawValue`
- Update `CodingKeys` and `init(from:)` decoder in `AppConfig` to handle these properties safely.

### Component: Settings UI

#### [MODIFY] [SettingsView.swift](file:///Users/ahegde/projects/muesli/native/MuesliNative/Sources/MuesliNativeApp/SettingsView.swift)

- Render form fields when `selectedMeetingSummaryBackend == .customLLM`:
  - **API Format**: Dropdown menu choosing between OpenAI-compatible and Anthropic formats.
  - **Base URL**: Text field for custom endpoint base URL.
  - **API Key**: Secure text field for API key.
  - **Model**: Text field for model name/ID.

### Component: Summary Execution Client

#### [MODIFY] [MeetingSummaryClient.swift](file:///Users/ahegde/projects/muesli/native/MuesliNative/Sources/MuesliNativeApp/MeetingSummaryClient.swift)

- Route custom LLM backend requests to `summarizeWithCustomLLM` and `generateTitleWithCustomLLM`.
- Implement `resolveCustomLLMURL(config: AppConfig, format: CustomLLMFormat)` helper to expand empty or partial base URLs to full endpoints.
- Implement `extractAnthropicText(from payload: [String: Any]) -> String?` for parsing Anthropic JSON responses.
- Implement API payload construction and POST request logic matching each API format (OpenAI Chat Completions / Anthropic Messages).

## Verification Plan

### Automated Tests
- Run `swift test --package-path native/MuesliNative` to verify no regressions in existing tests.
- Add unit tests in `MeetingSummaryClientTests.swift` and `ModelsTests.swift` covering URL resolution, custom LLM routing, and response extraction.

### Manual Verification
- Launch the application dev build: `./scripts/dev-test.sh`
- Open Settings -> Meeting Summaries tab.
- Set Summary Backend to "Custom LLM".
- Toggle between formats and verify correct placeholders and visibility.
- Test endpoint calls with a mock server or local Ollama/LM Studio OpenAI-compatible endpoint.
