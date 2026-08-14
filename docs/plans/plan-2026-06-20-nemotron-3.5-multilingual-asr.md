# Plan: Add Nemotron 3.5 Multilingual Streaming ASR as a model option

**Date:** 2026-06-20 (verified & implemented 2026-06-21)
**Branch:** `claude/nemotron-asr-streaming-msek2t`
**Status:** §5 unknowns verified against the live FluidInference repo on a Mac; implementing.

---

## 0. VERIFIED FACTS (2026-06-21, from the live repo — supersede §2/§5 guesses)

Repo: `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML` (sha 2d4cd16).

- **Layout:** `{latin,multilingual}/{560,1120,2240,4480}ms/` each with `encoder.mlmodelc`, `decoder.mlmodelc`, `joint.mlmodelc`, `decoder_joint.mlmodelc` (fused, unused by us), `preprocessor.mlmodelc`, `tokenizer.json`, `metadata.json`. Repo root has `config.json` (empty `{}`) + `manifest.json`. **No 80/320ms variants** (plan's 320ms default was wrong).
- **Tracks:** `latin` = vocab 2828, en/es/fr/it/pt/de. `multilingual` = vocab 13087, +zh/ja/100+ via prompt_id. Encoder (566MB) is byte-identical across tracks; decoder/joint differ.
- **DECISION: ship `multilingual` @ `2240ms`** (FluidInference's `recommended_tier_ms`). Reason: Hindi requires the multilingual track (latin tokenizer has 1 incidental Devanagari token; multilingual has 196; `hi`→prompt_id 6). Bundle ≈ 665MB.
- **Tokenizer:** plain `tokenizer.json` = `{ "id": "piece" }` — **same format as the EN backend**. Punctuation (`.`,`,`,`?`) is in-vocab → drop punctuation stripping. Space marker `▁`. Special/lang-tag pieces look like `<unk>`, `<en-US>`, `<bg-BG>` → strip any `^<…>$` piece on decode.
- **Encoder I/O (same input names as EN + one new input):**
  - in: `cache_channel fp32 [1,24,42,1024]`, `cache_len int32 [1]`, `cache_time fp32 [1,24,1024,8]`, `mel fp32 [1,128,233]`, `mel_length int32 [1]`, **`prompt_id int32 [1]`** (NEW — language; auto-detect sentinel = **101**, default).
  - out: `encoded`, `encoded_length`, `cache_channel_out`, `cache_time_out`, `cache_len_out`.
  - Cache layout is the **same ordering as EN**, just sizes 42 vs 70 (att_context `[42,13]`). No `pre_cache` input; no cache renames.
- **decoder I/O** (identical to EN): in `c_in [2,1,640]`, `h_in [2,1,640]`, `token int32 [1,1]`, `token_length int32 [1]` → out `decoder_out`, `h_out`, `c_out`.
- **joint I/O** (identical to EN): in `decoder [1,640,1]`, `encoder [1,1024,1]` → out `logits`. (We use decoder+joint separately, exactly as EN — ignore the fused `decoder_joint`.)
- **preprocessor I/O** (identical to EN): in `audio fp32 [1,?]` (flex up to 1.28M), `audio_length int32 [1]` → out `mel`, `mel_length`.
- **Geometry (multilingual/2240ms metadata.json):** sample_rate 16000, mel_features 128, chunk_mel_frames 224, pre_encode_cache 9, total_mel_frames 233, 8× subsample → 28 encoder frames/chunk, chunkSamples = 2240·16 = **35840**. encoder_dim 1024, decoder_hidden 640, decoder_layers 2.
- **Vocab/blank:** vocab_size 13087, **blank_idx 13087** (= logits dim 13088). default_prompt_id 101, num_prompts 128.
- **License:** `openmdw-1.1` / NVIDIA Software-and-Model Evaluation License. Base ships en/es/fr/it/pt/de/zh/ja in card languages.

Net effect: the 3.5 backend uses the same RNNT pipeline shape as the former EN backend (same I/O feature names, same decode loop, same tokenizer format, same download helpers) with different cache sizes, vocab/blank, chunk geometry, the added `prompt_id` input, and `<…>` tag stripping. `StreamState` is now the neutral `RNNTStreamState`, and `StreamingDictationController` is driven through the protocol-based Nemotron 3.5 path.

---

## 1. Goal

Add NVIDIA's [`nemotron-3.5-asr-streaming-0.6b`](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b) as the supported local Nemotron streaming option, replacing the older English-only `nemotron-speech-streaming-en-0.6b-coreml` app backend.

Ship via the FluidInference CoreML/ANE conversion:
[`FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML).

**Wins over the retired EN backend:** 40 language-locales (en/es/fr/it/pt/de + zh/ja + 100+ via language prompt), newer base checkpoint (2026-05-29), and **native punctuation in the vocab** (removes the old backend's "no punctuation" limitation).

---

## 2. Why this is NOT a one-line URL swap

The 3.5 model has a **different CoreML interface** than the retired English backend constants. Confirmed differences from public docs (must be re-verified against the actual `config.json`/`metadata.json` — see §5):

| Aspect | Retired EN backend | Nemotron 3.5 multilingual |
|---|---|---|
| Vocab size / blank id | `1024` / `1024` | `13087` (full) or `2828` (Latin-pruned) / `= vocabSize` |
| Encoder caches | `cache_channel [1,24,70,1024]`, `cache_time [1,24,1024,8]`, `cache_len [1]` | `cache_last_channel [24,1,56,1024]`, `cache_last_time [24,1,1024,8]`, `pre_cache [1,128,9]`, `cache_last_channel_len [1]` |
| Encoder language input | none | **6th input** for language selection — name/shape unconfirmed: either `prompt_index` (int64 `[batch]`, `101` = auto-detect) **or** one-hot `language_mask [1,128]`. **VERIFY.** |
| Tokenizer files | `tokenizer.json` (`{id_string: piece}`) | SentencePiece `tokenizer.model` + `vocab.json` + `languages.json` + `config.json` |
| Decoder | 2-layer LSTM, `pred_hidden=640` (same) | 2-layer LSTM, `pred_hidden=640` (same — likely reusable) |
| Encoder dim | `1024` | `1024` (d_model, 24 Conformer layers — same) |
| Chunk variants | `560ms` only | `560 / 1120 / 2240 / 4480 ms` tracks; this integration ships `multilingual/2240ms` |
| Subsampling | — | 8× (one encoder frame / 80ms) |

Because the cache shapes, I/O feature names, vocab, and the new language input all differ, this needs a **new backend type** (or a parameterized one), not a repointed URL on the existing `nemotron` backend.

---

## 3. Decision: new backend identifier

Use backend string `"nemotron35"` and remove the older `"nemotron"` app backend from the model list and runtime routing. This avoids exposing two confusing Nemotron choices while preserving the shared RNNT helpers needed by 3.5.

Recommended default chunk variant: **2240ms** (`multilingual/2240ms`, FluidInference's `recommended_tier_ms`). Optionally expose lower-latency tiers later as separate downloads.

Language default: **auto-detect** (the `101`/auto sentinel). A language picker in Settings is a follow-up, not required for v1.

---

## 4. Files to touch (integration surface)

All paths under `native/MuesliNative/Sources/MuesliNativeApp/` unless noted. Line numbers are approximate as of this branch.

### 4.1 `Models.swift`
- Add a `BackendOption`:
  ```swift
  static let nemotron35Multilingual = BackendOption(
      backend: "nemotron35",
      model: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
      label: "Nemotron 3.5 Multilingual",
      sizeLabel: "~665 MB",
      description: "NVIDIA Nemotron 3.5 streaming RNNT via FluidInference. Multilingual incl. Hindi, Chinese, Japanese + 100+ locales (auto-detect). Native punctuation. Hold-to-talk or double-tap handsfree (live text). Append-only — no corrections.",
      recommended: false
  )
  ```
- Add it to `all` as a normal Models tab card, not to `experimental`.
- Extend `isAvailableLocally(...)` (the `switch` near line ~173) with a `case "nemotron35":` checking `.cache/muesli/models/nemotron35-multilingual-2240ms/encoder.mlmodelc/coremldata.bin`.

### 4.2 New backend file `Nemotron35StreamingBackend.swift`
Implement a dedicated 3.5 backend actor, then change:
- **Cache shapes & names** in `makeStreamState()` and the encoder `MLDictionaryFeatureProvider` (see §2 table). Add `pre_cache` and rename `cache_channel→cache_last_channel`, `cache_time→cache_last_time`, `cache_len→cache_last_channel_len`. Match the actual output feature names for the `*_out` writes-back.
- **Add language input** to the encoder feature dict (the 6th input). Build it once per stream from the selected language (auto = sentinel). VERIFY name/dtype/shape.
- **Vocab/blank**: read from `config.json` if present; otherwise set `vocabSize`/`blankTokenId` from the bundle (13087 multilingual or 2828 Latin-pruned). Do **not** hardcode 1024.
- **Tokenizer/decode**: the EN path maps `tokenizer.json {id:piece}` and replaces `▁`. The 3.5 bundle ships `vocab.json` (likely `{piece: id}` or an array) + SentencePiece `tokenizer.model`. Implement decode from `vocab.json` (id→piece) with `▁`→space. Native punctuation means **drop** any punctuation-stripping. Strip the per-language tag suffix the model can emit at utterance end (see model card — VERIFY token format).
- **Chunk geometry**: set `chunkSamples`, mel-frame counts, `encoderOutputFrames` from the `multilingual/2240ms` metadata. (560ms EN values do **not** transfer.)
- **Download**: point `cacheDir` to `.cache/muesli/models/nemotron35-multilingual-2240ms` and the HF tree/resolve URLs to the new repo + the `multilingual/2240ms` subfolder. Reuse the existing `downloadDirectory`/`downloadWithRetry` helpers verbatim.

### 4.3 `TranscriptionRuntime.swift`
- Add a lazy `_nemotron35Transcriber: Any?` + accessor mirroring `nemotronTranscriber` (lines ~19–39).
- `prepareBackend`/load switch (line ~191): add `case "nemotron35":` with the same `#available(macOS 15, *)` guard and a silent-chunk warmup (use the new `chunkSamples`, not 8960).
- Transcribe switch (line ~446): add `case "nemotron35": return try await transcribeWithNemotron35(url:)` and implement the wrapper (clone `transcribeWithNemotron`, lines ~549).
- `shutdown` (line ~345): add `await nemotron35Transcriber.shutdown()`.

### 4.4 `StreamingDictationController.swift`
- The `NemotronStreamingTranscribing` protocol uses neutral `RNNTStreamState`.
- `MuesliController` chooses the streaming controller only for `backend == "nemotron35"` and passes the 3.5 chunk size.

### 4.5 `ModelsView.swift`
- The new option appears in `all` as a normal Models tab card, not under `experimental`. Verify the download/progress UI keys off `backend`/`model` correctly.

### 4.6 Tests — `Tests/MuesliTests/`
- `ModelsTests.swift`: assert the new option exists, has `backend == "nemotron35"`, correct model id, and is in `all` but not `experimental`.
- `BackendTests.swift` / `TranscriptionRuntimeTests.swift`: extend any `switch backend` exhaustiveness/coverage tests.
- `NemotronStreamingTests.swift`: add a sibling suite for the new backend's pure helpers (token decode, language-input construction, state init shapes). Guard CoreML-dependent tests behind model availability as the existing suite does.
- Target: keep the suite green with focused Nemotron/model/routing coverage plus the full SwiftPM suite when warranted.

---

## 5. MUST-VERIFY before/while coding (needs HF access + a Mac)

These are the items I could not confirm from this environment. Pull them from the FluidInference repo's `config.json` / `metadata.json` / model `.mlmodelc` `metadata`:

1. **Repo tree & variant folder names** — confirmed as `multilingual/2240ms` with `encoder.mlmodelc`, `decoder.mlmodelc`, `joint.mlmodelc`, `preprocessor.mlmodelc`, and `tokenizer.json`. Mirror the EN `downloadDirectory` API/resolve URL pattern.
2. **Encoder I/O feature names & shapes** — `mel`/`audio` input name, cache input/output names, and especially the **language input** (`prompt_index` int64 `[batch]` vs one-hot `language_mask [1,128]`) and its auto-detect sentinel value.
3. **Vocab size + blank id** + whether the shipped bundle is the 13087 (full) or 2828 (Latin-pruned) vocab — and which FluidInference publishes by default.
4. **Tokenizer format** — structure of `vocab.json` (id→piece vs piece→id vs array), space marker (`▁`), and the per-language suffix-tag token format to strip.
5. **Chunk geometry** for `multilingual/2240ms` — `chunkSamples`, mel window/hop frame counts, encoder output frames per chunk.
6. **Bundle size** for the `sizeLabel` string.
7. **License** — confirm NVIDIA's model license permits redistribution/use in a shipped app (the EN one is already shipped, but 3.5 license terms should be re-checked).

---

## 6. Caveats to surface in UI / docs (carry forward to CLAUDE.md "Known Limitations")

- RNNT limitations to surface: **append-only, no corrections, handsfree-oriented, weak on very short dictations.** Hold-to-talk is supported via record-then-transcribe; double-tap uses live streaming.
- First run pays CoreML ANE compilation warmup cost (mitigated by silent-chunk warmup on load).
- Multilingual accuracy varies by language; some locales are "adaptation-ready" only (need fine-tuning). Set expectations in the model description.
- Larger vocab (13087) → slightly heavier joint/argmax per frame than the EN 1024 path; profile on lowest-supported hardware.

---

## 7. Suggested sequencing

1. (Mac, HF access) Inspect repo → fill in all §5 unknowns.
2. Add `Models.swift` entry + `isAvailableLocally` + tests for those (cheap, no model needed).
3. Implement `Nemotron35StreamingBackend.swift` against verified shapes; unit-test pure helpers.
4. Wire `TranscriptionRuntime` + `StreamingDictationController`/`MuesliController` routing.
5. `./scripts/dev-test.sh` → download model → real handsfree dictation in 2–3 languages.
6. Update `CLAUDE.md` (model count 7→8, Known Limitations) + this Context note.
7. PR.

---

## 8. Sources
- https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b
- https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML
- https://github.com/soniqo/speech-swift/blob/main/docs/models/nemotron-asr-streaming.md
- https://github.com/k2-fsa/sherpa-onnx/issues/3664 (prompt_index language conditioning)
- https://www.marktechpost.com/2026/06/06/nvidia-releases-nemotron-3-5-asr-a-600m-parameter-cache-aware-streaming-model-transcribing-40-language-locales-in-real-time/
