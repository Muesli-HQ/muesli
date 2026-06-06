# AGENTS.md

## Build Artifacts and Worktrees

SwiftPM can write build artifacts to `native/MuesliNative/.build` inside the active worktree. That can consume several GB per worktree when multiple feature worktrees are used.

Local build scripts resolve a shared SwiftPM scratch path through `scripts/muesli_spm_cache.sh`:

- If `MUESLI_SWIFTPM_SCRATCH_PATH` is set, that explicit path wins.
- If `MUESLI_SWIFTPM_SCRATCH_CHANNEL` is set, scripts use that channel under the resolved cache root.
- If `MUESLI_EXTERNAL_SPM_CACHE_ROOT` is set, it replaces the default `/Volumes/MuesliBuildCache/muesli-spm` external cache root.
- Otherwise, if `/Volumes/MuesliBuildCache/muesli-spm` is mounted, scripts use that external APFS cache.
- Otherwise, scripts fall back to `$HOME/Library/Caches/muesli-spm`.
- Set `MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1` to intentionally use SwiftPM's package-local `.build`; this takes precedence over all scratch path settings.

The external cache lives in an APFS sparse bundle at `/Volumes/eSSD/MuesliBuildCache.sparsebundle`; attach it before build-heavy work:

```bash
hdiutil attach /Volumes/eSSD/MuesliBuildCache.sparsebundle
```

`/Volumes/eSSD/MuesliBuildCache.sparsebundle` is the maintainer's local SSD path. Contributors can substitute their own volume path or skip the attach step; scripts fall back to `~/Library/Caches/muesli-spm` when the external cache is not mounted.

Default channels:

```bash
./scripts/dev-test.sh                 # /Volumes/MuesliBuildCache/muesli-spm/worktrees/<worktree>/dev when mounted
./scripts/build_native_app.sh release # /Volumes/MuesliBuildCache/muesli-spm/release when mounted
./scripts/release-preprod.sh          # /Volumes/MuesliBuildCache/muesli-spm/preprod when mounted
```

For direct or concurrent worktree builds, pass a specific path:

```bash
MUESLI_SWIFTPM_SCRATCH_PATH="/Volumes/MuesliBuildCache/muesli-spm/worktrees/pr182/dev" ./scripts/dev-test.sh
swift test --package-path native/MuesliNative --scratch-path "/Volumes/MuesliBuildCache/muesli-spm/worktrees/pr182/test"
```

Caveat: do not run concurrent builds from different worktrees into the same scratch path. Use separate paths per channel, agent, or simultaneous build, such as `worktrees/pr182/dev`, `worktrees/pr188/dev`, or `agent-1`.

Deleting a scratch path only removes rebuildable SwiftPM artifacts. It does not delete installed app bundles or app data under `~/Library/Application Support/`.

For direct SwiftPM test runs, pass the scratch path yourself:

```bash
swift test --package-path native/MuesliNative --scratch-path "/Volumes/MuesliBuildCache/muesli-spm/test"
```
