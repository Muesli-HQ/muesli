# Strict-background reference setup patch

> Current benchmark upgrade: see [trycua 0.36.0 background context](trycua-036-background-context.md). Its consolidated patch replaces this older patch stack when building 0.36.0.


Local benchmark only; not part of the native Swift shipping driver.
Applies to trycua/cua `05d14942609e907e3d3a3e09bf1886adeffacb9b` (0.35.4).

The initial setup inspection previously walked the entire current website and
refused on its unrelated node-budget truncation. Inspect browser controls with
closed menus collapsed and web-document descendants omitted. If the address bar
already names the setup URL, use the original full walk. Full setup-page,
checkbox identity, and truncation checks remain in place before checkbox writes.

This local build also refuses every setup foreground-assist callback, including
cleanup fallbacks. Existing-profile authorization does not authorize foreground
activation or global input. This can safely block attachment; it is not a claim
that every Chrome configuration supports background setup. Other self-activating
AX actions still require monitoring.

Reproduce in a checkout at the pinned commit:

```sh
git apply /absolute/path/to/trycua-05d1494-scoped-setup-inspection.patch
cd libs/cua-driver/rust
cargo test --locked -p platform-macos --lib browser::setup_ui
cargo build --locked -p cua-driver
```

Use a distinct cache location from the unmodified upstream binary. Replay through
DevA with `MUESLI_REFERENCE_DRIVER` pointing at this build and
`MUESLI_REFERENCE_AUTHORIZE_EXISTING_PROFILE=1` after explicit user authorization.
Keep the focus monitor active. Driver version still reports 0.35.4; executable
path and this patch distinguish this local variant from upstream.

## Chromium element ownership correction

Apply `trycua-05d1494-window-identity.patch` after the setup patch. Chromium
sometimes exposes an AXGroup through AXWindow. Reject that intermediate
compositor ID and let the existing bounded AXParent ascent prove the owning
AXWindow/AXSheet. Foreign top-level IDs still fail the target gate; unknown
ancestry is not accepted. The sheet-to-parent behavior is preserved.

Validation: 12 exact_target unit tests pass. Live run577 dispatched the formerly
refused X account-menu AXPress with background delivery. Its effect remained
unverifiable because Chromium's off-Space accessibility state stayed stale.
This is a verified identity-gate fix, not a completed draft benchmark.

Combined local binary: `~/Library/Caches/muesli-trycua/05d1494-scoped-setup-identity/arm64/cua-driver`.
Chrome's initial browser connection still cannot complete in this fixture with
foreground assistance prohibited. Do not remove that restriction or treat
explicit existing-profile authorization as approval to steal focus.

## Manual Chrome connection and reconnect

Apply `trycua-05d1494-manual-chrome-reconnect.patch` after the patches above.
Muesli sets `MUESLI_CHROME_MANUAL_RECONNECT=1` on the driver: a lost existing-profile
socket returns `browser_consent_required` instead of redialing and potentially
activating Chrome. `browser_prepare` remains available only to the Settings
Connect/Reconnect action; it is excluded from the background planner catalog and
blocked at background dispatch. The manual action deliberately opens Chrome's
setup page and permits foreground attachment. The conservative setup fallback
restrictions above remain in place; enable the checkbox manually if requested.

The host retains a dedicated browser session across commands, because ending that
session revokes its profile grant. Ordinary task sessions still end individually.
Chrome exit, driver shutdown, known consent refusals and conservative idle/total
expiry invalidate the displayed connection. Reconnection is always explicit.

Build using Rust 1.97.1, then use a distinct binary cache directory:
`~/Library/Caches/muesli-trycua/05d1494-manual-chrome-connect/arm64/cua-driver`.
The driver is still a local benchmark dependency, not bundled into production.

Regression test (mock CDP, no real Chrome interaction):

```sh
MUESLI_CHROME_MANUAL_RECONNECT=1 cargo +1.97.1 test --locked -p cua-driver-core \
  --lib muesli_manual_reconnect_never_redials_after_socket_loss -- --ignored
```

The manual-reconnect patch also makes browser_prepare discovery-only when no
endpoint exists: it returns browser_requires_setup before any setup UI actions.
The host opens setup at most once per explicit Connect operation, then polls for
up to 180 seconds. Existing endpoints attach immediately without opening setup.
Chrome approval receives up to 120 seconds within that operation. Only the
requires_setup refusal retries; other refusal messages reach the Settings UI.
Current cached binary: ~/Library/Caches/muesli-trycua/05d1494-wait-chrome-connect/arm64/cua-driver.
Run both mock regressions with filter `muesli_manual_` and `-- --ignored`.

Revocation status: browser_connection_status is a host-only read-only tool that
looks up the retained session grant and existing socket. It never discovers an
endpoint, dials a socket, observes a page, or invokes browser_prepare. The
Permissions view checks every five seconds when visible and the host is idle;
command ownership prevents transport races. A lost socket clears Connected.
Current binary: ~/Library/Caches/muesli-trycua/05d1494-chrome-status/arm64/cua-driver.
The socket-loss regression checks the probe before/after loss and asserts no new
connection was accepted by the mock server. The planner does not see this tool.

## Event-driven status (supersedes five-second polling)

Apply `trycua-05d1494-chrome-events.patch` after the patches above. The driver
publishes socket closure through a Tokio watch channel. The host registers once
on Connect (`browser_connection_status`, watch=true); the listener appends one
session-scoped event to the host-owned private file specified at daemon launch.
Muesli observes that file with DispatchSource filesystem events, with no recurring
status requests. The session identifier rejects late events from old connections.
Daemon/proxy termination handlers and one-shot idle/absolute expiry tasks also
invalidate connection state. Opening Settings still performs one reconciliation
probe; only an explicit Connect retains bounded endpoint polling.

The old temporary source tree lost build manifests. The same pinned upstream
archive was restored at /tmp/muesli-trycua-events-20261019. Apply all four patches
there; the Cargo target cache can still be reused from the earlier path. New
executable cache: ~/Library/Caches/muesli-trycua/05d1494-chrome-events/arm64/cua-driver.

### Live event revocation verification (2026-10-19)

Real dispatcher testing exposed two gaps missed by direct tool mocks: the status
tool lacked a reviewed risk classification, and emitted disconnects contained
runtime-private session IDs. The event patch now classifies metadata-only status
as R0 and uses the existing public-session label conversion for emitted events.
The event regression uses a namespaced session. Authorization and all three
manual-connect/event regressions pass.

DevA with `05d1494-chrome-events-public-session/arm64/cua-driver` changed from
Connected to Reconnect within a 187 ms observation bound after disabling Chrome's
actual remote-debugging checkbox. Only the initial watch subscription was sent;
no status RPC followed revocation. During revocation the foreground app remained DevA; a later switch to Codex
was recorded after the status observation. Chrome never activated. The window-order proxy changed among DevA windows, so this
is not a claim about exact AX key-window identity. Chrome access was left revoked.
Live evidence: `/tmp/cua-revoke-final-20261019/result.json` and driver artifacts
`/tmp/muesli-reference-D7F94DDB-8BB3-455A-BE02-AB7E99CCBCE3`.

### Profile connection / per-window capability separation (2026-10-19)

Apply `trycua-05d1494-profile-window-scope.patch` after the chrome-events patch.
DevA opts in through host-only `MUESLI_CHROME_PROFILE_WINDOW_SCOPE=1`. The grant
captures that scope when minted; public model arguments cannot expand it. Protected
approval metadata/description names the scope. The original setup window remains
the cleanup anchor. Process fingerprint, endpoint ownership, transport/session,
revocation and expiry remain checked. Each additional native window must pass exact
native/CDP correlation before receiving its own target capability; heuristic
cross-window matches are refused. Default upstream single-window scope is unchanged.

Regression checks: scoped reuse does not open a new socket/setup; other session,
other PID, missing target and revoked consent are refused. Default-scope variant
also passes. Existing browser v2 suite: 56 passed, 4 ignored. DevA rebuilt using
the existing b617-cua caches; signature and packaged LocalVQE runtime verified.
Driver: `~/Library/Caches/muesli-trycua/05d1494-profile-window-scope/arm64/cua-driver`.

Live check run 585: manual browser_prepare succeeded on window 91; get_browser_state
succeeded on X window 84 with binding_quality=exact and existing_profile_approved.
No second prepare/approval was needed. Subsequent semantic_v2 page snapshot timed
out at host transport, ending the run failed; do not report full browser automation
as passing. No posting/mutation occurred. Evidence /tmp/cua-window-binding-live and
/tmp/muesli-reference-3CDD2EF4-D821-45A0-B3FC-1B3C8FA8D775. Chrome was foreground
after manual connection setup, so this does not establish typing continuity with
another app in front.

### Semantic page-read CPU bottleneck (2026-10-19)

Live direct driver probes against the same public repository tab took 27.118s
and 26.942s. CDP data retrieval was subsecond (DOM.getDocument 95ms, layout
143ms, AX tree 304ms). Active stack sampling identified apply_page_occlusion /
DomIndex ancestry walks as the hot path. It checked DOM ancestry against every
layout node before rejecting static/non-covering/non-hit-testable boxes.

`trycua-05d1494-semantic-read-performance.patch` prefilters positioned painted
hit-testable candidates once and checks paint/bounds before ancestry. The
occlusion conditions are preserved. Nine semantic tests pass, including a new
filter matrix (fixed/absolute/static, pointer-events:none, hidden, lower paint,
nonoverlap) and the existing covered-action and dialog-descendant tests. Method
timing diagnostics log only method names and elapsed time, no page data.

Rebuilt driver: ~/Library/Caches/muesli-trycua/05d1494-semantic-read-performance/arm64/cua-driver.
Live optimized measurement and authorized reply retry pending: Mac locked and
X absent from currently bound Chrome window's 33-tab list. User asked to unlock
and open X, then return to another foreground app. No reply posted.
Evidence: /tmp/cua-driver-read-active-sample.txt, /tmp/cua-direct-read-output.log,
/tmp/cua-direct-read-third.log, /tmp/cua-read-semantic-final-tests.log.

### Missing-site recovery (2026-10-19)

Apply `trycua-05d1494-background-new-tab.patch` after the semantic-read patch.
`browser_navigate(new_tab: true)` treats tab_id as an observed anchor, revalidates
its grant, derives its browser context, and creates about:blank with background=true
and newWindow=false. It verifies the new tab belongs to the bound window and
revalidates access before navigating. It never activates Chrome or replaces the
anchor. Failures after creation preserve the blank tab and report partial effects.
The planner receives this recovery path instead of asking users to open websites.
58 browser regression tests pass (4 pre-existing ignored), including forced
background parameters and stale-anchor refusal. Live validation pending.
Driver cache: ~/Library/Caches/muesli-trycua/05d1494-background-new-tab/arm64/cua-driver.

Live run 588 opened X in a new inactive tab, switched to @fastspeech2text,
and located https://x.com/fastspeech2text/status/2080507946241560757 from a
latest-first account/CUA search. No text was typed or submitted: the old
append-only planner history hit its 240k-character ceiling. During the task
there was no Chrome foreground activation; the user switched cmux -> Codex
and the run continued. Evidence /tmp/cua-new-tab-live.

Same-public-tab timing after optimization: 3.098s versus 27.118s/26.942s
before (about 8.7x faster), /tmp/cua-optimized-read.log. X semantic reads were
roughly 1s. The preparation probe reused the approved connection with no
setup page, consent prompt, or activation.

The host now retains the newest two page snapshots and preserves every action
and mutation outcome plus older page/binding metadata. Old snapshot contents
and refs are explicitly marked stale and require fresh inspection. This
prevents stale snapshots accumulating indefinitely without losing submission
outcomes or permitting retries of uncertain actions.

Run 589 exposed a history-compaction flaw: removing old observation facts
caused repeated chronology research/new search tabs. Stopped before any typing
or submission. Corrected compaction retains named observation facts and
structure (only unnamed generic wrappers/indentation removed), plus DOM labels
when no semantic outline exists. It retires action tokens, not historical
evidence. Replaying its 18 snapshots reduces their representation from roughly
515k to 105k characters (before additional retained indentation), preserving
all mutation results. Tests verify facts survive compaction.

### Reply posted and verified (2026-10-19)

Run 590 submitted the exact reply `it has been some time..` as @fastspeech2text
under original CUA post https://x.com/fastspeech2text/status/2080507946241560757.
Verified reply permalink: https://x.com/fastspeech2text/status/2112120739260498123.
Parent count increased 5 -> 6 after reload. Independent read-only driver queries
verified the result article author/text and permalink; no second submission.
Evidence: /tmp/cua-post-verification, /tmp/cua-reply-link, /tmp/cua-reply-confirmed.

Important limitation: app run 590 ended Failed (history limit) AFTER posting,
during verification. Never replay this posting task. Retiring old tab inventories
was missing: repeated binds retained full 35-40-tab lists. Final host compaction
now retires old bind inventories as well as action refs, keeping exact binding
metadata, observation facts, and every mutation/outcome. Replaying the 36 browser
observations reduces their representation from ~981k to ~158k characters
(before retained indentation and non-browser action ledger). Final build does
not auto-run the command.

Focus: run 588 opened X and switched account while cmux/Codex were foreground;
no Chrome activation during its task interval. Run 590 recorded zero foreground
changes, but Chrome was already foreground after explicit connection setup,
so its final submission is not an end-to-end test with another app in front.
No target tab activation was requested and the previously selected Claude tab
remained selected. Evidence: /tmp/cua-facts-live/focus-report.json.

Final source/runtime remain local on codex/cua-trycua-benchmark; no commit/push
performed. Native comparison branch unchanged. New-tab patch follows semantic
read patch. Unrelated existing experiments/ preserved.

Final validation: 28 ComputerUseBackgroundTests pass; 58 browser v2 regression tests pass (4 existing ignored). DevA rebuilt using shared caches; build script verified deep signature and complete LocalVQE. Relaunched with updated trycua driver and no replay arguments; Chrome access confirmed Connected, app idle.

### Model-aware history budget and incomplete outcomes (2026-10-19)

The comparison harness no longer stops at 240,000 characters or truncates each
observation at 60,000 characters. It estimates UTF-8 token cost for instructions,
upstream schemas and history, reserves screenshot and response capacity, and
compacts whole older observations before dispatching a planner request. The
estimator is approximate (shared with Meeting Chat), with 20% headroom. Hosted
capacities are an explicit Codex model-catalog snapshot verified on 2026-10-19;
unknown IDs use an 8K conservative fallback. Gemma capacity is sourced from its
inference adapter and shared with engine initialization. Large hosted models also
have a 128K operational input cap for latency/cost; this is not their context size.

Compaction retires obsolete references/tab inventories, compresses structural
wrappers, and references identical complete fact blocks at the same page/target
back to their earlier entry. It does not deduplicate individual labels across
containers or discard unique observations, mutation calls, uncertain outcomes,
or original instructions. When safe compaction cannot fit, the run stops before
another planner request. Provider-side rejection remains possible because token
counting is approximate.

A stopped run after a potentially mutating tool now has an amber `incomplete`
status across history, floating pill and notch, preserving the reason and warning
that earlier actions may have taken effect. This is deliberately not `done`: a
successfully delivered click does not prove that a reply was posted. Explicit
cancellation remains cancelled but retains the side-effect warning. Verified
completion remains done; pre-action failure remains failed. No submission is
replayed to test this behavior.

Optional read-only regression replay:
`MUESLI_REFERENCE_HISTORY_REPLAY_ROOT=<saved daemon directory> swift test ... --filter ComputerUseBackgroundTests`
reads saved call JSON and schemas only. It never connects to the driver or browser.

Validation: 63 focused background/local-planner tests passed, including a read-only
replay of 51 recorded tool calls from the previously exhausted run. Every replay
step fit; peak estimated history was 63,561 tokens within the 131,072-token total
input operating budget after schemas/instructions/image reservation. This is a
history reconstruction test, not another live posting run.

## Background reconnect reuse

Apply `trycua-05d1494-background-reconnect.patch` after the preceding patches.
With the manual reconnect environment enabled, background prepare can only
claim an existing approved socket. The pool checks and claims under its dial
lock; a missing, closed, or expired connection cannot trigger a new handshake,
consent UI, background guard, or focus restoration. Endpoint ownership, window,
and grant checks still apply. Missing sockets return browser_consent_required;
missing debugging still returns browser_requires_setup.

The Settings action first attempts this background path without activating an
already running Chrome. Only those specific setup/consent responses permit the
interactive path. Other refusals terminate without escalating to foreground.
