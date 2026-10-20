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
