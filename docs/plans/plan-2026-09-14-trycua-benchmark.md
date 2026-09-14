# Local direct-trycua benchmark

## Branch ownership

- Native PR branch: `codex/cua-background-driver`.
- Local benchmark branch: `codex/cua-trycua-benchmark` (this branch).
- Common application baseline: `05eb305db67d4b39beabf70388dc790d4d6c5a12`, PR #515.
- Shared checkout: `/Users/pranavhari/.codex/worktrees/b617/muesli`.
- Upstream reference: `https://github.com/trycua/cua`, commit
  `39a206e637273385f39a41b3b8544e6d3ab5c099`.

This branch is explicitly authorized to use the real upstream runtime locally.
The native shipping branch remains Swift. Do not push this branch, open a PR
from it, or merge its dependency/packaging changes into the native branch.
It has no upstream and its branch-specific `pushRemote` is
`DISABLED-local-only`, an intentionally nonexistent remote. This prevents a
normal default push, not an explicit `git push origin ...` or `--all`; those
must also exclude this branch. Do not change repository-wide push behavior.

Commit work before switching branches. Build sequentially in this one checkout;
use separate branch-specific caches. Proposed installed lanes are DevA for
native and DevB for direct trycua, after checking existing lane ownership and
preserving app data. Only one driver should execute actions at a time.

## Why two comparisons

1. **Matched operations:** same fixture state, exact target, action and expected
   result through each driver. This isolates dispatch, window scoping, focus
   behavior, cancellation and verification from model/tool-schema differences.
2. **Model-driven tasks:** same GPT model, task, limits and initial state, with
   each implementation's own tools. Expose upstream schemas faithfully so
   Muesli's existing catalog does not hide upstream capabilities. Record prompt,
   schema and observation differences; do not attribute all performance gains
   to the driver when those also differ.

Capture the upstream tool catalog/schema from the pinned built driver. For each
tool, map arguments, process/window/element targeting, preconditions, delivery
route, observation scope, effect verification, cancellation, fallback behavior,
and structured failures. Record unsupported or unmapped tools explicitly.

## Integration work

The old `codex/cua-trycua-embedded-spike` branch at `71e0411b` preserves
`ComputerUseEmbeddedDriverHost.swift` and optional binary packaging. It launches
a driver child and writes an endpoint; the inspected host is not itself a
planner-to-driver tool adapter. Reuse only parts compatible with the pinned
upstream executable, socket protocol, permissions and lifecycle.

1. Build or obtain the pinned upstream driver with recorded provenance; capture
   its version, supported launch arguments and actual tool schemas. Do not
   assume historical embedded flags still exist.
2. Connect observation and action calls to the real driver. Make the selected
   backend explicit in traces; fail when the reference driver is unavailable
   instead of silently falling back to Muesli's native executor.
3. Tie process/socket lifetime, cancellation and errors to the Muesli run. Test
   driver exit, stale endpoints and Stop. Verify the actual permission identity
   experimentally rather than assuming child-process TCC attribution.
4. Keep upstream behavior unchanged initially. Log any necessary adapter or
   upstream modifications so this remains an interpretable reference.
5. Build the reference lane with the complete LocalVQE runtime and verify the
   installed bundle/signature under the normal dev-lane workflow.

## Comparison fixtures and evidence

Start with a local two-window AppKit fixture and browser test pages, then run
the known-post X task and the discovery variant. Drafts/local fixtures precede
any live posting; do not publish benchmark replies without authorization.

For both backends record build/upstream SHAs, OS/app versions, model settings,
tool schemas, cold/warm AX state, target identity, chosen route, latency, tool
count, observed effect, failures, cursor movement, frontmost transitions and
whether the sibling window was changed. A restored focus steal still counts
as a focus steal. Avoid recording unrelated user screen/text contents.

Cover two windows in one process, background text and multiline replacement,
pointer/scroll operations, manual user app switches/typing, Stop mid-action,
closed targets, stale elements, unavailable AX, hidden/minimized/other-Space
targets, and missing routing capabilities. Separate unavailable capabilities
from failures of supported operations.

Keep a results matrix with native result, reference result, evidence, likely
cause and the smallest Swift change worth porting. Use failures in both drivers
to identify platform limitations; never treat source similarity as parity.

## Current status

Branch and comparison contract established. Direct-driver wiring, builds,
schema capture and live benchmark runs are pending. No benchmark result or
runtime parity is claimed by this setup commit.
