# Gemma E4B settings benchmark: native tool calling — 2026-10-05

**25/25 succeeded**, compared with [0/25 before these fixes](cua-gemma-e4b-settings-2026-10-05.md).

## Method

Same five commands, five round-robin rounds, downloaded E4B model, isolated five-setting fixture, temporary JSON persistence and unchanged success criteria as the baseline. Every attempt starts with the opposite value. Success requires the intended saved value, exactly one intended mutation, and all other settings unchanged. No live app preferences or desktop actions are changed.

Changes under test: LiteRT native function declarations and constrained decoding; correctly shaped system-message content; exactly one parsed native call with schema validation; mutation tools withheld until inspection and then limited to inspected setting IDs. This measures the combined change, not each component's individual contribution.

Latency includes planning, any bounded repair, mutation and save verification. The first attempt includes engine loading; subsequent attempts reuse the engine. No ASR, UI, full settings catalog or end-to-end desktop benchmark. E2B is not downloaded and was not measured.

## Results

| Command | Success | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 | Mean | Median |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Turn sound effects off. | 5/5 | 9.95s | 7.08s | 7.02s | 6.98s | 7.02s | 7.61s | 7.02s |
| Turn dark mode on. | 5/5 | 7.09s | 7.11s | 7.13s | 7.07s | 7.09s | 7.10s | 7.09s |
| Turn pause media during dictation on. | 5/5 | 7.09s | 7.12s | 7.16s | 7.10s | 7.07s | 7.11s | 7.10s |
| Turn open dashboard on launch off. | 5/5 | 7.13s | 7.19s | 7.08s | 7.10s | 7.12s | 7.12s | 7.12s |
| Change recording indicator style to notch. | 5/5 | 7.15s | 7.06s | 7.07s | 7.06s | 7.07s | 7.08s | 7.07s |

Overall mean **7.20s**, median **7.09s**. Warm-engine mean **7.09s**. The old approximately 5-second measurements were failures before mutation and must not be described as faster successful automation.

## Reproduce

Use the baseline command with `MUESLI_CUA_MATRIX_REPORT=/tmp/cua-settings-native-matrix.json`. The test body and success criteria are unchanged. Raw results: [JSON](cua-gemma-e4b-settings-native-2026-10-05.json), [CSV](cua-gemma-e4b-settings-native-2026-10-05.csv).

This small, repeated fixture demonstrates improved settings protocol reliability, not general desktop or unseen-command accuracy.

## Separate desktop and writing probes

These probes select calls only and never execute OS actions. They are not part of the 25-attempt settings score:

- Settings inspection and mutation passed.
- Calculator launch passed (6.37s).
- Cursor request (120, 80) emitted (20, 800), failing both exact-coordinate assertions (8.40s).
- Writing selected `edit_text` but omitted the observed element target, so the runtime decoder rejected it (9.74s).
- Separate writing generation passed: “Send the report when you have time.”

The opt-in broader benchmark therefore still fails, with three assertions/errors in two tests. No expectations were loosened. Native structured output does not establish semantic desktop accuracy.
