# On-device Computer Use planner

Download Gemma 4 E2B or E4B in Models, then choose **On-device** under
Settings → Computer Use → Planner backend. Select the downloaded model in
**Planner model**. Requires macOS 15 or later. On-device hides ChatGPT sign-in and
Thinking; ChatGPT shows its own models and account controls. Without a downloaded
local model, On-device is unavailable and the UI explains where to download one.
Existing selections determine the backend automatically. Switching backends selects
the default ChatGPT model or the first available local model; reselecting the active
backend preserves its current model. Meeting-summary selections stay independent.
For an entirely local voice pipeline, also select an on-device dictation model.

The initial local planner uses text: the settings index and inspected choices,
Accessibility elements, tool results, and screenshot metadata. It does **not** see
screenshot pixels. It can choose existing native app-launch, keyboard, element,
and explicit-coordinate tools. It must report missing visual information rather
than guess image targets. App actions still use Muesli's existing driver and macOS
permissions. The model cannot submit arbitrary AppleScript or shell programs.

Local selection never falls back to ChatGPT. Missing models fail locally rather
than starting a download. Gemma uses LiteRT's native tool declarations and constrained
decoding. The adapter accepts exactly one structured tool call, validates its name
and arguments against the offered schema, and then invokes the existing executor.
Text-only responses, multiple calls and invalid arguments are rejected, with at most
one repair attempt. Settings mutation tools are withheld until inspection and then
restricted to the inspected setting IDs; executor checks remain in place.
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

## Initial E4B measurements (before native tool calling)

On the development Mac, the four synthetic planner fixtures produced three exact
results: settings discovery, settings mutation, and Calculator launch. The cursor
fixture returned a valid call with y=8 instead of the requested y=80, so the
benchmark correctly fails that assertion. Treat cursor planning as experimental,
not reliable unattended control. E2B was not downloaded and was not measured.
A separate settings round trip through the real local planner and shared executor
completed successfully in about 11 seconds using isolated test settings. These
measurements do not establish general desktop task accuracy.

## Shared writing with Quill

Quill remains the direct “write here” shortcut. Computer Use handles “do this”
workflows and delegates composition, rewriting and translation to `edit_text`.
Both use the Writing model configured under Quill, with the existing generation
prompt, length limits and output validation. The Quill shortcut toggle does not
disable CUA's writing tool. A local planner refuses a hosted writing backend;
select a downloaded on-device Writing model as well. No automatic model switch
or cloud fallback occurs.

The tool accepts an element ID, an index, or both when both resolve to the same AX element. Conflicting or unresolved references are rejected at capture and rechecked before writing.

The tool requires an observed editable AX element and an explicit `selection` or
`field` scope. Selection scope replaces the highlighted range, or inserts at a
zero-length cursor range; field scope replaces the entire field. Source text is
read by the tool rather than supplied by the planner. This initial adapter needs
a readable, writable plain-text AX value and (for selection scope) a valid range.
It does not focus the app, use clipboard fallback, or send/submit content. Quill's
direct shortcut retains its existing selection/paste adapter for other supported
editors. Changes to the captured text or selection invalidate the pending CUA edit;
selection edits also require the field to remain focused within its owning app,
without requiring that app to be foreground. Whole-field edits stay bound to the
explicitly observed target, so switching apps does not redirect background work.
Selection edits restore and verify a collapsed caret after the replacement using
UTF-16 offsets. If caret restoration fails, the result explicitly says the text
was updated. The text is read back after writing. A readback mismatch reports that the write
was accepted but could not be verified, and stops rather than retrying blindly.

Writing generation is excluded from CUA's execution timeout. Stop discards late
writing output before mutation. Literal `type_text`, `paste_text` and `set_value`
remain for exact supplied text, while planner instructions prefer `edit_text`
for generating prose. This routing is model-guided, not a keyword parser.

The initial native-tool E4B writing benchmark omitted its observed target. After
requiring either target identifier in the schema and explicitly describing that
requirement, the October 6 probe returned `edit_text` with `element_id: e1` and
`scope: field`, passing the unchanged assertion. The schema change alone still
failed before the description clarification. This is one successful synthetic
delegation probe, not an end-to-end editor accuracy claim. Writing generation
separately succeeds through the shared service on an isolated target.
The opt-in `writingDelegationWithGemma` and `writingGenerationWithGemma` tests keep
these two measurements separate.

## Native tool calling results

The unchanged five-command, five-round settings matrix improved from **0/25 to
25/25 successful verified changes**, with 7.20s average completion and 7.09s warm
average. See the [full comparison and raw results](benchmarks/cua-gemma-e4b-settings-native-2026-10-05.md).
These are isolated settings fixtures, not live voice or full-catalog measurements.

The separate fixed prompts passed settings inspection, settings mutation and
Calculator launch. Cursor arguments remain incorrect: requested (120, 80), emitted
(20, 800). Constrained decoding improves syntax; it does not guarantee correct
values or observed targets. No desktop actions are executed by these benchmarks.

## Planner limits and writing privacy

Before local generation, the runtime tokenizes the combined instructions, tool
schemas and task text and reserves 768 output tokens plus 2,048 tokens for template
overhead within the 16K context. This is a conservative preflight, not an exact
measurement of the runtime's rendered template. Oversized requests fail explicitly
without silently truncating element references or falling back to ChatGPT.

When a hosted Writing model is selected with a hosted planner, the requested
selection (or the entire field for field scope) is sent to that writing provider.
On-device CUA enforces local writing. The no-download policy is passed explicitly
from local CUA; direct Quill retains its existing model-availability checks.
