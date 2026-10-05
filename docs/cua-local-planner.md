# On-device Computer Use planner

Download Gemma 4 E2B or E4B in Models, then select its **(on device)** entry in
Settings → Computer Use → Planner model. Requires macOS 15 or later. Only downloaded
local models are offered. Existing ChatGPT model selections keep their current behavior.
For an entirely local voice pipeline, also select an on-device dictation model.

The initial local planner uses text: the settings index and inspected choices,
Accessibility elements, tool results, and screenshot metadata. It does **not** see
screenshot pixels. It can choose existing native app-launch, keyboard, element,
and explicit-coordinate tools. It must report missing visual information rather
than guess image targets. App actions still use Muesli's existing driver and macOS
permissions. The model cannot submit arbitrary AppleScript or shell programs.

Local selection never falls back to ChatGPT. Missing models fail locally rather
than starting a download. Model output is parsed as one JSON tool call and checked
against the supplied schema before the existing executor validates and performs it.
Clarification history, settings prerequisites, fresh availability checks and save
verification use the same path as hosted planning.

The Gemma engine is shared with transcription and Quill, with serialized operations.
Planner calls expand its context allocation to 16K tokens. Settings planning retains
its cumulative deadline. Stop rejects late model responses; the synchronous LiteRT
inference call may take time to return before cancellation completes. This first
version has no screenshot-vision adapter or persistent model conversation cache.

## Adding another local runtime

Implement `ComputerUseLocalInferenceBackend`, then register model descriptors in
`ComputerUseLocalPlanner.models`. Stable IDs start with `local:`. The shared tool
contract, schema validator, settings definitions and native executor do not depend
on Gemma. LiquidFM and CUA-S1 are future candidates, not supported selections yet.
Adapters must explicitly handle their model's prompt/template and output format;
image-based models will also need an image-capable request interface before use.

## Reproducible planner benchmark

The opt-in suite uses fixed synthetic prompts and never executes generated desktop
actions or changes settings. It reports tool names, arguments and elapsed time
including initial model load. It is disabled during normal CI; it is not an
end-to-end desktop success benchmark.

```bash
MUESLI_CUA_BENCHMARK=1 swift test --package-path native/MuesliNative \
  --scratch-path "$HOME/Library/Caches/muesli-spm/worktrees/b617-cua/test" \
  --filter ComputerUseLocalPlannerBenchmarkTests
```

Set `MUESLI_CUA_BENCHMARK_MODEL` to a registered planner ID to compare one model at
a time. Add the same fixtures for future runtime adapters before comparing results.

## Initial E4B measurements

On the development Mac, the four synthetic planner fixtures produced three exact
results: settings discovery, settings mutation, and Calculator launch. The cursor
fixture returned a valid call with y=8 instead of the requested y=80, so the
benchmark correctly fails that assertion. Treat cursor planning as experimental,
not reliable unattended control. E2B was not downloaded and was not measured.
A separate settings round trip through the real local planner and shared executor
completed successfully in about 11 seconds using isolated test settings. These
measurements do not establish general desktop task accuracy.
