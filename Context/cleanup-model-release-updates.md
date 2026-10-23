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
