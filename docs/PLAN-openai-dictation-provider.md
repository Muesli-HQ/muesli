# Plan: OpenAI Speech-to-Text as a Dictation Provider

## Design

Muesli's dictation pipeline is: hotkey → record WAV → `TranscriptionCoordinator.transcribeDictation(at:backend:)` → insert at cursor. Only the transcription backend needs to change.

A pluggable **dictation provider** layer is added above the existing local model selection:

- `DictationProvider` enum: `.local` (default, unchanged) or `.openAI`.
- The existing `stt_backend`/`stt_model` config keys keep representing the **local** model selection and are never overwritten by the provider switch, so local behavior is fully preserved and the "fallback to selected local model" requirement is trivially satisfied.
- At dictation time the effective backend is chosen:
  - `.local` → the existing `selectedBackend`.
  - `.openAI` → a dynamically-built `BackendOption(backend: "openai", model: <configured model>)` routed to a new OpenAI transcription client.
- The OpenAI API key is stored in the macOS Keychain (new `OpenAIKeychainStore`), never in `config.json`.

## New files

| File | Purpose |
|---|---|
| `DictationProvider.swift` | `DictationProvider` enum + transcription model presets/constants. |
| `OpenAIKeychainStore.swift` | Secure Keychain read/write/delete for the OpenAI dictation API key. |
| `OpenAITranscriptionClient.swift` | Multipart POST to `https://api.openai.com/v1/audio/transcriptions`, connection test, `OpenAIDictationConfiguration`, error type. |

## Modified files

| File | Changes |
|---|---|
| `Models.swift` | `AppConfig`: `dictationProvider`, `openaiDictationModel`, `openaiDictationFallbackToLocal` (+ CodingKeys + decode + resolver). `BackendOption.openAITranscription(model:)`, `isDownloaded` → true for `openai`, `supportsMeetingTranscription` → false for `openai`. |
| `AppState.swift` | `var dictationProvider: DictationProvider`. |
| `TranscriptionRuntime.swift` | `preloadRequired` case `openai` (no-op). `route` case `openai`. `transcribeWithOpenAI(url:model:apiKey:)`. `transcribeDictation` gains optional `openAIConfiguration` param. |
| `MuesliController.swift` | `selectedDictationProvider`, init/`updateConfig` resolution, `selectDictationProvider(_:)`, Keychain accessors, `testOpenAIConnection()`, startup preload short-circuit for OpenAI, `finishStandardDictationStop` effective-backend selection + fallback-to-local on OpenAI failure, status-bar provider menu selectors. |
| `StatusBarController.swift` | New "Dictation Provider" submenu (Local / OpenAI). |
| `SettingsView.swift` | "Provider" menu in the Speech Recognition section; OpenAI config rows (Keychain API key, model menu, test connection, fallback toggle) when OpenAI is selected. |

## Dictation flow changes (in `finishStandardDictationStop`)

1. Effective backend = OpenAI option if provider is `.openAI` and a key is configured, else `selectedBackend`.
2. If provider is `.openAI` but no key is configured → clear message, no silent fallback.
3. On transcription failure with OpenAI and `openaiDictationFallbackToLocal == true` → retry with `selectedBackend` (local), log it.
4. Everything else (paste, clipboard restore, history, indicator, cleanup, custom words) is unchanged.

## Out of scope

Realtime/streaming STT, GPT Realtime, live partials, grammar correction, rewriting, TTS, meeting transcription/summaries, and any change to local models.

## Verification

- `swift build --package-path native/MuesliNative` — **Build complete** (only pre-existing warnings).
- `swift test --package-path native/MuesliNative` — **1491 tests / 146 suites passed**, including 10 new `OpenAIDictationProviderTests`.
- Live end-to-end dictation (GUI + mic + real OpenAI key) not exercised in this environment.
