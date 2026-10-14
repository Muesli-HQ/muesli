# Strict-background reference setup patch

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
