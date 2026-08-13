# Handoff — Nemotron 3.5 Multilingual ASR backend

**Date:** 2026-06-22
**Branch:** `claude/nemotron-asr-streaming-msek2t` (pushed to `origin` = github.com/prasadsunny1/muesli)
**HEAD:** `22c1049f` · 8 commits ahead of `main` · **all pushed**, no PR opened yet
**Status:** Feature complete + code-reviewed + refactored. Builds clean, full suite green at the time of this handoff (1002 tests / 114 suites; repo-wide count has since increased on `main`). English transcription validated end-to-end on the real model. **Live multilingual (Hindi) mic test still pending** (needs a real mic + a rebuild).

---

## What this adds

The supported local Nemotron ASR backend, **`nemotron35`**, shipping NVIDIA Nemotron 3.5 multilingual streaming RNNT (via FluidInference's CoreML conversion). The older English-only `nemotron` app backend has been removed to avoid two confusing Nemotron choices. Plus: hold-to-talk, an in-app language picker, an upstream model-update check, and a dev-signing fix.

---

## Commits (newest first)

```
22c1049 Add Nemotron 3.5 language picker and upstream-update check
0d1a0e2 Extract shared NemotronRNNTEngine; dedup EN + 3.5 backends
a7b6219 Code-review fixes: harden ad-hoc signing; drop dead backend constants
bea5f3b Ad-hoc sign dev builds instead of skipping codesign
7b79796 Enable hold-to-talk for Nemotron backends; offer Nemotron 3.5 in onboarding
7b10ce3 Add Nemotron 3.5 multilingual streaming ASR backend (nemotron35)
89cd765 docs: add implementation spec (docs/plans/plan-2026-06-20-nemotron-3.5-multilingual-asr.md)
```

---

## Verified model facts (from the live FluidInference repo — source of truth)

Repo: `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML` (`main` @ `2d4cd16`, lastModified 2026-06-09).

- **Layout:** `{latin,multilingual}/{560,1120,2240,4480}ms/` each with `encoder.mlmodelc`, `decoder.mlmodelc`, `joint.mlmodelc`, `decoder_joint.mlmodelc` (fused — UNUSED, we run decoder+joint separately and skip its download), `preprocessor.mlmodelc`, `tokenizer.json`, `metadata.json`. Root: `config.json` (`{}`), `manifest.json`.
- **We ship `multilingual/2240ms`** (~665 MB). FluidInference's `recommended_tier_ms` = 2240. Chosen over the `latin` track because **Hindi/CJK need the full 13087 vocab** (latin = 2828, Latin-script only). Encoder (566 MB) is byte-identical across tracks.
- **Tokenizer** = plain `tokenizer.json` `{ "id": "piece" }` — same format as the EN backend. Punctuation is in-vocab (don't strip). `▁`→space. `<lang>`/`<unk>` tag pieces are stripped structurally (`^<…>$`); verified all 40 `<…>` pieces in the vocab are genuine tags (zero content tokens match).
- **Encoder I/O:** inputs `cache_channel fp32 [1,24,42,1024]`, `cache_len i32 [1]`, `cache_time fp32 [1,24,1024,8]`, `mel fp32 [1,128,233]`, `mel_length i32 [1]`, **`prompt_id i32 [1]`** (language; auto-detect=101). Outputs `encoded`, `encoded_length`, `cache_channel_out`, `cache_time_out`, `cache_len_out`. Same input *names* as EN; just +`prompt_id` and cache 42 vs 70.
- **decoder/joint I/O** identical to EN. **Geometry:** chunk_mel_frames 224 + pre_encode_cache 9 = total 233; 8× subsample → 28 enc frames/chunk; chunkSamples = 2240·16 = **35840**. vocab 13087, **blank_idx 13087**, encoder_dim 1024, decoder_hidden 640.
- **`prompt_dictionary`** (subset used): auto=101, en=0, es=3, zh=4, hi=6, ar=7, fr=8, de=9, ja=10, ru=11, pt=13, ko=14, it=15.
- Upstream also has a `v2-newckpt-scriptprune` branch (not used) — candidate future update. No version tags; FluidInference iterates via branches/`main`.

Full detail: `docs/plans/plan-2026-06-20-nemotron-3.5-multilingual-asr.md` §0.

---

## Architecture / file map

- **`Sources/MuesliNativeApp/NemotronRNNTEngine.swift`** — shared engine (the dedup). `NemotronRNNTConfig` (per-model differences), neutral `RNNTStreamState`, `NemotronRNNTError`, and free funcs: `nemotronMakeStreamState`, `nemotronTranscribeChunk` (preprocessor→encoder(+optional prompt_id)→RNNT greedy decode), `nemotronDecodeTokens`, `nemotronLoadWavAsFloats`, `nemotronZeroFill`, `nemotronDownloadHuggingFaceTree` (with `skipRelativePrefix`). **Fix the pipeline here once.**
- **`Nemotron35StreamingBackend.swift`** — thin actor: owns MLModels + tokenizer + a `NemotronRNNTConfig` + cache/download paths; delegates to the shared RNNT engine. It has a settable `promptId` (config computed from it) + `setPromptId`, and the update-check helpers (`installedRevision`/`fetchRemoteRevision`/`updateAvailable`, `.revision` file). The old English-only `NemotronStreamingBackend.swift` path has been removed from this PR.
- **`StreamingDictationController.swift`** — protocol `NemotronStreamingTranscribing` uses `RNNTStreamState`; `chunkSamples` is injectable and currently set to 35840 for Nemotron 3.5.
- **`TranscriptionRuntime.swift`** (`TranscriptionCoordinator`) — lazy `nemotron35Transcriber`, `getNemotron35Transcriber()` (async, applies prompt id), `setNemotron35PromptId`, preload/transcribe/shutdown cases for `"nemotron35"`.
- **`MuesliController.swift`** — `isStreamingDictationBackend` (= nemotron35) gates double-tap streaming + skips prepare/arm pre-warm; **handleStart no longer blocks hold-to-talk** (record→file path). `startNemotronStreamingAsync` resolves the Nemotron 3.5 transcriber and chunk size. `setNemotron35Language(_:)` + prompt propagation in startup/select/stream/transcribe paths.
- **`Models.swift`** — `BackendOption.nemotron35Multilingual` (normal Models tab card + onboarding; no longer experimental), `isDownloaded` case, `Nemotron35Language` enum, config `nemotron35Language` (key `nemotron35_language`, default `auto`) + `resolvedNemotron35Language`.
- **`ModelsView.swift`** — icon/delete/isDownloaded cases, Language picker card, "Update" affordance (`checkNemotron35Update`/`updateNemotron35`).
- **`scripts/build_native_app.sh`** — `MUESLI_SKIP_SIGN=1` now **ad-hoc signs** the bundle (was: skip signing) so macOS TCC attributes Accessibility/Input-Monitoring grants.
- **Tests:** `Tests/MuesliTests/NemotronStreamingTests.swift` (3.5 state/metadata/policy/language suites), `ModelsTests.swift`, `TranscriptionRuntimeTests.swift`.

**Dictation modes (Nemotron 3.5):** hold-to-talk → record then transcribe file (`transcribeWithNemotron35`); double-tap → live streaming (`StreamingDictationController`).

---

## How to resume on another machine

1. `git fetch && git checkout claude/nemotron-asr-streaming-msek2t` (HEAD `22c1049f`).
2. **Tests (no model/mic needed):** `swift test --package-path native/MuesliNative` — this handoff observed 1002 tests / 114 suites green; current `main` may report a higher count. To keep the worktree small, pass `--scratch-path "$HOME/Library/Caches/muesli-spm/worktrees/nemotron35/build"` (see CLAUDE.md "SwiftPM build artifacts").
3. **Run the dev app:** `MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh` (installs `/Applications/MuesliDev.app`, bundle id `com.muesli.dev`, data under `~/Library/Application Support/MuesliDev/`). Without the maintainer's Developer ID cert this is the path; it now ad-hoc signs.
4. **Use the model:** Models tab → "Nemotron 3.5 Multilingual" → Download (~665 MB, first load ~30s ANE warmup). Then select it; pick a Language (Auto/Hindi/…). Hold-to-talk or double-tap to dictate. Cache: `~/.cache/muesli/models/nemotron35-multilingual-2240ms/`.
5. **Headless E2E sanity** (no mic): generate speech with `say -o /tmp/s.aiff "…"` → `afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/s.aiff /tmp/s.wav`, then rewrite a canonical 44-byte-header WAV (afconvert inserts an FLLR chunk pushing `data` past offset 44 — the backend's WAV loader assumes 44). Run a temp `@Test` gated by an env var that calls `Nemotron35StreamingTranscriber().loadModels()` + `transcribe(wavURL:)`. This is how English + explicit-prompt_id were validated; delete the temp test after.

---

## Environment gotchas

- **Ad-hoc signing + TCC:** ad-hoc cdhash changes every rebuild, so macOS privacy grants (Accessibility, Input Monitoring, Mic) must be **re-approved after each `dev-test.sh`**. If the onboarding permissions step won't advance after granting, the cause is a stale/incoherent signature — `tccutil reset All com.muesli.dev`, rebuild, re-grant. For grants that persist across rebuilds, create a self-signed code-signing cert and pass `MUESLI_SIGN_IDENTITY=<cert>` (not yet wired into the script — see "Open items").
- `AXIsProcessTrusted()` updates live for a **coherent** signature (no restart needed for the query); the onboarding restart is for event-tap re-creation.
- Don't run concurrent builds from different worktrees into the same `--scratch-path`.

---

## Open items / next steps

1. **Use-before-loaded guard** (code-review #1, medium) — hold-to-talk throws `notLoaded` if you dictate before `loadModels` finishes (e.g. right after the onboarding accessibility restart with nemotron35 persisted). Fails silently (stderr). Add a "model still loading" path. **Not done.**
2. **Live multilingual test** — only English validated E2E; Hindi/CJK real-mic dictation unverified.
3. **Self-signed dev cert** — wire `MUESLI_SIGN_IDENTITY` so TCC grants persist across rebuilds (personal use). For public distribution you need an Apple Developer ID + notarization via the existing production `build_native_app.sh`/`release.sh` path.
4. **Latin track / other latency tiers** as additional options — deferred (each is a separate ~600 MB download + UI). Only if users ask.
5. **Open PR** — none yet. Decide base (fork `main` vs upstream `Muesli-HQ/muesli`).
6. Minor review nits (low priority): cold-start clips first word on hold-to-talk (skips prepare/arm pre-warm by design); shallow `isDownloaded` (encoder-marker only); no behavioral test that `handleStart` records for Nemotron; onboarding double-tap-during-test bypass (rare, re-run-onboarding-with-streaming-backend-active only).

---

## Notes on decisions (context for review)

- **Track choice:** multilingual (not latin) — Hindi requires it. Latin is ~2× faster per frame but Latin-script only.
- **`prompt_id` and speed:** it's a single scalar (not a list); fixing a language affects *accuracy*, not *latency* (graph size unchanged). Real speed lever is the track.
- **Onboarding membership** is an explicit curated list (not a derived `onboardingEligible` flag) — deliberate; Nemotron 3.5 is included as the supported Nemotron option.
- **StreamState** is now a neutral top-level type (`RNNTStreamState`); each backend `typealias StreamState = RNNTStreamState` for back-compat.
