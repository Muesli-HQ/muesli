---
date: 2026-08-03
title: Add OpenAI Speech-to-Text as a Dictation Provider
files_touched: [muesli_repo/native/MuesliNative/Sources/MuesliNativeApp/DictationProvider.swift, muesli_repo/native/MuesliNative/Sources/MuesliNativeApp/OpenAIKeychainStore.swift, muesli_repo/native/MuesliNative/Sources/MuesliNativeApp/OpenAITranscriptionClient.swift, muesli_repo/native/MuesliNative/Sources/MuesliNativeApp/Models.swift, muesli_repo/native/MuesliNative/Sources/MuesliNativeApp/TranscriptionRuntime.swift, muesli_repo/native/MuesliNative/Sources/MuesliNativeApp/MuesliController.swift, muesli_repo/native/MuesliNative/Sources/MuesliNativeApp/AppState.swift, muesli_repo/native/MuesliNative/Sources/MuesliNativeApp/StatusBarController.swift, muesli_repo/native/MuesliNative/Sources/MuesliNativeApp/SettingsView.swift, muesli_repo/native/MuesliNative/Tests/MuesliTests/ModelsTests.swift, muesli_repo/docs/PLAN-openai-dictation-provider.md]
short_summary: Added OpenAI Speech-to-Text as a pluggable dictation provider in Muesli on branch feature/openai-dictation-provider. Introduced DictationProvider enum (local/openAI), OpenAIKeychainStore (Keychain-backed API key), and OpenAITranscriptionClient (multipart /v1/audio/transcriptions + test connection). Wired routing into TranscriptionCoordinator, provider switching in MuesliController without restart, status-bar Dictation Provider submenu, and Settings UI (key, model, fallback toggle, test). Local model selection preserved as fallback; 1491 tests passed including 10 new OpenAI provider tests.
---

# Session Summary — 2026-08-03

## Detailed Summary

This session implemented the PRD for adding **OpenAI Speech-to-Text as a dictation provider** in the Muesli macOS app (Swift/AppKit/SwiftPM package at `native/MuesliNative`). The repo was cloned from `https://github.com/Muesli-HQ/muesli` into `muesli_repo` (working directory `muesli_neeraj`), and a feature branch `feature/openai-dictation-provider` was created before any changes.

### The problem
Muesli's existing dictation uses local CoreML ASR models (Parakeet, Whisper, Cohere, etc.). The PRD required adding OpenAI as a selectable provider using the user's own OpenAI API key, while leaving the entire existing dictation pipeline untouched (hotkeys, recording, indicator, accessibility permissions, cursor detection, paste/clipboard restore, dictation history, local models).

### Key architecture decision
Rather than injecting OpenAI into the existing `stt_backend`/`stt_model` config (which would have rippled through `BackendOption.all`, `selectedBackend` resolution, Models tab, meeting logic), a separate pluggable **`DictationProvider`** layer was added on top:
- `DictationProvider` enum: `.local` (default) / `.openAI`.
- `stt_backend`/`stt_model` continue to hold only the LOCAL model selection — never overwritten by the provider switch. This trivially satisfies the "fall back to the selected local transcription model" requirement and makes switching back instant.
- At dictation time the effective backend is chosen in `finishStandardDictationStop`: `.local` → existing `selectedBackend`; `.openAI` → a dynamically built `BackendOption(backend: "openai", model: <configured>)` routed through the new OpenAI client.

### New files
- `DictationProvider.swift` — provider enum, labels, `resolved(rawValue:)`.
- `OpenAIKeychainStore.swift` — macOS Keychain storage (`com.muesli.app.openai-dictation`) for the dictation API key, deliberately separate from the summary key in config.json. Uses `kSecUseDataProtectionKeychain`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- `OpenAITranscriptionClient.swift` — `OpenAIDictationConfiguration` (Sendable), `OpenAITranscriptionError` (LocalizedError), multipart `POST /v1/audio/transcriptions` (file/model/response_format=json), `testConnection` via `GET /v1/models`, model presets (`gpt-4o-mini-transcribe` default, `gpt-4o-transcribe`, `whisper-1`) plus custom-model support, `makeMultipartBody` made internal for testability.

### Modified files
- `Models.swift` — AppConfig fields `dictation_provider` (default "local"), `openai_dictation_model`, `openai_dictation_fallback_to_local` (default true) with CodingKeys and graceful `try?` decoding; `resolvedDictationProvider`; `BackendOption.openAITranscription(model:)`, `isOpenAI(_:)`, `isDownloaded` → true for "openai", `supportsMeetingTranscription` → false for "openai".
- `TranscriptionRuntime.swift` — `preloadRequired` no-op case "openai"; `route()` "openai" case calling `transcribeWithOpenAI`; `transcribeDictation` gained optional `openAIConfiguration` param (meeting paths unaffected).
- `MuesliController.swift` — `selectedDictationProvider`, init/`updateConfig`/`syncAppState`/`applyConfigRuntimeSideEffects` sync, `selectDictationProvider(_:)` (switching back to local re-preloads the model), Keychain accessors (`openAIDictationAPIKey`, `setOpenAIDictationAPIKey`), `selectOpenAIDictationModel`, `testOpenAIConnection()`, `openAIFallbackBackend(for:)`, startup preload short-circuit for OpenAI, `selectDictationProviderFromMenu`, and the rewritten `finishStandardDictationStop` effective-backend selection with: missing-key early-return (clean error + temp file cleanup), and OpenAI-failure → local fallback retry when enabled (with status/indicator notice). Telemetry now reports the effective backend + provider.
- `AppState.swift` — `dictationProvider` observable.
- `StatusBarController.swift` — new "Dictation Provider" submenu (Local / OpenAI).
- `SettingsView.swift` — "Provider" menu at top of the Speech Recognition section, plus OpenAI rows (Keychain API key field, model menu, "Fall back to local" toggle, "Test connection" with idle/testing/connected/failed states). Model row gets a "used for fallback" description when OpenAI is active.
- `Tests/MuesliTests/ModelsTests.swift` — new `OpenAIDictationProviderTests` suite (10 tests).

### Verification (important — see Open Questions for the build workaround)
- `swift build --package-path native/MuesliNative --scratch-path /tmp/muesli-spm` → **Build complete** (only pre-existing warnings).
- `swift test --package-path native/MuesliNative --scratch-path /tmp/muesli-spm` → **1491 tests / 146 suites passed, 0 failures**, including the 10 new tests and the pre-existing `allBackendsCovered` / AppConfig round-trip tests that the changes touch.
- Standalone `swiftc -typecheck` of the three new files and a logic harness for multipart-body/model-normalization all passed.
- NOT tested: live end-to-end dictation (GUI app + mic + macOS permissions + a real OpenAI API key were not available in this environment). No API key exists in env; the client was built but not exercised against the live API.

### Build environment notes (how the build was unblocked)
Initial `swift package resolve` / `swift build` hung indefinitely at "Downloading binary artifact" with zero network sockets, while git and curl worked. The SwiftPM binary artifact downloader was stalled. Workaround that succeeded:
1. `swift build` failed/timed out with default `.build`; the `.build` dir was removed (`rm -rf native/MuesliNative/.build`).
2. The two binary artifacts (`CLiteRTLM_mac.xcframework.zip` ~42MB from google-ai-edge/LiteRT-LM, `Sparkle-for-Swift-Package-Manager.zip` ~11MB) were downloaded with `curl` into `/tmp` and placed into `~/Library/Caches/org.swift.swiftpm/artifacts/mueslinative/unspecified/` and `artifacts/sparkle/2.9.3/` (checksum for CLiteRTLM verified: `ec9ffe230dc39117a7fc8933b1cc15910454027fee6d3041534ab7cf17313981`).
3. Using `--scratch-path /tmp/muesli-spm` (a clean scratch path, per the repo's `scripts/muesli_spm_cache.sh` convention) avoided the corrupt build state and completed the build in ~120s.
These cache entries remain on disk and should make future builds in this environment fast.

### Current state
All changes are uncommitted working-tree edits on branch `feature/openai-dictation-provider`. A plan doc was written to `docs/PLAN-openai-dictation-provider.md`. Per the workflow policy, no commit was made because the user did not explicitly request one.

## Open Questions
- **Live end-to-end validation**: Recorded-audio → OpenAI transcription → cursor insertion has not been exercised (needs the running MuesliDev GUI, mic/accessibility permissions, and a real OpenAI API key). Should be smoke-tested with `./scripts/dev-test.sh` before merging.
- **`makeMultipartBody` visibility**: It was widened from `private` to `internal` to enable the standalone logic harness. Consider whether to revert to `private` or keep it for unit testing.
- **Keychain vs existing `openAIAPIKey` config**: The dictation key is a separate Keychain entry (`com.muesli.app.openai-dictation`) from the meeting-summary key in config.json. Confirm this split is acceptable product behavior (users must enter the key twice if they use both features).
- **Fallback UX**: When OpenAI fails and fallback is enabled, the app shows a transient status/indicator notice but does not persist which provider produced the transcript. Decide whether dictation history should record the provider.
- **Commit/PR**: Changes are staged in the working tree only. Commit and open a PR when the user requests it.

## Decisions Made
- **Separate `DictationProvider` layer instead of injecting "openai" into `stt_backend`/`stt_model`** — avoids touching `BackendOption.all`, `selectedBackend` resolution, Models tab, and meeting logic; preserves local selection untouched and satisfies the fallback requirement cleanly. Keeps "no changes to local transcription models" in scope.
- **Dedicated Keychain store for the dictation key** (`OpenAIKeychainStore`) — PRD required the API key be stored securely; separate service keeps it independent of the summary key and is removable without affecting other features.
- **Self-contained `OpenAITranscriptionClient`** — thin client reusable by future OpenAI speech features (meetings, TTS) without touching dictation code; model is config-driven so future models need no code change.
- **Effective backend chosen in `finishStandardDictationStop`** with test mode always forcing local — onboarding dictation tests keep using local models; only the real dictation path consults the provider.
- **Missing key with fallback disabled → hard error (no silent local fallback)**; with fallback enabled → local + notice. Clearer than silently switching providers.
- **Meeting transcription excludes OpenAI** (`supportsMeetingTranscription == false`) — meeting transcription was explicitly out of scope.
