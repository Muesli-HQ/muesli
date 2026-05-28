# Sales Caddie Polish Release Checklist

Use this checklist before handing Sales Caddie to a rep who will not run it from Terminal.

## Product Readiness

- The sidebar should read as a sales workspace: Meetings, Jessica, Sales Assist, Workspace, then lower-level tools.
- Sales Assist Overview should show the setup checklist, shortcut health, cloud sync status, and test controls.
- Settings > General should show clear permission states with Fix and Recheck controls.
- Sales Assist > Library should be searchable and filterable, with objections separated from live cue cards.
- Meeting detail pages should show Sales Intelligence above the transcript/notes for completed calls.
- Settings > Sales should show whether the app is local-only, direct Supabase, or hosted API.

## Local Internal Build

Run:

```sh
./scripts/package_sales_caddie_dev.sh
```

This creates a local app bundle and DMG under `dist-native/`. It is intended for internal testing, not customer distribution.

## Customer Distribution

For a real external build, use the existing signed and notarized release flow:

```sh
./scripts/release.sh <version>
```

That flow should produce the signed DMG, notarize it, upload it to GitHub Releases, and update the Sparkle appcast. Do not ship a build that still requires users to clone the repo, open Xcode, or run Terminal commands.

## Final Smoke Test

- Fresh install opens without Terminal.
- Google Calendar onboarding starts before Apple Calendar setup.
- Workspace invite code fills the user identity.
- Microphone, Input Monitoring, Accessibility, and Screen Recording all show accurate status after Recheck.
- Jessica hotkey returns a response card and preserves follow-up context.
- Computer Use hotkey remains separate from Jessica.
- Meeting recording creates a transcript, post-call intelligence, and synced cloud payload when sync is enabled.
- Sales Assist overlay can replay objection, buying signal, and battlecard cards.
