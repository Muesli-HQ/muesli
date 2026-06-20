---
title: March 19, 2026 Audit Hardening Report
description: >
  Verified audit findings, shipped fixes, and validation notes for the
  March 19, 2026 Muesli hardening pass.
---

# March 19, 2026 Audit Hardening Report

This report covers the hardening work done after auditing the repository
hosted at `https://github.com/Muesli-HQ/muesli`.

The review focused on the parts of the app where a bug would matter most:
the SQLite query layer, live meeting transcription, system-audio startup,
and local secret storage.

## What was verified

### 1. Unsafe SQL construction in dictation date filters

`DictationStore.recentDictations()` built the optional date filters by
splicing raw strings into the SQL text. In the current app flow those
values come from internally formatted dates, so this was not treated as a
proven user-facing exploit. It was still an unsafe sink in the storage
API and worth fixing immediately.

Files:

- `native/MuesliNative/Sources/MuesliCore/DictationStore.swift`
- `native/MuesliNative/Tests/MuesliTests/DictationStoreTests.swift`

### 2. Meeting chunk tasks could finish after final transcript merge

`MeetingSession.rotateChunk()` launched background tasks that mutated shared
state later, while `stop()` merged the final transcript without waiting for
those tasks to complete. That creates a real risk of dropping completed mic
chunks or merging them out of order in longer meetings.

Files:

- `native/MuesliNative/Sources/MuesliNativeApp/MeetingSession.swift`
- `native/MuesliNative/Tests/MuesliTests/QoLTests.swift`

### 3. System audio startup could fail after success had already been reported

`SystemAudioRecorder.start()` created the output file and returned before the
`SCStream` startup work finished. If startup failed inside the async task,
the recorder flipped `isRecording` later but left the caller with a
false-success path and possible temp-file leakage.

File:

- `native/MuesliNative/Sources/MuesliNativeApp/SystemAudioRecorder.swift`

### 4. Documentation drift around ChatGPT token storage

The README said ChatGPT OAuth tokens were stored in Keychain. The code had
already migrated them into `chatgpt-auth.json` in the app support
directory and protected that file with `0600` permissions. That mismatch
needed to be corrected.

Files:

- `README.md`
- `native/MuesliNative/Sources/MuesliNativeApp/ChatGPTAuthManager.swift`

### 5. API key config file lacked explicit permission hardening

Provider API keys live in `AppConfig`, which is serialized to
`config.json`. The file was written atomically but without an explicit
owner-only permission pass. That is a local hardening gap, not a remote
attack, but it is the kind of detail that should be tightened in an app
handling API secrets.

Files:

- `native/MuesliNative/Sources/MuesliNativeApp/ConfigStore.swift`
- `native/MuesliNative/Tests/MuesliTests/ConfigStoreTests.swift`

## What changed

### Query safety

The dictation date filter now uses bound parameters instead of direct string
interpolation. That keeps the query behavior stable even if future call
sites pass raw strings.

### Meeting transcript collection

A small `MeetingChunkCollector` now tracks the background chunk tasks.
`stop()` drains those task results, waits for them to finish, and sorts the
segments before merging the final transcript.

### Recorder cleanup

`SystemAudioRecorder` now keeps its startup task explicit and cleans up the
output state if stream startup fails. `stop()` also finalizes based on the
real file state, not just the `isRecording` flag.

### Secret-storage hardening and docs

`ConfigStore.save()` now applies `0600` permissions to `config.json`, and
the README now describes ChatGPT token storage the way the code actually
works.

## Validation

What ran successfully in this environment:

- `swift build --package-path native/MuesliNative`

What did not run cleanly here:

- `swift test --package-path native/MuesliNative --filter ...`

The package test run failed before it reached the new regression tests
because the active machine setup only has Command Line Tools and not a full
Xcode developer directory, while the repository test target imports the
Swift `Testing` module. The failure happened in existing test files before
any of the new assertions could be exercised.

## Remaining risk

- The local-secret story is better than before, but it is still file-based.
  A future pass could move provider API keys into Keychain as well if the
  project wants a stronger default.
- The recorder fix closes the obvious false-success path. A fuller runtime
  test harness around `ScreenCaptureKit` would still be useful because that
  framework is difficult to cover in unit tests alone.

## References

- `docs/plans/2026-03-19-audit-hardening-execplan.md`
