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

## Boundaries

Gemma uses LiteRT-LM; LFM/Qwen GGUF use the pinned llama.cpp through the local LLM.swift wrapper. A runtime or tokenizer upgrade is separate from an artifact revision. MLX integration and a newer llama.xcframework are not implemented here.
