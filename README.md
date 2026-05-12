<p align="center">
  <img src="assets/muesli_app_icon.png" alt="Muesli" width="128" height="128" />
</p>

<h1 align="center">Muesli</h1>

<p align="center">
  <strong>Local-first dictation & meeting transcription for macOS</strong><br>
  100% on-device speech-to-text · Zero cloud costs · Privacy by default
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License" /></a>
  <a href="https://buymeacoffee.com/phequals7"><img src="https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?logo=buymeacoffee&logoColor=white" alt="Buy Me A Coffee" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014.2%2B-lightgrey?logo=apple" alt="macOS 14.2+" />
  <img src="https://img.shields.io/badge/Apple%20Silicon-optimized-green" alt="Apple Silicon" />
</p>

---

## What is Muesli?

Muesli is a **lightweight native macOS app** that combines **WisprFlow-style dictation** and **Granola-style meeting transcription** in one tool. All transcription runs locally on Apple Silicon — your audio never leaves your device unless you choose a cloud-backed meeting summary provider.

<p align="center">
  <img src="assets/muesli-github-ss.png" alt="Muesli interface showing dictations and meeting history" width="900" />
</p>

### Dictation
Hold your hotkey (or double-tap for hands-free mode) → speak → release → transcribed text is pasted at your cursor. **~0.13 second latency** via Parakeet TDT on the Apple Neural Engine.

### Meeting Transcription
Start a meeting recording → Muesli captures your mic (You) and system audio (Others) simultaneously → VAD-driven chunked transcription happens during the meeting at natural speech boundaries → speaker diarization identifies individual remote speakers (Speaker 1, Speaker 2, etc.) → when you stop, the transcript is ready in seconds, not minutes. Generate structured meeting notes via OpenAI, free OpenRouter models, your ChatGPT Plus/Pro subscription, or local Ollama models.

---

## Features

- **Native Swift, zero Python** — Pure Swift app with CoreML and Metal backends. No bundled runtimes, no subprocess IPC.
- **Multiple ASR models** — Parakeet TDT (Neural Engine), Cohere Transcribe 2B (mixed precision CoreML), Whisper Small/Medium/Large Turbo (CoreML/ANE via WhisperKit), and Qwen3 ASR (52 languages, CoreML).
- **Hold-to-talk & hands-free** — Hold hotkey for quick dictation, or double-tap for sustained recording.
- **Meeting recording** — Captures mic + system audio (including Bluetooth/AirPods) with a CoreAudio process tap by default and ScreenCaptureKit fallback. System audio from Zoom, Teams, and other call clients stays on the Others side of the transcript.
- **VAD-driven chunk rotation** — Silero VAD detects natural speech boundaries in real-time, splitting mic audio at pauses instead of fixed intervals. No mid-sentence cuts.
- **Speaker diarization** — Identifies individual speakers in system audio (Speaker 1, Speaker 2, etc.) using FluidAudio's pyannote-based CoreML diarization model.
- **Camera-based meeting detection** — Detects when your webcam + mic activate in a recognized meeting app (Zoom, Chrome, Teams, FaceTime, Slack, WhatsApp). Camera alone (e.g. Photo Booth) won't trigger false positives.
- **Join & Record** — Extracts meeting URLs from calendar events (Zoom, Google Meet, Teams, Webex, Chime, FaceTime). Split-button notification: "Join & Record" opens the meeting + starts recording, "Join Only" opens without recording, "Record Only" starts recording without joining. Platform icons (Zoom, Meet) in the notification panel.
- **Google Calendar integration** — Connect your Google Calendar to see upcoming meetings in the Coming Up section and status bar. Event-driven notifications via `EKEventStoreChangedNotification` for instant calendar change detection. Pre-meeting countdowns via Marauder's Map easter egg.
- **Meeting export** — Export meeting notes or transcripts as PDF (paginated US Letter) or Markdown. Format picker in the save panel, auto-opens the exported file.
- **Meeting templates** — Built-in and custom templates for meeting notes. Choose a template before or after recording — re-summarize any meeting with a different template.
- **Dismiss calendar events** — Hide irrelevant events from Coming Up, status bar, and menu bar. Dismissed events are pruned automatically.
- **Filler word removal** — Automatically strips "uh", "um", "er", "hmm" and verbal disfluencies.
- **AI meeting notes** — BYOK with OpenAI or OpenRouter, sign in with your ChatGPT Plus/Pro subscription (no API key needed), or use local Ollama models. Auto-generated meeting titles. Re-summarize any meeting.
- **ChatGPT OAuth** — Sign in with your existing ChatGPT subscription via browser-based OAuth (PKCE). Tokens stored in the app support directory with owner-only file permissions.
- **Personal dictionary** — Add custom words, phrase matches, and replacement pairs. Jaro-Winkler fuzzy matching auto-corrects transcription output.
- **Model management** — Download, delete, and switch between models from the Models tab. Background downloads that don't block the app.
- **Configurable hotkeys** — Choose any modifier key (Cmd, Option, Ctrl, Fn, Shift) for dictation.
- **Onboarding** — First-launch wizard with model selection, real OS permission verification, hotkey configuration, smoother Accessibility handoff, live dictation test to verify the full pipeline works, and optional summary setup for ChatGPT, OpenAI, OpenRouter, or Ollama. Progress saved on every step — survives crashes and manual quits.
- **Launch at Login** — Start Muesli automatically with macOS login items, with approval-state refresh in Settings.
- **Dark & light mode** — Adaptive theme with toggle in sidebar.
- **SwiftUI dashboard** — Dictation history, meeting notes (Notes-style split view), meeting folders, dictionary, models, shortcuts, settings, about page.
- **Floating indicator** — Frosted glass pill with dynamic waveform, accent color customization, and click-to-stop for meetings.

---

## Install

### Download (recommended)

Download the latest `.dmg` from [Releases](https://github.com/pHequals7/muesli/releases), open it, and drag Muesli to Applications — or double-click to install automatically.

### Homebrew

```bash
brew tap pHequals7/muesli
brew install --cask muesli
```

### Build from source

**Requirements:** macOS 14.2+, Xcode 16+

```bash
# Clone
git clone https://github.com/pHequals7/muesli.git
cd muesli

# Build and install to /Applications
./scripts/build_native_app.sh

# Contributor dev build without the maintainer Developer ID certificate
MUESLI_SKIP_SIGN=1 ./scripts/dev-test.sh
```

Release builds are signed by the maintainer Developer ID certificate. External
contributors can use the unsigned dev build for local testing; it installs
`MuesliDev.app` with a separate bundle ID and app data directory.
See [CONTRIBUTING.md](CONTRIBUTING.md) for the full local development workflow.

The transcription model (~450MB for Parakeet v3) downloads automatically on first use.

---

## Agent CLI

Muesli bundles an agent-friendly local CLI inside the app bundle:

- Installed path: `/Applications/Muesli.app/Contents/MacOS/muesli-cli`
- Dev path: `native/MuesliNative/.build/arm64-apple-macosx/debug/muesli-cli`

The CLI is designed for coding agents such as Codex and Claude Code. It exposes meetings, dictations, raw transcripts, and stored notes as stable JSON so an agent can analyze them with its own model and write notes back without requiring a user-supplied OpenAI or OpenRouter key.

### What agents should do

1. Discover the CLI:
   ```bash
   command -v muesli-cli || echo "/Applications/Muesli.app/Contents/MacOS/muesli-cli"
   ```
2. Inspect the command contract:
   ```bash
   /Applications/Muesli.app/Contents/MacOS/muesli-cli spec
   ```
3. List recent meetings or dictations:
   ```bash
   /Applications/Muesli.app/Contents/MacOS/muesli-cli meetings list --limit 10
   /Applications/Muesli.app/Contents/MacOS/muesli-cli dictations list --limit 10
   ```
4. Fetch a full record:
   ```bash
   /Applications/Muesli.app/Contents/MacOS/muesli-cli meetings get 125
   /Applications/Muesli.app/Contents/MacOS/muesli-cli dictations get 42
   ```
5. Summarize or analyze locally in the agent.
6. Write improved meeting notes back:
   ```bash
   cat notes.md | /Applications/Muesli.app/Contents/MacOS/muesli-cli meetings update-notes 125 --stdin
   ```

### Commands

- `muesli-cli spec`
- `muesli-cli info`
- `muesli-cli meetings list [--limit N] [--folder-id ID]`
- `muesli-cli meetings get <id>`
- `muesli-cli meetings update-notes <id> (--stdin | --file <path>)`
- `muesli-cli dictations list [--limit N]`
- `muesli-cli dictations get <id>`

### JSON contract

All CLI commands return JSON on stdout.

Success shape:

```json
{
  "ok": true,
  "command": "muesli-cli meetings get",
  "data": {},
  "meta": {
    "schemaVersion": 1,
    "generatedAt": "2026-03-17T00:00:00Z",
    "dbPath": "/Users/example/Library/Application Support/Muesli/muesli.db",
    "warnings": []
  }
}
```

Failure shape:

```json
{
  "ok": false,
  "command": "muesli-cli meetings get 999",
  "error": {
    "code": "not_found",
    "message": "No meeting exists with id 999.",
    "fix": "Run `muesli-cli meetings list` to find a valid ID."
  },
  "meta": {
    "schemaVersion": 1,
    "generatedAt": "2026-03-17T00:00:00Z",
    "dbPath": "",
    "warnings": []
  }
}
```

Important meeting fields:

- `rawTranscript`
- `formattedNotes`
- `notesState`
- `calendarEventID`
- `micAudioPath`
- `systemAudioPath`

`notesState` values:

- `missing`
- `raw_transcript_fallback`
- `structured_notes`

### Notes for agent authors

- The CLI is JSON-first and intended to be machine-consumed.
- `formattedNotes` is the only write-back surface in v1.
- `rawTranscript` is read-only and should be treated as source material.
- If `notesState` is `missing` or `raw_transcript_fallback`, agents should prefer summarizing from `rawTranscript`.
- Use `--db-path` or `--support-dir` only when the default Muesli data location is wrong.

---

## Models

| Model | Backend | Runtime | Size | Languages | Latency |
|-------|---------|---------|------|-----------|---------|
| **Parakeet v3** (recommended) | FluidAudio | CoreML / Neural Engine | ~450 MB | 25 languages | ~0.13s |
| Parakeet v2 | FluidAudio | CoreML / Neural Engine | ~450 MB | English only | ~0.13s |
| **Cohere Transcribe 2B** | CoreML | FP16 encoder + INT8 decoder | ~3.8 GB | English | ~1s |
| Qwen3 ASR | FluidAudio | CoreML / Neural Engine | ~1.3 GB | 52 languages | ~2-3s |
| Whisper Small | WhisperKit | CoreML / Neural Engine | ~190 MB | English only | ~1-2s |
| Whisper Medium | WhisperKit | CoreML / Neural Engine | ~1.5 GB | English only | ~2-3s |
| Whisper Large Turbo | WhisperKit | CoreML / Neural Engine | ~600 MB | Multilingual | ~2-4s |

Cohere Transcribe is a 2B parameter model (#1 on Open ASR Leaderboard) running in mixed precision — FP16 FastConformer encoder on the Neural Engine with INT8 quantized decoders. Includes VAD-gated silence detection to prevent hallucination. Best for high-accuracy English dictation.

Models download on demand from HuggingFace. Manage them from the **Models** tab in the dashboard.

---

## Permissions

Muesli needs these macOS permissions (guided during onboarding):

| Permission | Why |
|---|---|
| **Microphone** | Record audio for dictation and meetings |
| **System Audio Recording** | Capture call audio from Zoom/Meet/Teams |
| **Accessibility** | Simulate Cmd+V to paste transcribed text |
| **Input Monitoring** | Detect hotkey presses globally |
| **Camera** *(implicit)* | Detect webcam activation for meeting detection |
| **Calendar** *(optional)* | Show upcoming meetings from Google Calendar |

---

## Tech Stack

| Component | Technology |
|---|---|
| App | Swift, AppKit, SwiftUI |
| Primary ASR | [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet TDT + Qwen3 ASR on CoreML/ANE) |
| Cohere ASR | [Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) (FP16 encoder + INT8 decoder on CoreML) |
| Whisper ASR | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML/ANE) |
| Voice activity | Silero VAD via FluidAudio (streaming, event-driven) |
| Speaker diarization | pyannote via FluidAudio (CoreML on ANE) |
| Camera detection | CoreMediaIO property listeners (event-driven) |
| System audio | CoreAudio process tap by default; ScreenCaptureKit (`SCStream`) fallback |
| Meeting notes | OpenAI / OpenRouter (BYOK), ChatGPT subscription (OAuth), or Ollama |
| Calendar | Google Calendar API (OAuth 2.0) |
| Export | PDF (NSPrintOperation, paginated US Letter) + Markdown |
| Word correction | Jaro-Winkler similarity (native Swift) |
| Storage | SQLite (WAL mode) |
| Signing | Developer ID + hardened runtime (notarization ready) |

---

## Contributing

Contributions welcome! To get started:

```bash
git clone https://github.com/pHequals7/muesli.git
cd muesli
swift build --package-path native/MuesliNative -c release
swift test --package-path native/MuesliNative
./scripts/test_packaged_cli.sh
```

684 tests covering model configuration, custom word and phrase matching, filler removal, transcription routing, data persistence, CLI contract/path-resolution logic, speaker diarization alignment, token consolidation, camera-based meeting detection, CoreAudio system capture, ChatGPT OAuth logic, Ollama summaries, update-flow policy, launch at login, paste/clipboard safety, meeting export, meeting navigation, and Google Calendar URL extraction.

Current test scope:

- Covered by tests: CLI command contract generation, CLI path-resolution logic, SQLite read/write behavior, note-state classification, meeting/dictation retrieval/update flows, update-flow policy, CoreAudio cleanup, paste/clipboard safety, launch at login, Ollama summary routing, and Computer Use planner foundations.
- Not covered by Swift unit tests: app-bundle packaging and copying `muesli-cli` into `/Applications/Muesli.app/Contents/MacOS`.
- Packaging is verified by `scripts/test_packaged_cli.sh`, which builds an isolated app bundle, checks that `Contents/MacOS/muesli-cli` exists and is executable, and runs `muesli-cli spec` from the packaged path.

Please open an issue before submitting large PRs.

---

## Support

If Muesli saves you time, consider supporting development:

<a href="https://buymeacoffee.com/phequals7"><img src="https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow?style=for-the-badge&logo=buymeacoffee&logoColor=white" alt="Buy Me A Coffee" /></a>

---

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — CoreML speech models for Apple devices (Parakeet TDT, Qwen3 ASR, Silero VAD, speaker diarization)
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — Swift Whisper inference on CoreML/ANE
- [Core Audio](https://developer.apple.com/documentation/coreaudio) by Apple — system audio process taps
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) by Apple — system audio fallback capture
- [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) — FastConformer TDT speech recognition model
- [Cohere Transcribe](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) — 2B parameter autoregressive ASR (#1 Open ASR Leaderboard)
- [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B) — Multilingual speech recognition (52 languages)
- [pyannote](https://github.com/pyannote/pyannote-audio) — Speaker diarization (via FluidAudio CoreML conversion)

---

## License

[MIT](LICENSE) — free and open source.

## Star History

<a href="https://www.star-history.com/?repos=phequals7%2Fmuesli&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=phequals7/muesli&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=phequals7/muesli&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=phequals7/muesli&type=date&legend=top-left" />
 </picture>
</a>
