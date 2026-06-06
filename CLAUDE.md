> **Post-compaction recovery:** PreCompact hooks auto-generate context handover files at `Context/handoff-summary-YYYY-MM-DD-<slug>.md`. After compaction, read the latest handoff file in `Context/` to restore session memory and resume work.

# Muesli

Local-first macOS app for **dictation** and **meeting transcription** on Apple Silicon. All speech-to-text runs on-device via CoreML/Neural Engine. Native Swift/AppKit — no Electron, no Python runtime, no cloud STT costs.

**Status:** Live and public. Available at [GitHub Releases](https://github.com/Muesli-HQ/muesli/releases). Signed, notarized, stapled.

## What It Does

- **Dictation:** Hold hotkey → speak → release → text pasted at cursor (~0.13s with Parakeet)
- **Meeting transcription:** Captures mic (You) + system audio (Others) → VAD-driven chunking → speaker diarization → AI-powered meeting notes
- **Meeting export:** Export notes or transcript as PDF (paginated US Letter) or Markdown via `MeetingExporter.swift`
- **Screen context:** Accessibility API captures app name + text around cursor for dictation context-awareness (opt-in, off by default)
- **7 ASR models:** Parakeet v3/v2, Whisper Small/Medium/Large Turbo, Qwen3 ASR, Nemotron Streaming
- **3 summarization backends:** OpenAI API key, OpenRouter API key, ChatGPT OAuth (subscription-based)
- **Camera-based meeting detection:** Requires mic + camera + recognized meeting app (camera alone won't trigger)
- **Join & Record:** Extract meeting URLs from calendar events (Zoom, Meet, Teams, Webex, Chime, FaceTime), split button with "Join & Record" / "Join Only" / "Record Only", platform icons in notifications
- **Google Calendar integration:** Coming Up section, status bar, pre-meeting countdowns, event-driven notifications via `EKEventStoreChangedNotification`
- **Meeting templates:** Built-in and custom templates for structured meeting notes

## Building

### Production build (signed, installed to /Applications)
```bash
./scripts/build_native_app.sh
```

### Dev/test build (isolated, unsigned)
```bash
./scripts/dev-test.sh                  # Build MuesliDev.app (separate bundle ID, separate data)
./scripts/dev-test.sh --clean          # Wipe dev data, fresh onboarding
./scripts/dev-test.sh --reset          # Re-run onboarding, keep dev data
./scripts/dev-seed-from-prod.sh        # Copy production DB/config into MuesliDev safely
./scripts/dev-reset-permissions.sh     # Reset macOS privacy permissions for MuesliDev
```

MuesliDev uses bundle ID `com.muesli.dev` and stores data at `~/Library/Application Support/MuesliDev/`. Production data is never touched.

### SwiftPM build artifacts in worktrees
SwiftPM can write build artifacts to `native/MuesliNative/.build` inside the active worktree. That can consume several GB per worktree. Local scripts now resolve a shared SwiftPM scratch path through `scripts/muesli_spm_cache.sh`:

- Explicit `MUESLI_SWIFTPM_SCRATCH_PATH` wins.
- `MUESLI_SWIFTPM_SCRATCH_CHANNEL` overrides the channel segment under the resolved cache root.
- `MUESLI_EXTERNAL_SPM_CACHE_ROOT` overrides the default `/Volumes/MuesliBuildCache/muesli-spm` external cache root.
- If `/Volumes/MuesliBuildCache/muesli-spm` is mounted, scripts use that external APFS cache.
- Otherwise scripts fall back to `~/Library/Caches/muesli-spm`.
- `MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1` intentionally opts out and uses SwiftPM's package-local `.build`; this takes precedence over all scratch path settings.

The preferred local cache is an APFS sparse bundle stored on the external SSD at `/Volumes/eSSD/MuesliBuildCache.sparsebundle`. Mount it before build-heavy local work:

```bash
hdiutil attach /Volumes/eSSD/MuesliBuildCache.sparsebundle
```

That sparse-bundle path is the maintainer's local SSD path. Contributors can substitute their own volume path or skip the attach step; scripts fall back to `~/Library/Caches/muesli-spm` when the external cache is not mounted.

Default script channels:

```bash
./scripts/dev-test.sh                 # /Volumes/MuesliBuildCache/muesli-spm/worktrees/<worktree>/dev when mounted
./scripts/build_native_app.sh release # /Volumes/MuesliBuildCache/muesli-spm/release when mounted
./scripts/release-preprod.sh          # /Volumes/MuesliBuildCache/muesli-spm/preprod when mounted
./scripts/release-alpha.sh            # /Volumes/MuesliBuildCache/muesli-spm/alpha when mounted
```

For parallel PR/worktree work, use isolated paths:

```bash
MUESLI_SWIFTPM_SCRATCH_PATH="/Volumes/MuesliBuildCache/muesli-spm/worktrees/pr182/dev" ./scripts/dev-test.sh
swift test --package-path native/MuesliNative --scratch-path "/Volumes/MuesliBuildCache/muesli-spm/worktrees/pr182/test"
```

The build script passes the resolved path to SwiftPM as `--scratch-path`, so multiple worktrees do not each grow their own `.build`. Caveat: do not run concurrent builds from different worktrees into the same scratch path; use separate paths per channel, agent, or simultaneous build. Deleting a scratch path only removes rebuildable SwiftPM artifacts, not installed apps or app data. Set `MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1` only when you intentionally want package-local `.build`.

### Tests
```bash
swift test --package-path native/MuesliNative    # 396 tests across 65 suites
```

### Onboarding testing
```bash
# Reset onboarding flag without losing data:
python3 -c "import json; p='$HOME/Library/Application Support/MuesliDev/config.json'; c=json.load(open(p)); c['has_completed_onboarding']=False; json.dump(c,open(p,'w'),indent=2)"
# Reset macOS permissions:
./scripts/dev-reset-permissions.sh
# Then:
./scripts/dev-test.sh
```
Note: config JSON uses snake_case keys (`has_completed_onboarding`, not `hasCompletedOnboarding`).

## CI/CD Pipeline

### Pull Requests
- **CI workflow** (`.github/workflows/ci.yml`): macOS 15 runners
  - `changes` → `build` → `cli-smoke` → `ci-gate` (required check)
- **Claude Code Review** — reviews every PR automatically
- **Greptile** — reviews every PR automatically
- **Vercel** — scoped to `site/` only
- **Concurrency** — stale CI runs auto-cancelled on new pushes

### Releases
```bash
./scripts/release.sh                   # Auto-increments version
./scripts/release.sh 1.0.0             # Explicit version
```
**Critical:** Staple the app bundle BEFORE creating the DMG, otherwise Gatekeeper rejects.

### Signing & Notarization
- Developer ID: `Pranav Hari Guruvayurappan (58W55QJ567)`
- Bundle ID: `com.muesli.app`
- Notary profile: `MuesliNotary` (Keychain)

## Key Architecture

```
native/MuesliNative/Sources/
├── MuesliNativeApp/              # Main app (~50 Swift files)
│   ├── MuesliController.swift    # Central orchestrator — dictation, meetings, onboarding, state
│   ├── TranscriptionRuntime.swift # Routes to ASR backends, post-processing, VAD + diarization
│   ├── FluidAudioBackend.swift   # Parakeet TDT on ANE
│   ├── Qwen3AsrBackend.swift     # Qwen3 ASR on ANE (macOS 15+)
│   ├── Qwen3PostProcessor.swift  # On-device GGUF LLM for dictation cleanup (opt-in)
│   ├── WhisperKitBackend.swift   # Whisper on CoreML/ANE via WhisperKit
│   ├── ScreenContextCapture.swift # AX-based app context for dictation + meetings
│   ├── MeetingExporter.swift     # PDF/Markdown export with NSPrintOperation
│   ├── OnboardingView.swift      # 7-step onboarding with real permission polling + dictation test
│   ├── OnboardingProgress.swift  # Crash-safe onboarding state persistence
│   ├── MeetingSession.swift      # Meeting lifecycle + diarization + screen context
│   ├── MeetingSummaryClient.swift # OpenAI / OpenRouter / ChatGPT summarization
│   ├── SystemAudioRecorder.swift # ScreenCaptureKit SCStream for system audio
│   ├── ChatGPTAuthManager.swift  # OAuth PKCE + WHAM API
│   ├── HotkeyMonitor.swift       # Global hotkey detection (modifier keys)
│   ├── MeetingDetector.swift     # Camera + mic + app detection for meetings
│   ├── MeetingNotificationController.swift # Join & Record notification panel with platform icons
│   └── PasteController.swift     # Clipboard-preserving Cmd+V paste
├── MuesliCore/                   # Shared library (SQLite, paths, models)
│   ├── DictationStore.swift      # SQLite3 C API — dictations + meetings CRUD
│   └── MuesliPaths.swift         # App-identity-aware path resolution
└── MuesliCLI/                    # Agent-friendly CLI (JSON over stdout)
```

## Data Storage

- **Config:** `~/Library/Application Support/{AppName}/config.json` (snake_case keys)
- **Database:** `~/Library/Application Support/{AppName}/muesli.db` (SQLite WAL)
- **Models:** `~/Library/Application Support/FluidAudio/Models/` (shared across app identities)
- **Onboarding progress:** `~/Library/Application Support/{AppName}/onboarding-progress.json` (deleted on completion)
- **ChatGPT tokens:** macOS Keychain (`com.muesli.app.chatgpt-auth`)
- **Whisper models:** `~/.cache/muesli/models/`

`{AppName}` is `Muesli` for production, `MuesliDev` for dev, `MuesliCanary` for alpha — controlled by `MuesliSupportDirectoryName` in Info.plist.

## macOS Permissions

| Permission | What Uses It | API |
|---|---|---|
| Microphone | Dictation + meeting mic | AVAudioRecorder, AVAudioEngine |
| Accessibility | Paste text + screen context capture | CGEvent Cmd+V, AXUIElement |
| Input Monitoring | Hotkey detection | NSEvent global monitors |
| Screen Recording | System audio capture | ScreenCaptureKit SCStream |
| Camera (implicit) | Meeting detection | CoreMediaIO property listeners |
| Calendar (optional) | Upcoming meetings | EKEventStore, Google Calendar API |

**Critical:** Accessibility permission requires an app restart to take effect. The onboarding flow handles this with an automatic restart after the hotkey configuration step.

**Important:** `CGWindowListCreateImage` (screenshots) conflicts with active `SCStream` sessions — causes `RPDaemonProxy: connection INTERRUPTED` and breaks system audio capture. Never take screenshots during meeting recording. See `Context/handoff-2026-04-16-coreaudio-tap-migration.md` for the planned fix.

## Onboarding Flow

7 steps: Welcome → Model → Permissions → Hotkey → **[app restart]** → Dictation Test → Meeting Summaries → Google Calendar

Key implementation details:
- Real OS permission polling every 1s (not fake timers) via `AXIsProcessTrusted()`, `CGPreflightListenEventAccess()`, etc.
- Uses proper request APIs: `AXIsProcessTrustedWithOptions`, `CGRequestScreenCaptureAccess`, `CGRequestListenEventAccess`
- Hotkey, calendar, and mic monitors are **deferred until after onboarding completes** to prevent premature permission prompts
- App restart via detached shell: `/bin/sh -c "sleep 1; open -- \"$1\"" -- <bundlePath>` then `NSApp.terminate(nil)`
- Progress saved on every step transition to `onboarding-progress.json` (schema-versioned, atomic writes)
- Dictation test step uses real hold-to-talk hotkey flow with `dictationTestCallback` routing (no paste, no floating indicator)
- `OnboardingView.dictationTestStep` (static Int = 4) — hotkey monitor only starts when resuming at this step or later

## Screen Context (opt-in, `enableScreenContext` in config)

**Dictation:** `DictationContextCapture.capture()` — synchronous Accessibility API call:
- App name + bundle ID via `NSWorkspace.shared.frontmostApplication`
- Text before cursor via `kAXSelectedTextRangeAttribute` + `kAXStringForRangeParameterizedAttribute` (falls back to `kAXValueAttribute` suffix for apps that don't support parameterized attributes)
- Selected text via `kAXSelectedTextAttribute`
- Browser URL via `kAXDocumentAttribute`
- Only runs when BOTH `enableScreenContext` AND `enablePostProcessor` are true
- Context injected into Qwen3 post-processor prompt as `<APP-CONTEXT>` tags
- Stored in existing `app_context` column in `dictations` table

**Meetings:** `MeetingScreenContextCollector` (actor) — periodic AX capture every 60s:
- Uses same `DictationContextCapture.capture()` (no screenshots — `CGWindowListCreateImage` conflicts with `SCStream`)
- Deduplicated, aggregated, injected into meeting summary prompt as "Visual context" section
- OCR-based capture (`ScreenContextCapture.captureOnce()`) exists in code but is unused until CoreAudio migration

## Meeting Export

`MeetingExporter.swift` — export menu in `MeetingDetailView` content toolbar:
- Two menu items: "Export Notes"/"Export Transcript" (contextual to active tab) + "Export Full Meeting"
- Format (PDF/Markdown) chosen via `ExportFormatAccessory` popup in NSSavePanel
- PDF: `NSPrintOperation` with paginated US Letter pages (612x792pt, 1" margins)
- Markdown: atomic write with metadata header (title, date, duration, word count, template)
- NSSavePanel presented via `beginSheetModal(for:)` — never `runModal()` (deadlocks in SwiftUI)
- File auto-opens in default app after save via `NSWorkspace.shared.open(url)`

## Development Workflow

1. **Feature work:** Create branch → implement → `./scripts/dev-test.sh` → push → PR
2. **PR review:** Claude Code + Greptile review automatically. Fix P1s before merge.
3. **Merge to main** via squash merge
4. **Release:** `./scripts/release.sh` → notarize → GitHub Releases

## Calendar Notification Pipeline

Event-driven architecture for meeting notifications:

- **Primary trigger:** `EKEventStoreChangedNotification` — macOS pushes calendar changes (add/move/delete) instantly via `NotificationCenter`. Immune to App Nap timer suspension in LSUIElement apps.
- **Fallback:** 60s `Timer` polls Google Calendar API (sync token for efficiency) and checks the 5-minute notification window for time-based triggers.
- **Dedup:** Composite key `id|startDate` — rescheduled events generate fresh notifications. Stale entries pruned hourly.
- **Per-event timers:** `meetingStartingNowTimers: [String: Timer]` — concurrent events get independent "starting now" timers.
- **Suppression:** After user acts on a calendar notification (Join Only, Dismiss), mic/camera detection is suppressed for the remaining event duration.
- **Meeting URL extraction:** EventKit (`event.url`, `location`, `notes` via regex) + Google Calendar API (`hangoutLink`, `conferenceData.entryPoints[type=video]`). `mergeEvents` backfills Google URL when EventKit duplicate has none.

**macOS 26 App Nap behavior (LSUIElement apps):** All timer mechanisms (`Timer.scheduledTimer`, `DispatchSourceTimer`, `Task.sleep`, `Thread.sleep`, `DispatchQueue.asyncAfter`, POSIX `nanosleep`) get suspended by aggressive power management. Only `NotificationCenter` observers (system IPC) are immune. The 60s fallback timer may not fire reliably — `EKEventStoreChangedNotification` is the critical path. Users with Google Calendar synced to macOS Calendar (System Settings > Internet Accounts) get reliable notifications via EventKit. OAuth-only users depend on the 60s timer.

## Known Limitations

- **Nemotron Streaming:** English-only, best for 10s+ utterances (handsfree mode). Short dictations produce poor results.
- **Qwen3 ASR:** 2-3s latency (autoregressive decoder). First run after launch has ~30s CoreML compilation warmup.
- **ChatGPT OAuth:** Uses reverse-engineered WHAM API. Could break if OpenAI changes the API.
- **Speaker diarization:** Post-processing only. Runs after meeting stops.
- **Screen context OCR disabled during meetings:** `CGWindowListCreateImage` conflicts with `SCStream`. AX-based context used instead. Planned fix: migrate to CoreAudio tap for system audio (see `Context/handoff-2026-04-16-coreaudio-tap-migration.md`).
- **NSSavePanel:** Must use `beginSheetModal(for:)` in SwiftUI, never `runModal()`. `NSAttributedString(html:)` deadlocks on main thread — build attributed strings manually.
- **App restart during onboarding:** Uses `exit(0)` via detached shell. `NSApp.terminate(nil)` inside SwiftUI animation context can crash.
- **macOS 26 App Nap:** LSUIElement apps have all timers suspended by aggressive power management. Calendar notifications rely on `EKEventStoreChangedNotification` (immune). The 60s Google Calendar poll timer may not fire. See Calendar Notification Pipeline section.
- **"Meeting starting now" after Join Only/Dismiss:** The scheduled timer is not cancelled when the user clicks Join Only or Dismiss on the "Upcoming meeting" notification. A redundant "Meeting starting now" fires at event start time. Fix: pass notification key into `handleUpcomingMeeting` so callbacks can cancel it.

## Upcoming Work

1. **Cancel "starting now" timer on Join Only/Dismiss** — Pass notification key into `handleUpcomingMeeting` so `onJoinOnly`/`onDismiss` callbacks can cancel `meetingStartingNowTimers[key]`.
2. **CoreAudio tap migration** — Replace ScreenCaptureKit with CoreAudio aggregate device for system audio. Unblocks OCR during meetings + friendlier "System Audio" permission (not "Screen Recording"). See `Context/handoff-2026-04-16-coreaudio-tap-migration.md`.
3. **Google OAuth verification** — Pending Google approval (~4 weeks from April 12). Once approved, embed credentials with `verified: true`.
4. **Post-processor fine-tune** — Collect `postproc-pairs.jsonl` from canary testers, train v3 model for better implicit list formatting.
