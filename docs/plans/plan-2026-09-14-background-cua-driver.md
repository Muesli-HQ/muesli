# Native background CUA driver: next PR contract

Status: reference audit and implementation scope; no parity claim or runtime change yet.

Branch: `codex/cua-background-driver`, in worktree `b617/muesli`, based on
`05eb305db67d4b39beabf70388dc790d4d6c5a12` (merged PR #515).

## Outcome

A voice-triggered CUA run should operate its acquired target window while the
user continues working in another app or another window of the same app. Keep
the implementation inside the native Swift application. Use trycua as a source
of driver concepts and a behavioral reference, without bundling its Rust driver
or a Python/Node runtime.

The user also authorized a separate local-only branch,
`codex/cua-trycua-benchmark`, for direct upstream integration. External driver
dependencies are allowed on that benchmark branch. Both branches start from
PR #515 in this same worktree; commit changes before switching. Only one branch
can be checked out here at once. The benchmark branch is not a PR or release
source, and its integration must not be merged wholesale into this native branch.

Compare the same model/configuration and task fixtures in two ways: matched
primitive operations to isolate driver behavior, and end-to-end runs exposing
the upstream tool schemas to discover capabilities lost by a Muesli adapter.
Record schema/prompt differences explicitly in the latter comparison. Use
separate installed dev lanes and sequential builds with separate branch cache
paths. Neither driver may execute actions concurrently with the other.

The next PR is background execution and its necessary safety/ownership plumbing.
Tool-catalog consolidation, resumable confirmations, batching, planner changes,
and a general terminal-execution tool are separate work. Preserve the Stop,
permission, diagnostics, and success-state behavior shipped in #515.

## Reference provenance

Upstream examined on 2026-09-14, pinned to
[`39a206e637273385f39a41b3b8544e6d3ab5c099`](https://github.com/trycua/cua/tree/39a206e637273385f39a41b3b8544e6d3ab5c099).
The current macOS implementation is Rust; its focus-guard comments explicitly
describe the preceding Swift implementation. Implementation language does not
prevent recovering these mechanisms in Muesli's Swift process.

Primary references:

- [Background input v1 plan](https://github.com/trycua/cua/blob/39a206e637273385f39a41b3b8544e6d3ab5c099/libs/cua-driver/docs/macos-background-input-v1-plan.md): **proposed** contract, not evidence that every listed capability already works.
- [Mutation lease](https://github.com/trycua/cua/blob/39a206e637273385f39a41b3b8544e6d3ab5c099/libs/cua-driver/rust/crates/platform-macos/src/background_mutation.rs): serializes the complete background mutation lifecycle per process.
- [Focus guard](https://github.com/trycua/cua/blob/39a206e637273385f39a41b3b8544e6d3ab5c099/libs/cua-driver/rust/crates/platform-macos/src/focus_guard.rs): targeted suppression lease with a post-action settling interval; documents limitations relative to the original Swift layers.
- [Focus suppression](https://github.com/trycua/cua/blob/39a206e637273385f39a41b3b8544e6d3ab5c099/libs/cua-driver/rust/crates/platform-macos/src/focus_steal.rs): reactive restoration; restoration is not proof of zero transient focus changes.
- [SkyLight input bridge](https://github.com/trycua/cua/blob/39a206e637273385f39a41b3b8544e6d3ab5c099/libs/cua-driver/rust/crates/platform-macos/src/input/skylight.rs): private window routing and authenticated PID dispatch, including unsupported-ABI risks.
- [Regression tests](https://github.com/trycua/cua/blob/39a206e637273385f39a41b3b8544e6d3ab5c099/libs/cua-driver/rust/crates/platform-macos/src/tools/background_input_regression_tests.rs): mutation lifecycle serialization. These unit tests do not establish real-app delivery accuracy.

Use original Swift implementations where practical. Retain upstream MIT notices
and attribution for any code actually copied or translated.

## What is preserved in Muesli

The old implementation is still on `codex/muesli-cua-core` at `839a3cf8`, with an
earlier integration on `codex/cua-pr307-trim`. The embedded-runtime experiment on
`codex/cua-trycua-embedded-spike` is separate and is not the intended dependency.

The canonical historical record is
`/Users/pranavhari/Desktop/hacks/muesli/Context/handoff-2026-08-23-muesli-cua-core-session.md`.
It records one completed 38-step X account-switch/reply/verification run with no
reported focus steal, followed by harder runs failing surface acquisition and
Chrome AX availability. This is useful historical evidence, not current parity
or repeatability evidence.

| Concern | Current main | Preserved implementation to recover/rework |
| --- | --- | --- |
| Observation | Activates requested app, then reads its focused window; unresolved app may fall back to user frontmost | Exact acquired surface; refuse to observe another window when acquisition fails (`9a1e0e46`) |
| Pointer and key input | Multiple global HID event routes | Private event sources and scoped dispatch (`80a0a582`), with explicit capability checks |
| Window ownership | App-level target | `ComputerUseBackgroundSurface` and owner/liveness checks; validate at acquisition and immediately before mutation |
| Navigation/text | Foreground/active browser routes remain available | Atomic omnibox write and focus restoration (`46b4dc8b`, `9be163e1`, `0f70f4bb`), isolated from user's active tab |
| Reuse | No background owned-window lifecycle | AX liveness gate before adoption (`839a3cf8`) |
| Run mode | Foreground runtime | Pin interaction mode per run (`1d6d6b3c`) |
| Stop | Shipped in #515 | Preserve it and ensure cancellation reaches driver transactions |

## Driver contract

1. Carry an exact process and native window identity through acquisition,
   observation, element resolution, dispatch, and verification. A PID is not a
   window identity. A matching title or the app's focused element is insufficient.
2. Own or explicitly acquire the automation surface. Do not adopt an arbitrary
   sibling window just because the original disappeared, AX timed out, or a
   browser returned a different active tab.
3. Prefer exact-element AX operations. Use window-local pointer dispatch only
   when its required routing primitives and target evidence are available.
   Process-targeted keyboard input requires independent exact-window delivery
   evidence; stamping a window field onto a PID event is not that evidence.
4. Serialize mutations for the same process across proof, dispatch, cleanup,
   and verification. Different processes need not share a global input lock.
5. Use private synthetic event state. Background mode must not fall through to
   global HID events, global paste shortcuts, app activation, pointer warping,
   Space switching, or restoring a minimized window to make a route work.
6. Track user activity during asynchronous actions. Any reactive restoration
   must respect intervening user intent; it cannot continually reactivate the
   app that happened to be frontmost at run start. Report a transient focus
   steal even if restoration succeeds.
7. Check cancellation before dispatch and between multi-event operations. Pair
   every delivered synthetic down with its scoped up during cleanup, including
   failure/cancellation. Do not clear modifiers the user physically holds.
8. A dispatched event is not confirmed success. Verify state in the acquired
   window; distinguish dispatched, verified, unavailable, and cancelled in
   diagnostics. Refuse unavailable routes with enough information for the
   planner to choose another route.
9. Keep foreground behavior explicit and separate so a background refusal
   cannot accidentally invoke an existing foreground helper.

## Do not copy these old mechanisms unchanged

- Both the old Swift driver and pinned upstream bridge probe offsets 24, 32,
  and 16 inside a CGEvent to find a private event-record pointer. A non-null
  guessed pointer is not ABI validation. Isolate and validate any required
  private bridge; decline unavailable capabilities rather than guessing.
- The old no-raise focus handshake is disabled after the keyboard incident.
  Keep it disabled unless a separate native test establishes safe behavior.
- The old focus preventer's two-second activation heuristic can also catch an
  intentional user activation. Scope restoration to an action and account for
  user input instead of treating every activation as synthetic.
- The old session modifier janitor posts global releases for all modifiers.
  Automatic cleanup must release only synthetic state owned by the transaction.
- Static reusable-window bookkeeping and a missing-claim permissive check are
  insufficient: no acquired surface must mean no background mutation.

## Implementation order within this PR

1. Introduce run-owned target/session state and exact-window observation. Make
   no-surface and closed/stale-window behavior fail closed before adding input.
2. Port native AX and window-scoped input behind that boundary, with per-process
   transaction ownership, cancellation cleanup, and route-specific diagnostics.
3. Wire the existing voice/runtime path to a pinned background mode, recover
   isolated browser acquisition and the minimum text/navigation primitives
   needed for the benchmark. Preserve current tool schemas where possible.
4. Add native fixture tests and exercise the installed dev lane. Only then
   assess live browser benchmark reliability and PR readiness.

This order is internal to the background PR; it does not move background work
behind unrelated harness or UX PRs.

## Acceptance evidence

Record OS/app versions, build SHA, selected route, exact target identity, action
outcome, observed focus transitions, and whether user-window contents changed.
Do not retain unrelated user screen/text contents just to prove isolation.

| Scenario | Required evidence |
| --- | --- |
| AppKit fixture: background click, edit, scroll | Intended control changes; user app, cursor, and sibling fixture window stay unaffected |
| Two windows in one process | Delivery and verification both use the acquired window, including when the sibling is key/frontmost |
| User types or switches apps during CUA | No intercepted text/shortcuts and no stale focus restoration fighting the user |
| Unicode, multiline, and replacement text | Exact delivered contents and target-local readback; distinguish replacement from insertion |
| Stop during a multi-event action | Prompt cancellation, balanced synthetic events, no subsequent mutation |
| Target closes or ownership/AX state becomes invalid | Structured refusal; no retargeting to the user's window |
| Minimized, hidden, or other-Space target | Verified supported semantic route or explicit refusal; no implicit foreground transition |
| Required private symbol unavailable | Refusal or another proven scoped route, never global-event fallback |
| X benchmark with a known post | Account switch, compose, and verify in the acquired window while user remains elsewhere |
| X discovery variant | Find the intended recent post, compose, and verify; record acquisition and settling failures separately |

For repeatability, start with three consecutive successful runs for each X
variant, including one with the user working in another browser window. This is
an initial acceptance gate, not statistical proof of general reliability.
Publishing benchmark replies requires explicit authorization for the live send;
use drafts/local fixtures for earlier driver testing.

No scenario has been newly validated on this branch as of this audit. Historical
success, source similarity, and unit-test passes must not be presented as live
background-driver parity.
