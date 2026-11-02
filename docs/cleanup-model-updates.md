# Cleanup model updates

Muesli-published cleanup models (Cleanup Lite, Pro Cleanup — Qwen 3.5, Pro Cleanup — LFM 2.5) can be updated
without shipping a new app. Installed users see an **Update** pill on the sidebar's Models row; the model's card
moves to the top of Models → Cleanup with an **Update** button (release notes on hover and in the confirmation),
and its select button reads **Use Legacy for Cleanup** until updated. Nothing downloads until they confirm. Versions
are internal and never shown to users.

## How it works

- **Slots.** Each managed cleanup option (`PostProcessorOption.id`) is a `CleanupModelSlot` with a fixed runtime
  (`mlx-qwen3.5` or `gguf-lfm2.5`), prompt contract and model filename. Only the weights change between releases.
- **Releases.** A `CleanupModelRelease` pins a `Muesli-HQ/*` repo to a full commit hash, with every file's size and
  SHA-256. Releases are ordered by an integer `sequence` (v14 → 14).
- **Bundled releases.** `CleanupModelRelease.swift` holds the newest release each app build knows. An app update that
  bundles a newer release shows the update offline.
- **Signed catalog.** `docs/models/cleanup-models.json` is served by GitHub Pages at
  `https://muesli-hq.github.io/muesli/models/cleanup-models.json`, with a detached Ed25519 signature in
  `cleanup-models.json.sig` made by the Sparkle update key. The app checks it at launch and when the Models page
  opens (at most every six hours). An unsigned, tampered or malformed catalog is ignored.
- **App-side checks.** A catalog entry is used only if its slot exists, its runtime and model filename match the slot,
  its repo is under `Muesli-HQ/`, its revision is a commit hash, its file names are plain, and
  `minimum_app_version` (optional) is met. The highest valid `sequence` per slot wins; the catalog can never
  downgrade the bundled release.
- **Install.** Downloads go to `postproc-<id>.pending-<revision>` beside the live folder. Files unchanged from the
  installed build are APFS-cloned, so only changed files are fetched. After every size and digest verifies, a
  `.muesli-cleanup-release.json` marker is written and the folder is swapped into place. The old model keeps
  working until the swap, then the loaded engine is dropped and the next dictation loads the new build.
- **Pre-marker installs.** Folders installed before markers existed are identified by the v12 file sizes
  (`unmarkedLegacy`).

## Publishing a new cleanup model

1. Upload the model to `Muesli-HQ/<repo>` on Hugging Face. Keep the slot's runtime, prompt contract and model filename
   (`model.safetensors` for MLX Qwen slots). A model that needs a new runtime, tokenizer workaround or prompt needs an
   app release instead; gate it with `--minimum-app-version`.
2. Evaluate it in asr-finetune and run it through the production MLX path
   (`CleanupMLXEvaluationTests.qwenProductionMLXGolden`).
3. Add it to the catalog. Sizes and digests are read from the Hub:

   ```bash
   scripts/cleanup_model_catalog.py add qwen35-2b-cleanup-v12 v15 15 \
     Muesli-HQ/qwen35-2b-muesli-cleanup-v15-mlx-8bit <40-char-commit> \
     --notes "One plain-language sentence for users; no version or dataset names."
   scripts/cleanup_model_catalog.py check --remote
   ```

4. Sign it with the Sparkle key from the Keychain and verify against the app's public key:

   ```bash
   scripts/sign_cleanup_model_catalog.sh
   ```

5. Commit `docs/models/cleanup-models.json` and `.sig` in a PR. Users are offered the update once it merges to `main`
   and GitHub Pages deploys. Also bump the bundled release in `CleanupModelRelease.swift` in the next app release.

Slot ids are historical (`qwen35-2b-cleanup-v12` hosts v14); never rename them, or installed users lose their
selection.

## Testing locally

Dev and lane builds (not `com.muesli.app`) can read an unsigned local catalog:

```bash
MUESLI_CLEANUP_MODEL_CATALOG_URL=file:///path/to/cleanup-models.json \
MUESLI_CLEANUP_MODEL_CATALOG_ALLOW_UNSIGNED=1 \
  /Applications/MuesliDevA.app/Contents/MacOS/MuesliDevA
```

To see the v12 → v14 update path, install Cleanup Lite or Pro Cleanup — Qwen 3.5 with a build from `main` (v12),
then launch this build: Lite and Pro Qwen move to the top of Cleanup with an **Update** button.
