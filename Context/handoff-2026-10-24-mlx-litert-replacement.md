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

## PR #668 review follow-up

Preserved the maintainer's merge of main and ready-for-review state. Fixed the Models download entry point to use the shared download/verify/prepare facade, including target/drafter progress callbacks. Optional missing cleanup/Quill models no longer enter recording admission; selected native dictation remains mandatory. Regression covers unavailable optional models and subsequent availability changes.

Packaging now writes the dev profile path with plutil, removes the unused always-true plist flag, rejects any retained LiteRT Mach-O dependency before installation, and bundles runtime licenses/notices with About acknowledgements. CI clears the benchmark test-selection environment flag and discovers/runs the separate native encoder test suite. Grammar literal serialization propagates errors instead of using try!.

Validation: 65 focused application tests and the 10-test encoder suite passed (reference-only tests explicitly skipped without fixtures); shard discovery, classifier/update-flow, shell syntax and diff checks passed. Installed DevC passed the new linkage guard; a synthetic linked executable was correctly rejected. A profile path containing spaces and an apostrophe round-tripped intact. Cross-GPU Bodhan performance under the process-wide TF32 policy remains a release validation item; no unchanged-throughput claim is made. Existing WhisperKit checkout has no swift-transformers dependency. Computer-use harness behavior remains out of scope.

### Second review follow-up

Optional cleanup/Quill preparation failures (including failed artifact validation) no longer prevent ordinary dictation. Required dictation failures and cancellation still fail closed; inference keeps its own artifact verification. Active audio and transcription sessions retain stop/cancel handling even if another preparation starts. Runtime unload now visits every shared Gemma engine, including one loaded only by the planner adapter.

CI builds test products first and locates MLX's compiled metallib before executing shards. MTP dataset paths now use the explicit evaluation environment configuration. Explicit model deletion removes the app-owned legacy LiteRT directory as well as the MLX target; external overrides and shared drafter caches remain preserved. No automatic cache deletion occurs on upgrade. The missing-model error now names the MLX override. Computer-use harness routing, context pruning, and error presentation remain separate.

Optional artifact availability now runs during asynchronous preparation rather than MainActor plan construction. The LiteRT packaging guard uses the staged executable name (not the app display name), including Preprod/Canary bundles whose binary is still named Muesli. A synthetic MuesliPreprod.app/Muesli fixture verifies this distinction.

Final follow-up validation: 67 focused application tests and the 10-test encoder suite passed on the finished edits (reference-only fixture cases skipped). Classifier, shard assignment, update-flow, shell syntax, and diff checks passed. Mocked CI invocation verified Metal resource discovery and fail-closed behavior for a missing resource.

### Quill readiness follow-up

Quill preparation/start no longer require credentials for the separately selected hosted dictation provider. The native preparation plan includes its actual local Gemma audio dependency even when hosted dictation is selected, and treats the Quill model as required for Quill interactions. Ordinary dictation keeps optional Quill preparation best-effort. Warm-up keys distinguish these requirements. 68 application tests and the 10-test encoder suite passed; fixture-only reference cases remained skipped.

### Native CI build engine and non-Gemma Quill

CI's Swift 6.3 legacy build engine did not compile MLX Metal resources. All three shards failed at the explicit resource check before executing tests. The shard runner now explicitly selects `--build-system swiftbuild` for build, product-path discovery, and test execution; this matches the locally validated resource-producing build engine without changing dependencies. See Swift's resource support documentation: https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageManagerDocs/Documentation.docc/SwiftBuildPreview.md .

Quill admission also prepares a selected non-Gemma local ASR backend through `preloadRequired`, even if hosted dictation is selected. Its backend/model/language forms an additional preparation key, so an empty Gemma list cannot bypass that load. A suspended-preparation regression test verifies recording admission stays blocked until it completes. Local validation passed 69 application tests plus the 10-test encoder suite; fixture-only references skipped.

The available optional Quill model intentionally remains part of the shared pre-recording warm-up, following the explicit product requirement to finish a shared warm-up before allowing dictation. Missing or failed optional models remain best-effort and do not disable ordinary dictation. The review suggestion to move available Quill warm-up behind recording would reverse that requested behavior, so it was not applied. Computer-use harness work remains separate.

### Swift 6.3 CI compatibility correction

The Swift 6.3 preview build engine produced duplicate app-target outputs, so CI retains `--build-system native`. `build_mlx_test_metallib.sh` compiles only the resolved/pinned MLX checkout's ten prepared Metal sources with `xcrun metal`/`metallib` and upstream kernel flags. The shard runner supplies this library when SwiftPM did not produce one. This replaces the earlier Swift Build CI approach; no dependency/toolchain bump was introduced.

The new standalone library passed 70 application tests and the 10-test encoder suite locally (fixture-only reference cases skipped). A mocked shard invocation exercised discovery, actual Metal compilation, environment propagation, and skip-build test execution. Classifier, shard assignment, shell syntax, and diff checks passed.

Preparation no longer clears toggle-to-stop state during an active interaction/audio session. Native model override resolution is shared across path selection, download, and deletion, treating an empty value as unset. Legacy LiteRT overrides remain explicitly unsupported; no alternate weights are silently substituted.

### Model deletion isolation

Legacy general/cleanup override variables no longer suppress deletion of unrelated app-managed model directories. Deletion still never resolves an external override path and preserves shared drafter artifacts. Cache-path construction accepts the existing FileManager injection so deletion tests use isolated temporary homes rather than the maintainer's actual model cache. Tests cover all three Gemma models with both legacy overrides present and verify the external file and drafter remain. Final local validation passed 71 application tests plus the 10-test encoder suite (fixture-only references skipped).
