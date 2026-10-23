# Updating Muesli cleanup fine-tunes

The Pro Cleanup variants reuse the existing `ModelDownloadCoordinator`, `ModelDownloadManifest`, and `ModelDownloadFile` components. `ManagedCleanupModel` is release metadata plus load-time validation, not another download implementation. The coordinator supplies progress, cancellation/resume, staging, size/hash verification and caching. LFM's license is a verified sidecar in the same manifest.

## Replacing a fine-tune within a model family

For a Gemma v13 or a later LFM/Qwen fine-tune with the same architecture, artifact format and prompt contract:

1. Update that family's descriptor in `ManagedCleanupModel.swift`: repository, pinned revision, primary filename, byte count, SHA-256, and required sidecars/license. Keep the model artifact first. The app derives filenames, download URLs, expected sizes and display sizes from it.
2. Preserve persisted model IDs and cache-directory identities. Existing IDs include historical version strings; they are compatibility keys, not the current artifact version. The manifest's version is its pinned repository revision. Do not rename these keys just to publish a new fine-tune.
3. The coordinator checks the new artifact manifest, and engine loading verifies exact size and SHA-256 before use, including local overrides. An old cache must not be treated as the new model. Re-download through Models when required. Different filenames may leave an older artifact in the cache until the model directory is deleted; there is no automatic background model update or old-artifact pruning in this change.
4. Keep `MuesliCleanupV2Prompt` unchanged only if the training contract is unchanged. A new chat format, stop token, context budget, architecture or license requires an explicit adapter/metadata change and new validation; replacing weights alone is insufficient.
5. Update golden fixtures/expected paths for the new release, run at least ten golden rows per model, verify corrupt-file rejection and the generation cap, and repeat app-context/list/paragraph smoke tests in DevC. Measure warm latency on identical inputs separately from first-load latency.

Do not make a beta the default during a weight update. Production `qwen35-postproc-v3` remains Muesli Cleanup Light unless a separate decision changes it. Local environment overrides remain available for pre-upload testing and must pass artifact verification.

The earlier Gemma v10 beta selection migrates to the v12 cleanup selection. Users must download the v12 artifact through Models; the old weights are not reused as v12.

## Boundaries

Gemma uses LiteRT-LM; LFM/Qwen GGUF use the pinned llama.cpp through the local LLM.swift wrapper. A runtime or tokenizer upgrade is separate from an artifact revision. MLX integration and a newer llama.xcframework are not implemented here.

### Gemma v12 MTP artifact

The Gemma descriptor now pins `gemma4-e2b-muesli-v12-mtp.litertlm` at revision `ce4656b3be4788e48d7b8e2b4fbfaef77c31d939`. The existing LiteRT-LM runtime detects its drafter and enables speculative decoding automatically; `MUESLI_GEMMA4_LITERT_MTP=0` disables it. Check `mtp=true` in the `engine_ready` profile log. The prompt, persisted model ID, and runtime version are unchanged. Existing no-drafter downloads need the new artifact downloaded through Models; they are not silently treated as the MTP file.

Use `v12gpu_mtp_held.jsonl` for Gemma reference comparisons. The opt-in native test checks all 400 held-out rows with at least 96% exact matches, allowing the updated spec's GPU rounding tolerance; GGUF comparisons remain exact. Run `gemmaLongDictationTiming` in separate processes with MTP enabled/disabled and `MUESLI_MTP_TIMING_REPORT` set to distinct output paths. It uses the same five longest coverage inputs, excludes warm-up, and records guarded/raw output and timing. These are app-backend timings, not microphone-to-paste latency.

The training-side benchmark reported occasional LiteRT engine crashes after roughly 100 requests under load, including with the old no-MTP artifact. Keep this as a beta stability follow-up and exercise long-lived engines. A fatal native crash cannot be caught and retried by the Swift error handler; do not claim automatic crash recovery. MTP's reported long-output improvement does not resolve the latency acceptance item below.

Native comparison on Apple M5 (2026-10-23, Debug backend, five longest coverage inputs, about 320 output words, warm-up excluded): median MTP on **4.30 s**, off **8.31 s**, about **48% lower** latency. All five final outputs matched across the isolated runs, with no guard fallback. This small sequential comparison is not a general speed guarantee. Both runs used the same verified MTP artifact; engine logs confirmed `mtp=true` and `mtp=false` respectively.

The full native MTP-on held-out run matched **387/400 (96.75%)** reference outputs, passing the 96% threshold. Median backend generation time was **0.822 s** across the held-out set and **0.652 s** across six short synthetic smoke inputs. One engine completed warm-up, all 400 rows, and the six smoke requests without a crash. This does not prove the reported intermittent crash is resolved. The comparison also exposed a shared punctuation-cleanup bug that removed whitespace before relative paths such as `../hotfix-4.2`; the cleaner now preserves relative paths, dotfiles, and leading-dot decimals, with a regression test. Remaining reference differences were not used to change training prompts or relax the acceptance threshold.

## Outstanding latency work for the merge handover

User feedback on 2026-10-23: cleanup latency during actual dictation is **not good enough and still needs improvement**. Carry this limitation into the eventual PR #660 merge handover. A successful integration, passing CI, or backend-only benchmark is not latency acceptance.

Measure dictation-completion-to-paste latency on identical inputs, separating OCR/context collection, model verification/loading, prompt processing, generation, and paste. Record cold and warm results per model, device, and build configuration. Runtime optimization and deferred Phase 2 work remain follow-ups; preserve output quality and formatting while improving speed, and obtain user validation before considering latency acceptable.

## Diagnosing formatting after a model update

Compare the exact prompt, raw generation, guarded output and pasted text for the same dictation. For GGUF, `Qwen3PostProcessor.processResult` returns raw and guarded output together; `TranscriptionRuntime` records `rawOutput` as `rawCleanupOutputText`. Do not substitute the guarded text for the raw response when adding a model adapter. A missing list in the raw response is a different failure from a list that disappears during cleanup or paste. Keep private dictation and screen-context logs out of the repository.

Guard rejection preserves the raw transcript, as required by the v12 integration specification §4E, and logs `fallback_original_transcript`. It does not silently report successful cleanup or apply a different deletion/filler policy. GGUF generation reports its stop reason; reaching the generation or context budget also preserves the full original transcript.

Gemma cleanup enables LiteRT token-count metrics and rejects responses that reach the output-token cap. Missing token-count data also preserves the original transcript. Count metrics do not change the training prompt or sampling settings.

### Opt-in stage timing (DevC investigation, 2026-10-23)

Launch with `MUESLI_LOG_TRANSCRIPT_CLEANUP_DEBUG=1`. The app support directory receives `cleanup-timing.jsonl` (monotonic durations), `cleanup-prompts.jsonl` (exact Gemma user prompt), and `transcript-cleanup-debug.jsonl` (raw ASR, raw model output, guarded output and final runtime text). Main dictation requests share the existing latency trace UUID, allowing comparison with `dictation-latency.log` through paste completion. Background engine warm-up can have no request ID. Text fields in the existing transcript log remain explicitly truncated after 4,000 characters; the prompt record is complete. Logs are local, opt-in and size-rotated.

Stage durations are nested, not additive: `cleanup_total` includes queue wait, model preparation and generation; model preparation includes verification and engine creation on a cold load. `gemma_generation` covers the native send-message call (prefill plus decoding), while the existing `processingTime` additionally includes session setup and output handling. ASR timing covers the ASR route, including any backend preparation performed there. `dictation_processing_total` excludes capture and paste; use the existing latency trace for those. Engine initialization records the effective MTP setting. Gemma cleanup-only requests now emit the previously skipped `cleanup_completed` profile event.

The first missing-bullets dictation had no raw ASR/OCR/model diagnostics. An opt-in `gemmaBulletDiagnosticReplay` replays its stored final text with minimal Codex context, then adds an explicit bullet instruction. With MTP on, the former produced a paragraph in both raw/final output; the latter produced three bullets in both. This supports model formatting-intent inconsistency, not stripping by cleanup in that replay. It does not reconstruct the original request or establish its exact cause. The explicit-instruction replay also dropped the introductory sentence, so this is diagnostic evidence, not a complete quality acceptance test. No training prompt was changed. Keep private replay reports out of Git.

### Generation latency investigation (Apple M5, 2026-10-23)

Native Swift tests replayed the latest three-point dictation with its exact logged ASR and context, MTP on, unchanged training prompt and 1,024-output-token cap. Private fixtures/results remain under `/tmp`, outside Git. Added LiteRT prefill/decode rate and time-to-first-token metrics to the opt-in profile log. `gemmaLatencyInvestigation` uses `MUESLI_LATENCY_FIXTURE` and `MUESLI_LATENCY_REPORT`; `MUESLI_LATENCY_WARMUP=1` tests an unrelated short warm-up and a 15-second idle interval. The cleanup API's context-size argument is diagnostic; production default stays 4,096.

| Variant | First generation after engine load | Median of next 3 |
|---|---:|---:|
| Full context, 4,096 allocation | 2.089 s | 1.084 s |
| Full context, 2,048 allocation | 2.183 s | 1.088 s |
| App name only, 4,096 allocation | 2.167 s | 1.100 s |
| Repeat full-context baseline, fresh engine | 2.180 s | 1.082 s |

All 16 raw/final results preserved the numbered list and all 16 final results exactly matched the recorded output. These are repeated measurements of one example, not a broad quality gate. No model initialization time is included above. Dropping OCR reduced prefill tokens from 583 to 267 but prefill time remained around 0.56–0.58 seconds on immediate repeats. Smaller context allocation also gave no useful improvement. Keep full context and the default allocation.

For the full-context baseline, first-call prefill/decode were approximately 0.80/1.28 seconds, versus 0.58/0.50 seconds on a representative immediate repeat (token count divided by reported token rate). This suggests execution warm-up matters beyond loading weights; the measurements do not identify shader compilation versus clocks or scheduling. The exporter documents fixed prefill shapes 128/1024 and a 32,003-token compiled cache, so shape-specialized re-exports merit a separate benchmark, not an assumed app-level gain.

An unrelated six-token-output warm-up in its own conversation took 1.194 seconds; the subsequent first real input took 1.170 seconds. After a 15-second pause, it took 1.206 seconds. All four real outputs in this experiment exactly matched the recorded numbered output. Candidate next step: one cancellable, bounded, disposable-conversation warm-up while preparing dictation, without altering the real prompt/history. Do not add continuous keep-alives. Validate minutes-long idle periods, varied prompt lengths, audio contention, battery impact and long recordings before deployment. The user's slow live request followed a prior request several minutes earlier, so startup-only warm-up is not yet a demonstrated fix for that recurring latency.

MLX remains the larger runtime candidate: the training handoff reports Gemma MLX 4-bit at 0.34 s median versus LiteRT 0.93 s on its 60-prompt harness. Those Python-harness figures are not Swift-app results or predictions for this longer three-point request. Follow Phase 2's dependency/tokenizer discussion and Bodhan regression checks before introducing it. Preserve the complete output guard; streaming partially verified text into the target app or lowering the generation cap is not a quality-preserving latency fix.

### Bounded preparation warm-up

DevC now schedules one best-effort Gemma cleanup warm-up after the microphone stream becomes active. It is deduplicated by dictation trace, cancelled when the recording/preparing state ends, and uses no real transcript or captured screen data. Admission requires the already-loaded cleanup model, an idle engine with no queued operations, a request less than two seconds old, and no cleanup activity within 30 seconds. It never downloads a model or changes model selection. The disposable conversation generates at most eight tokens; its output is discarded. No periodic keep-alive is installed, and the real training prompt, context, token cap and output guard are unchanged.

The native call is synchronous: cancellation prevents admission but cannot preempt an already-running native invocation. The bound is eight generated tokens, not a hard wall-clock timeout. Very short dictations can still encounter the tail of a warm-up. `gemma_bounded_warmup` timing and `warmup_completed` profile events distinguish preparation work from real inference. Validate the full microphone-to-paste path and battery/audio behavior in DevC before claiming a general latency improvement.

Validation on Apple M5: `gemmaLongIdleWarmup` waited 180 seconds after baseline cleanup, ran the production eight-token warm-up (0.940 s), waited another 15 seconds, and replayed three inputs. Generation took 1.453 s for the user's combined three-point dictation, 0.718 s for an explicit bullet request and 0.649 s for a numbered-list request. All three raw/final outputs exactly matched baseline outputs; no fallback occurred. Recent-activity, duplicate, expired and cancelled admissions were rejected, and the separate unloaded-engine test passed (2 tests total). DevC rebuilt from its existing caches, with deep signature and functional LocalVQE checks passing. Fresh installed-app profile confirms MTP enabled. These are backend results from one longer-idle cycle, not a microphone-to-paste speed guarantee or broad formatting acceptance.

Live DevC observation after approximately 20 minutes idle: warm-up completed in 945 ms while recording, followed by 426 ms ASR, under 1 ms model preparation, 912 ms Gemma generation, and 1.543 s stop-to-paste. Compared with the earlier live observation (3.225 s stop-to-paste, 2.297 s generation), these are approximately 52% and 60% lower respectively. The live inputs differ, so these are observed improvements, not a controlled estimate of the typical speedup. The controlled same-input replay improved from 2.089 s to 1.170 s generation after an unrelated warm-up (about 44%). Formatting remains model-dependent: the latest live response remained a paragraph in raw generation; no bullet formatting was stripped. Broad latency/formatting acceptance remains open.
