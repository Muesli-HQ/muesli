# Native Gemma audio encoder and evaluation

The application uses this module for native E2B/E4B audio preprocessing and encoding. It uses Swift, MLX and Apple Accelerate; no Python runtime is linked or launched by the app.
Reference-tensor checks and end-to-end transcription checks are separate: strict BF16 parity is not claimed. See the migration handover for the accepted test scope and remaining quality limitations.

Reference algorithm: Apache-2.0 Hugging Face Transformers Gemma4 `modeling_gemma4.py` and `feature_extraction_gemma4.py`, copyright HuggingFace/Google 2026. Source snapshots and hashes are recorded in Context for this experiment. Retain upstream attribution when promoting this code.

Run tests with the existing scratch cache and MUESLI_MLX_EVAL_METALLIB pointing at its built metallib.
- Normal tests: feature shape/mask/silence, independent scalar Double DFT, comparison failure behavior.
- MUESLI_GEMMA_AUDIO_SMOKE_MODEL=<verified E4B directory>: load actual audio tower and check execution/finite output. NOT parity.
- MUESLI_GEMMA_AUDIO_REQUIRE_PARITY=1: requires MUESLI_GEMMA_AUDIO_REFERENCE=<bundle> and MUESLI_GEMMA_AUDIO_MODEL=<model directory>; missing references FAIL.

Reference bundle:
- manifest.json: `weightLayout` (`mlx` or `huggingFace`), `producer`, 40-hex `referenceCommit`, `modelSHA256`, `configSHA256`, `tensorsSHA256`, `sampleRate`, `featureConfiguration` (Codable Configuration), `stages` [{name, absoluteTolerance, relativeTolerance}]. Tolerances must be justified by reference dtype/error, not increased to conceal failures.
- reference.safetensors: Float32 mono `samples`, `mel` [1,T,128], `mel_mask` [T], `subsample0` and `subsample1` in MLX [B,T,F,C] layout with their masks, `input_projection`, `layer0`...`layer11`, `encoder` [B,T,1536], `encoder_mask`. Masks compare exactly. All stages are mandatory, hashes verified before inference. Expected values must be generated independently, not exported from this implementation.

The encoder accepts the saved E4B MLX layout and the saved original E2B HF layout through explicit in-memory convolution-axis conversion. It strictly checks all tensor names/shapes/dtypes, retaining BF16 tower weights and optional F32 normalization weights. Quantized encoder variants are rejected instead of guessed. The projector, language-model integration, microphone handling and MTP are outside this isolated module. The cleanup MLX artifact has no audio weights.

E2B smoke flags: MUESLI_GEMMA_AUDIO_E2B_MODEL, MUESLI_GEMMA_AUDIO_E2B_SHA256 and MUESLI_GEMMA_AUDIO_E2B_CONFIG_SHA256 (all required together).

Pinned algorithm source: Transformers commit 50e35cc0ca18ec19b80653690de553e6decf74f5. The included LICENSE is its Apache 2.0 license. No Python source is executed or linked by Muesli. The separately invoked offline oracle in `scripts/generate_gemma_audio_references.py` uses the original pinned Hugging Face/PyTorch implementation to generate trusted test inputs.


## Generated-reference validation (2026-10-24)

See `Context/gemma-audio-parity-2026-10-24.md` for the independent source hashes,
reference tensors, precision control, stage metrics and limitations. Reference
bundles now declare `precision` (`checkpoint` or `float32`; absent means checkpoint).
`float32` upcasts existing weight values in memory; model files remain unchanged.
Run full-precision comparisons with `MLX_ENABLE_TF32=0` set before process startup.
MLX otherwise permits reduced-precision float32 matrix multiplication on M5.
The reference environment is isolated from the native app and its dependencies.

`MUESLI_GEMMA_AUDIO_REFERENCE` accepts either one fixture directory or a directory
containing fixture directories. Each fixture must include all 21 stages. The test
harness bounds and clears the GPU allocation cache between checkpoints.

Full-precision acceptance is separate from checkpoint BF16 acceptance. Do not
infer that BF16 passed from a float32 result, or that encoder tensor parity proves
end-to-end transcription, audio projection, streaming, or Quill behavior.

## BF16 follow-up

See `Context/gemma-audio-bf16-investigation-2026-10-24.md`. Final projection now
adds bias before BF16 rounding, matching the original fused Linear. The strict
BF16 elementwise gate still reports differences; the original CPU/MPS pair does
too. `MUESLI_GEMMA_AUDIO_BF16_CONTROL=<MPS fixture root>` explicitly selects a
SEPARATE bounded cross-backend diagnostic. It retains strict violation counts
and requires matching references and exact masks. It is not bitwise equivalence
or approval for production audio quality. FP32 strict checks remain unchanged.
Set `MUESLI_GEMMA_AUDIO_METRICS_DIR` to retain atomic per-fixture JSON records.

## End-to-end evaluation

`GemmaAudioEndToEndTests` in the application test target connects this encoder to
MLX-Swift-LM's public `Gemma4Unified` projected-audio input, using the original
E-series text/projector weights and the unchanged production dictation prompt.
It is opt-in through `MUESLI_AUDIO_E2E_REPORT` and does not register an app backend.
`encode(_:retainTrace: false)` retains only final features/mask for timing.
See `Context/gemma-audio-end-to-end-2026-10-24.md` for benchmark scope and results;
transcription evidence is separate from exact reference-tensor parity.
