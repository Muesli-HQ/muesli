# Gemma E4B settings benchmark — 2026-10-05

25 attempts: five commands, five rounds. **0/25 succeeded.** All 25 were rejected because the planner tried to change a setting before inspecting it. No persisted test setting changed.

## Method

- Branch `codex/cua-on-device-planner`; application source commit `40f3fcc8`, plus the opt-in matrix test.
- Downloaded Gemma 4 E4B via LiteRT, local inference; no ChatGPT.
- Five-setting fixture with canonical setting IDs, labels and choices; real `ComputerUseSettings` planner/executor and temporary JSON persistence. This is not the full live settings catalog, UI, hotkey, or speech recognition.
- All five settings offered on every attempt. Initial state resets before each command so success requires an actual change. Success also requires exactly the intended mutation, verified persisted value, and no changes to the other four settings.
- Round-robin order: sound, dark mode, pause media, dashboard, indicator; five rounds.
- Model unloaded once before starting, then reused. First sound attempt includes engine loading (not necessarily cold filesystem cache).
- Latency: monotonic elapsed time through `ComputerUseSettings.run`, including planning, internal repair attempts, mutation and executor verification if reached; excludes test setup, report writing and ASR.
- Production planning limit and bounded repair policy unchanged. No extra success-seeking retries. All failures retained.

## Results

These are **failure latencies**, not successful automation completion times.

| Command | Success | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 | Mean | Median |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Turn sound effects off. | 0/5 | 6.71s | 4.91s | 4.90s | 4.94s | 4.95s | 5.28s | 4.94s |
| Turn dark mode on. | 0/5 | 4.93s | 4.92s | 4.94s | 4.94s | 5.02s | 4.95s | 4.94s |
| Turn pause media during dictation on. | 0/5 | 4.94s | 4.94s | 4.96s | 4.97s | 5.00s | 4.96s | 4.96s |
| Turn open dashboard on launch off. | 0/5 | 4.93s | 4.98s | 4.97s | 4.99s | 5.03s | 4.98s | 4.98s |
| Change recording indicator style to notch. | 0/5 | 4.92s | 4.93s | 4.96s | 5.00s | 5.05s | 4.97s | 4.96s |

Overall mean 5.03s; median 4.95s; range 4.90–6.71s. Warm-engine attempts: mean 4.96s, median 4.95s. First attempt including model loading: 6.71s.

## Failure and interpretation

Every result was `failed` with “Inspect the setting before changing it. Nothing was changed.” All mutation lists were empty and all other-setting checks passed. The executor correctly enforced the inspection prerequisite; this fixture exposes a planner protocol-following failure, not a settings persistence failure.

Earlier one-setting tests had occasional successes. They offered a smaller catalog, so they should not be combined into this five-setting success rate. This small sample supports a conclusion about these exact prompts and fixture only.

## Reproduce

```bash
MUESLI_CUA_SETTINGS_MATRIX=1 \
MUESLI_CUA_BENCHMARK_MODEL='local:gemma4-litert:litert-community/gemma-4-E4B-it-litert-lm' \
MUESLI_CUA_MATRIX_REPORT=/tmp/cua-settings-matrix-results.json \
swift test --package-path native/MuesliNative \
  --scratch-path "$HOME/Library/Caches/muesli-spm/worktrees/b617-cua/test" \
  --filter ComputerUseLocalPlannerBenchmarkTests.settingsLatencyMatrix
```

The test deliberately exits with failure if any attempt fails, after completing all 25. It is disabled in regular CI. Raw per-attempt results: [JSON](cua-gemma-e4b-settings-2026-10-05.json), [CSV](cua-gemma-e4b-settings-2026-10-05.csv).
