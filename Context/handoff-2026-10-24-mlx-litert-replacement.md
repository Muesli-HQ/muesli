# Replace LiteRT with native MLX inference

## Scope

Native Swift/MLX now handles Gemma E2B/E4B dictation, Gemma cleanup v12, text/direct-audio Quill, and the model adapter for local computer use. Existing model identities and prompt contracts are preserved; native weights and assistants have pinned revision/size/SHA256 manifests and reuse ModelDownloadCoordinator. LFM/Qwen GGUF remain on LLM.swift. No model files are committed.

Remove CLiteRTLM_mac and stale cached packaging artifacts. Add official mlx-swift-lm 3.32.3 (including guided generation), swift-transformers 1.3.2 tokenizer, and mlx-swift 0.32.3. Audio frontend/encoder are native Swift with independent reference and end-to-end tests. Python is only an explicitly invoked offline reference-tensor exporter, never an application runtime dependency. Apache-2.0 attribution/license accompanies the encoder port from Transformers commit 50e35cc0ca18ec19b80653690de553e6decf74f5.

Shared per-model engines, bounded warm-up, recording admission gate/pill, silence handling, strict completion checks, and per-stage timing are included. Computer use retains tool schema constraints, strict argument parsing, allowed-tool scope, and existing execution approvals. The combined grammar/MTP mode is opt-in; DevC has it embedded for manual tests. No browser/task-routing or context-pruning changes are included.

## Evidence and limits

Apple M5, 24 GiB. Optimized DevC built with reused caches; installed signature and LocalVQE/bundled-model verification passed. No LiteRT dylib remains in the bundle or load commands. Installed size fell about 59 MiB (298 to 239 MiB); excludes model caches and is not a compressed-installer comparison.

Previous selected 77-test regression run passed; not all are real-model tests (opt-in evaluations return early without fixtures). Separate model smoke checks covered E2B/E4B speech, silence, expected long cleanup bullets, and text/direct-audio Quill. Native audio FP32 reference checks and BF16 diagnostics are separate: strict BF16 elementwise equivalence is not claimed. Some direct-audio Quill edit cases differed from LiteRT (E4B deleted an extra sentence; E2B partly transcribed a cursor instruction). These remain release review items.

MTP is confirmed in actual DevC dictation logs. In the latest live E2B computer-use run, hybrid=true with nonzero accepted drafts and skipped drafter blocks produced a valid launch_app call and successfully activated Chrome. Its subsequent failure occurred before generation at the existing planner input-budget check, not during MTP verification. No tweet was drafted or posted.

Three-mode benchmark: 48 real inference calls across E2B/E4B, four fixtures, two repetitions; expected tools and required arguments passed. No desktop actions executed by the benchmark. Three focused grammar/validation tests passed, including forced suffix replay and premature EOS rejection. Warmed four-fixture median grammar-only -> combined: E2B 0.792 -> 0.776 s; E4B 2.054 -> 1.960 s. Small sample: no claim of a major speedup. Optional descriptive labels can differ.

Cold/idle prefill remains slow: a recent first dictation needed about 12.8 s inference, versus about 0.85–0.91 s for later samples. Warm-up does not eliminate all input-shape/idle effects. Further runtime latency optimization remains needed.

## Separate computer-use harness follow-up

- Browser versus native-app routing: “open Twitter” attempted to launch an installed Twitter app.
- Prompt context budgeting: Chrome's 80 accessibility elements exceeded the current 13,568-token input budget after successfully opening Chrome.
- Error classification: this pre-generation rejection is misleadingly labeled “invalid tool call.” “Nothing was executed” is also misleading after an earlier successful step.
- Address these in a separate harness change; do not weaken grammar, validation, approvals or prompt restrictions to make the migration pass.

## Reproduction

Use existing worktree-specific caches and scripts/dev-test.sh --lane C --local-only. Set MUESLI_GEMMA_TOOL_MTP=hybrid at build time to embed the combined decoder only in DevC. Default production tool planning stays grammar-guided; dictation/cleanup/Quill use MTP unless MUESLI_GEMMA_MLX_MTP=0.

Opt-in model benchmarks: MUESLI_CUA_BENCHMARK=1 and MUESLI_CUA_MTP_COMPARISON=1 with fixedPlannerPrompts. MUESLI_MLX_EVAL_METALLIB must point to the built MLX metallib. Offline parity fixtures are intentionally not committed; tests explicitly requiring parity fail if those fixtures are absent.
