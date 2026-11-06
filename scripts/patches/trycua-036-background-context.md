# trycua 0.36.0 background benchmark driver

Base: `cua-driver-rs-v0.36.0`, commit
`6d6c734c127025fb39ad5d585a10382808b39dc1` in https://github.com/trycua/cua.

Apply `trycua-036-background-context.patch` from the upstream repository root.
It is a complete patch against the pristine release; do not also apply the
older `trycua-05d1494-*` patches. Those remain historical references.

```sh
git checkout 6d6c734c127025fb39ad5d585a10382808b39dc1
git apply /path/to/muesli/scripts/patches/trycua-036-background-context.patch
cd libs/cua-driver/rust
cargo +1.97.1 build --locked -p cua-driver
```

## Preserved background behavior

- Reuse the approved browser socket. In manual reconnect mode, ordinary commands
  and status queries cannot reconnect, trigger approval, or reopen setup.
- Explicit background preparation atomically claims an existing socket without
  dialing or entering foreground setup. Missing consent is reported to the host.
- Socket-close events update connection state without periodic status queries.
- Host-enabled profile scope permits rebinding to another exactly identified
  window in the same approved profile, retaining process/session boundaries.
- New tabs are created in the background in the bound window, checked before
  navigation, and do not replace the anchor target.
- Exact AX window matching and refusal of foreground setup fallbacks remain.
- Overlay inspection prefilters candidates before expensive layout checks.

The existing host sets `MUESLI_CHROME_MANUAL_RECONNECT=1`,
`MUESLI_CHROME_PROFILE_WINDOW_SCOPE=1`, and its private
`MUESLI_CHROME_EVENTS_PATH`. Do not expose these as model-controlled options.

## Scoped page evidence

Query matches now include bounded nearby semantic context from the nearest
article, form, dialog, menu, list item, or row. Expansion stays within an explicit
`scope_ref`, skips hidden/occluded subtrees, selects at most 64 meaningful nodes per container (with a 256-node traversal cap),
and adds at most 128 context nodes overall. Existing pagination still applies.
An unmatched query remains empty; this is not an automatic whole-page fallback.

Refs expose `query_match`, observed anchor `href`, and an absolute HTTP(S)
`destination` resolved against the owning frame's document base. Unsupported
schemes have no destination. These are page data, not navigation instructions or
new action capabilities. Links are not followed during inspection.

## Regression checks

```sh
cargo +1.97.1 test --locked -p cua-driver-core --lib browser::
MUESLI_CHROME_MANUAL_RECONNECT=1 \
MUESLI_CHROME_PROFILE_WINDOW_SCOPE=1 \
MUESLI_CHROME_EVENTS_PATH=/tmp/cua-test-events.jsonl \
cargo +1.97.1 test --locked -p cua-driver-core --lib browser::v2_tests::muesli_ -- --ignored --test-threads=1
cargo +1.97.1 test --locked -p cua-driver-core --lib muesli_profile_scope_rebinds -- --ignored
cargo +1.97.1 test --locked -p platform-macos --lib browser::setup_ui
cargo +1.97.1 test --locked -p platform-macos --lib ax::exact_target
```

The opt-in tests exercise process-scoped environment policies separately from
normal upstream tests. Page-context fixtures cover scope boundaries, hidden
nodes, bounded expansion, unchanged action authority, and iframe-relative URLs.
A real browser benchmark with foreground monitoring is still needed to measure
performance and focus behavior on a live page; unit tests cannot establish that.

## Operation lifetime and execution deadline follow-up

Fresh flattened CDP sessions now have operation-owned cleanup. Observations,
continuations, screenshot reads, successful mutations and refused mutations
release their top-level session (and attached iframe agents). Snapshot refs
retain document/target identity, not the transient session. Cancellation also
schedules cleanup while the runtime exists; transport shutdown closes the socket.

Trusted wheel input retains upstream focus emulation and cleanup. An isolated
attempt without renderer focus timed out waiting for Chrome's wheel acknowledgement,
so that attempted change was reverted. Driver call logs include wall-clock start
timestamps for correlation with foreground events, without page contents.

The Muesli reference harness passes its remaining execution allowance into each
RPC; the previous unrelated 30-second per-call cap could kill the driver after
several valid revalidation subcalls. Model thinking still does not consume the
execution allowance. A dev-only `--computer-use-start-signal PATH` barrier lets
isolated probes finish before the queued planner uses the same Chrome connection.

Regression checks additionally cover balanced attach/detach on observations and
stale-ref refusal, and wheel dispatch restoring renderer focus without native activation.

## Semantic context follow-up after run 609

The 33-read trace contained partial-word query matches ("Switch account" returned
unrelated "Verified account" nodes), empty layout wrappers consuming up to
101/300 output slots, and relative links with no resolved destination.

- Query fallback requires every term on one node; words scattered across
  unrelated controls no longer masquerade as a match. Empty results remain
  scoped evidence, never proof of whole-page absence.
- Unnamed, stateless, non-actionable layout wrappers remain in the internal tree
  for scope/ancestry, but consume neither output slots nor outline indentation.
- Context expansion counts up to 64 meaningful nodes per container, separately
  capped at 256 visited nodes, with the existing 128-added-node global limit.
- A text editor without a semantic form ancestor can expose a nearby small
  control group containing buttons. Explicit scope and hidden/occluded boundaries
  still apply; broad main/navigation/document ancestors are never substituted.
- Links inherit their own document base even when CDP omits its frame ID.
  Child documents do not inherit the parent's base or action authority.

These are semantic tree changes, not command/site-specific routing. No automatic
submission, synthetic input, cached stale refs, or foreground fallback is added.


Validation: 223 browser regression tests passed, including five focused tests for
query precision, empty-wrapper budgets, deep-wrapper context, editor control
scope/visibility, and frame-ID-free document bases. The read-only live check on
run609's existing reply returned all 269 meaningful nodes in one complete snapshot
versus the recorded 300/467 partial snapshot. Outline length fell from 16,763 to
8,489 characters; structured response from 76,451 to 65,183 characters. Dynamic
page state can change, so these are observed context measurements, not a controlled
claim about planner call count. All 23 observed relative links resolved and
"Switch account" returned no spurious matches. No new post or text mutation.

### Accessibility/vision-only comparison

DevA accepts `--trycua-accessibility-only` alongside `--trycua-driver`. This
removes all browser tools from the planner catalog and dispatch allowlist and
uses Accessibility/window-screenshot instructions. Do not pass
`--computer-use-wait-for-chrome` for this mode. Non-browser calls do not probe
Chrome connection status. Background delivery restrictions remain in place.

An off-Space Chrome window may expose stale Accessibility content or fail window
capture. Treat that as an observation limitation, not permission to activate the
window, enable debugging, or submit an unverified action. The October 20 live X
reply comparison stopped after window inspection, without mutation: SkyLight,
ScreenCaptureKit and screenshot fallback could not capture window 84 on another
Space. This is not evidence that all Accessibility-only browser tasks fail.

### Off-Space screenshot capture

The native capture path uses `SCScreenshotManager.captureSampleBuffer` on every
Space, avoiding a race between observing the current desktop and capturing the
window. Native capture precedes the backing-store fallback on both routes. The existing bounded worker, capture identity revalidation, geometry
checks and background-input refusal rules remain in force.

This addresses an observed fullscreen Chrome failure: public image capture
returned ScreenCaptureKit error -3811 on an inactive Space while sample-buffer
capture returned the full 3024x1654 window without activation. Pixel conversion
checks dimensions, BGRA format, row stride, alpha and transparency. Capture tests
cover padded rows, truncated data, overflow, transparent images and fallback
ordering. This does not establish that every returned frame or AX tree is current;
lock state and post-action verification still matter.

The unlocked October 20 follow-up captured window 84 on another Space with a
valid frame and an exact AX target. A reversible Gmail sidebar AXPress pair
returned `unverifiable`; the before, intermediate and final screenshots were
byte-identical, and AX content was unchanged apart from snapshot tokens. The
monitor recorded Codex foreground throughout all 876 samples of that test.
This verifies off-Space capture without observed activation, but does not
establish fresh post-action rendering or successful background interaction.
Do not remove the stale-content warning or promote AX delivery to confirmed
success on the strength of the capture fix.

An additional isolated experiment bypassed the pixel click's AX hit-test
shortcut for off-Space browsers. On X, opening More and dismissing it used
`synthetic_events`, but three captures remained identical. Chrome never became
foreground during that action sequence. The experiment was removed: it did not
demonstrate an improvement and should not change the shipped routing policy.
Neither test establishes whether Chrome ignored or deferred the action, or
whether only observation was stale. Do not retry externally visible mutations
on the assumption that an unchanged screenshot proves no effect.

Related upstream reports:
- https://github.com/trycua/cua/pull/4996 explicitly records Chrome pixels and AX
  updating only after its Space was shown.
- https://github.com/trycua/cua/issues/4243 remains open and describes some
  Chrome controls ignoring both background AX and pixel clicks.

Same-desktop control test (October 20): with Chrome window 84 on desktop 1
and Claude foreground, an AXPress opened GitHub's quick-search overlay.
The first capture showed the transition while the AX tree lagged; a later
read contained the search combobox and suggestions. Exact-window background
Escape dismissed it, and the final PNG hash matched the pre-action PNG.
Claude stayed foreground throughout 2,142 monitor samples spanning the open,
readback and dismissal sequence. No browser integration or foreground delivery
was used. This demonstrates working background AX plus vision on the same
desktop; it is not a controlled same-page comparison with the earlier Gmail/X
off-Space tests, nor proof that every Chrome control works.

Reference: AltTab's documented API distinction for inactive fullscreen Spaces:
https://github.com/lwouis/alt-tab-macos/blob/master/src/events/WindowCaptureEventsSpecs.md
Apple API:
https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/capturesamplebuffer(contentfilter:configuration:completionhandler:)

## Desktop-transition capture follow-up

Window capture now uses the desktop-independent sample-buffer API on every
Space. The earlier choice between image and sample-buffer capture was made
from a momentary current-Space check; the user could switch desktops before
capture completed. Capture still validates the exact window identity and
rejects malformed or transparent buffers. It does not activate or move windows.

This removes that API-selection race, not the remaining Chromium repaint/AX
freshness limitation. A captured frame is not evidence that an action took
effect. A permanently blocked synchronous ScreenCaptureKit callback can still
hold the bounded worker gate; do not release the gate while that worker remains
alive or replay uncertain mutations as recovery.

## Background navigation guidance

The off-Space observation warning no longer tells callers to show the window
before verification or claims that input was delivered. Space membership is
possible-staleness evidence, not a delivery result. The warning retains the
requirement for observed effects and explicit route refusals. Muesli's AX-only
planner now inspects unfiltered navigation controls after a query miss, separates
navigating from publication identity checks, and does not terminate solely for
an unrelated initial page or off-Space status. This does not enable shortcuts,
foreground fallback or arbitrary script execution.

## Synthetic focus port

Ported the temporary AXFocused/AXMain save/write/restore layer from
`libs/cua-driver/swift/Sources/CuaDriverCore/Focus/{FocusGuard,SyntheticAppFocusEnforcer}.swift`
at upstream commit `53e6736f0bc549d5be01fcc550a180b7cac4f10f` (the Swift port
was later removed). Chromium enablement already exists in Rust and is reused.

Background AX click, text and value workers hold the synthetic lease inside the
existing reactive suppression scope. It validates the window ID and owning PID,
skips minimized or unknown minimized state, only changes readable false focus
attributes, and restores successful writes on normal return or unwind. The lease
stays on the blocking AX worker so cancellation cannot restore state before the
underlying action finishes. Failed writes and already-focused attributes are left
alone; cleanup does not overwrite a value observed to have changed externally.

Four focused regression tests cover restoration, unwind, minimized/unknown state,
unreadable attributes, failed writes, preexisting focus and external changes.
This is best-effort compatibility behavior, not proof of zero native activation.
The live benchmark must still verify focus and action outcomes independently.

## Host read recovery

The Swift host now keeps the existing MCP transport and approved Chrome socket
while a timed-out or cancelled observation drains, for up to 30 additional
seconds. No new command can start during recovery, late data is discarded, and
command-session cleanup waits for recovery. Malformed/closed transport, exhausted
recovery, setup and uncertain mutations still terminate the driver. No operation
is automatically replayed. Explicit command-session cleanup errors alone no
longer invalidate the independent Chrome session.

The dev-only `--trycua-connect-approved` launch option attempts background
attachment without opening setup, launching Chrome, or escalating to foreground
consent. If a new connection needs approval, it reports that prerequisite.
This does not persist approval across application/daemon restarts or override
Chrome's consent expiry. `--trycua-browser-only` excludes all native mutation
fallbacks from both the planner catalog and dispatch allowlist.

## Post-action observation settling

The host now treats CDP input acknowledgement as delivery, not a rendering
barrier. In an isolated account-menu comparison, the first screenshot and
semantic snapshot after a trusted click showed the closed menu; the following
read showed it open without another click. The same lag appeared when closing
the menu through the DOM-event route. Changing click routes or replaying the
click would therefore be the wrong recovery for this case.

After a browser mutation, Muesli performs up to four screenshot-backed reads,
350 ms apart, within the remaining execution allowance. It stops early when
semantic evidence has changed from the last comparable full snapshot and matches
across two reads. Rotating refs and focused-state changes do not count as page
changes. A transient `browser_route_unavailable` observation refusal (such as
a frame replaced during navigation) is retried within the same four-read bound.
Consent, identity, transport failures, missing images, cancellation, lock and
deadline stop the check.
Only the final observation is added to planner history; all calls remain in the
raw trace. An unchanged or continuously changing page is explicitly unconfirmed,
never an instruction to replay input or proof that a submission failed. The
planner still verifies identity, destination and the requested outcome. This is
a generic harness observation policy; the driver's input route is unchanged.
