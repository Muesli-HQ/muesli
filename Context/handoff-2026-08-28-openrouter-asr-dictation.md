# OpenRouter ASR dictation handoff (2026-08-28)

## Objective

Add OpenRouter as an opt-in hosted dictation provider while keeping Muesli local by default and leaving meeting transcription unchanged.

## Transport decision

- OpenRouter documents `POST /api/v1/audio/transcriptions` with base64 audio and a 60-second upstream timeout, but no realtime STT WebSocket. This implementation therefore uploads the completed WAV after recording stops and uses a 65-second client timeout.
- Hosted dictation now routes through a shared session seam. OpenAI wraps its existing Realtime WebSocket; OpenRouter snapshots its credential and selected model and finalizes from the recorded WAV. A future documented streaming transport can replace the OpenRouter session without changing controller or menu routing.

## Implementation

- `DictationProvider` includes OpenRouter and persists a separate, empty-by-default `open_router_dictation_model`, requiring explicit model selection.
- OpenRouter authentication reuses the shared credential resolver with environment, protected OAuth/manual, and legacy precedence.
- The transcription client sends the selected model and raw base64 WAV, uses the existing OpenRouter app identity header, sanitizes provider errors, supports injected networking, and propagates cancellation.
- Missing authentication or model selection blocks before microphone capture. Successful hosted output bypasses cleanup. Non-cancellation failures fall back to an installed non-streaming local backend; cancellation never triggers fallback.
- Provider and model values are snapshotted in the in-flight hosted session, so settings changes cannot reroute a transcription already being finalized.
- OpenRouter text-summary and transcription catalogs use separate shared caches. The STT catalog is discovered through `output_modalities=transcription`, retains the configured custom ID, and exposes retry after failures.
- Settings reuse the existing OpenRouter account control and add explicit STT model/custom model selection plus the generalized hosted fallback row. The status menu exposes dynamic OpenRouter models and applies provider plus model atomically.
- Hosted model selectors are credential-gated in both Settings and the status menu. With no hosted credentials only Local models are listed; an OpenAI key exposes only OpenAI presets, and an authenticated OpenRouter account exposes only its discovered/custom choices. OpenRouter catalog loading is also suppressed and cleared while unauthenticated.
- OpenRouter model visibility uses the same environment, protected-store, and legacy credential resolution as actual transcription, so a recoverable legacy credential cannot leave working dictation hidden from the UI.
- Transcription catalog loads carry a generation token. A cancelled request from before disconnect cannot clear or overwrite a newer reconnect/reload, while normal catalogs remain cached once per app process with no periodic refresh.
- Disconnecting an actively selected OpenRouter account returns future dictations to Local and retains the chosen OpenRouter model. A dictation that already began through OpenRouter keeps its snapshotted provider, model, and credential and is allowed to finish, matching ordinary mid-dictation provider changes.
- README, privacy, and terms describe optional OpenAI/OpenRouter dictation and the OpenRouter upstream data path while preserving local-by-default language.

## Verification

- Focused OpenRouter dictation suite: 16 tests passed.
- Focused hosted-provider visibility and catalog checks: 26 tests passed.
- OpenRouter OAuth suite: 11 tests passed.
- Provider/config suite: 6 tests passed.
- Full native suite: 1,943 tests across 173 suites passed.
- Changed-file classification, CI shard assignment, update-flow verification with DMG skipped, and `git diff --check` passed.
- Dev lane B was rebuilt through the canonical shared SwiftPM cache, installed with bundle ID `com.muesli.dev.b`, and launched. Both the source and installed LocalVQE runtimes passed completeness validation.
- Three consecutive Dev B dictations using `fish-audio/transcribe-1` completed through OpenRouter with HTTP 200 responses; no local fallback ran.

## Review follow-up

- OpenRouter disconnect now moves dictation to Local and immediately starts preparing the selected local backend while retaining the OpenRouter model for reconnection.
- Standard dictation finalization retains its task and detached hosted session until completion. Cancelling during transcription now cancels the OpenRouter upload, and stale cancellation completion cannot reset a newer dictation.
- Provider changes and account disconnects apply to the next dictation. An active dictation keeps the provider, model, and credential selected when it began; the explicit dictation Cancel action still cancels its upload, and cancelled or stale work is barred from starting local fallback.

## Deferred scope

- A realtime OpenRouter transport remains deferred until OpenRouter documents a WebSocket STT API.
- Audio splitting, provider-specific language/options, usage/cost UI, and synthetic paid connection tests remain out of scope.
