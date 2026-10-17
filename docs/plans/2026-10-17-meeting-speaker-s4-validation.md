# S4 meeting-speaker Accessibility validation

This is the validation gate for the experimental S4 Accessibility evidence path. Synthetic fixtures pin the current selectors; they do not establish that a shipped app exposes the same Accessibility tree. The feature remains off by default until real Mac fixtures pass the exit criteria below.

## Goal and non-goals

S4 may add a participant name to a diarized system-audio speaker only when a supported meeting app exposes both a participant label and an explicit active-speaker marker, and the observation overlaps the speaker's audio interval. When layout, window scope, authorization, clock, or speaker match is uncertain, S4 withholds the name.

S4 does not infer activity from focus or selection, inspect pixels or screenshots, attribute mic-only audio, or enable itself by default. Manual speaker corrections remain authoritative.

The app-list snapshot is acquired for the duration of an authorized manual recording, even when meeting-detection notifications and auto-recording are disabled.

## Accessibility contracts to verify on Mac

The selectors below are hypotheses that synthetic fixtures pin until real fixtures verify them:

- Zoom (`us.zoom.xos`): a participant tile with the `zoom participant` description, one participant-name child, and a separate `speaking status` value.
- Teams (`com.microsoft.teams` or `com.microsoft.teams2`): a tile with the `teams participant` description, one participant-name child, and a separate `speaking status` value.
- Meet in Chrome, Edge, or Firefox: an HTTPS `meet.google.com` document URL with a nonempty meeting path, and a `video tile` with a participant name and separate speaking status.
- Slack (`com.tinyspeck.slackmacgap`): a tile with the `huddle participant` description, one participant-name child, and a separate `speaking status` value.

For each app build, record the macOS version, app version, and fixture case ID. Do not store participant names, contact details, transcript text, recordings, or screenshots in this repository or PR.

## Acceptance criteria

1. For each supported app, 10/10 positive fixture intervals map the explicit active participant to the overlapping diarized system-audio speaker.
2. Every roster-only, missing-marker, ambiguous, truncated, multiple-window, over-limit, permission-revoked, or overlapping-speaker fixture withholds attribution. The target is zero false assignments in these negative cases.
3. Across 20 labeled active-speaker intervals per app, at least 19 are correctly attributed. Report abstentions separately so precision is not hidden by coverage.
4. Compare Accessibility observation times with `MeetingChunkTimingTracker` and diarization segment times across chunk rotation, pause transitions, and resumed capture. A callback for samples already written to the full system recording must also enter the chunk and timing stream, including in-flight callbacks while the native recorder applies Pause or Stop. Every accepted vote must overlap its diarized interval; equal or stale clock samples may only discard their own pair.
5. Reopen pre-escape transcripts and verify structured speaker rows, citation turn navigation, search, previews, export, and model-facing text remain readable for labels containing colons or backslashes.
6. Revoke Accessibility permission during capture and verify no later observation is added, no assignment is applied, and final persistence removes prior Accessibility-derived names.

## Exit criteria

Keep the setting off until all four supported apps pass the positive and negative fixture criteria on Mac, timing checks pass across chunk rotation and resumed capture, and saved-transcript compatibility passes. Report abstentions alongside successful assignments. Removing the experimental status requires maintainer review of the fixture results and an explicit rollout decision.

## Transcript format dependency

Canonical speaker labels escape colons and backslashes so names remain separable from transcript speech. That format change and the S4 monitor remain in one stack commit because S4 writes these labels. Legacy rendering, digest matching, citations, search, previews, exports, and prompt normalization preserve existing transcripts and readable UI text.
