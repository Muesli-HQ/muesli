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
