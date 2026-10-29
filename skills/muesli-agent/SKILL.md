---
name: muesli-agent
description: Use when working with local Muesli meetings, notes, dictations, Scrawl captures, audio-file transcription, or raw transcripts through the bundled `muesli-cli` CLI. Prefer this skill when a coding agent needs to transcribe local audio, inspect transcripts or Scrawl captures, summarize meetings with its own model, or write notes back into Muesli without requiring the user's API keys.
---

# Muesli Agent

Use the local `muesli-cli` CLI as the source of truth for meeting, dictation, and Scrawl capture data.

## CLI discovery

Resolve the binary in this order:
1. `command -v muesli-cli`
2. `command -v muesli` only when the resolved path is a Homebrew cask alias to `Muesli.app/Contents/MacOS/muesli-cli`; verify with `muesli info`
3. `/Applications/Muesli.app/Contents/MacOS/muesli-cli`
4. A local SwiftPM build path inside this repo

If discovery is uncertain, run the candidate binary with `info` first and reject unrelated `muesli` executables.

## Core workflow

1. Inspect capabilities with `muesli-cli spec` if you do not know the exact subcommand shape.
2. To transcribe a local audio file, run `muesli-cli transcribe <file>` and read plain transcript text from stdout.
3. Use `muesli-cli transcribe <file> --format json` when you need duration, word count, model, warnings, summary, or saved meeting ID.
4. Add `--save-meeting` to persist an imported meeting with `source = audio_import`.
5. List candidate meetings with `muesli-cli meetings list --limit 10`.
6. Fetch a full record with `muesli-cli meetings get <id>`.
7. Use the coding agent's own model to analyze `rawTranscript` and `formattedNotes`.
8. If you want to persist improved notes, write markdown back with:
   - `cat notes.md | muesli-cli meetings update-notes <id> --stdin`
   - or `muesli-cli meetings update-notes <id> --file notes.md`

## Rules

- Treat CLI stdout as the API. Data commands are JSON by default; `transcribe` is plain text by default, Markdown with `--format markdown`, and JSON with `--format json`.
- Treat stderr as informational only.
- Do not mutate `rawTranscript`; only update `formattedNotes`.
- Prefer the meeting transcript when `notesState` is `missing` or `raw_transcript_fallback`.
- Use `--db-path` or `--support-dir` only when the default Muesli data location is wrong.

## Inspect Scrawl locally

Use `muesli-cli captures list [--limit N]`, then `captures get <id|latest>` for
the summary, absolute artifact paths, state, and failures. Add `--manifest` for
the validated version-1 manifest; its embedded paths remain relative.
`captures frames <id|latest>` returns available saved screenshots and the sheet.
Open these images before interpreting the narration or changing code.

For a closer look, use `captures zoom <id|latest> --at M:SS` or `--mark N`
(exactly one). Mark N selects stable ID `mN`, not a pin or screenshot number.
Timestamp context is ±2 seconds; a mark includes its full span plus one second
on each side. Zoom returns at most six frames, a contact sheet, and overlapping
words with original millisecond times. Evidence takes priority over uniform
sampling: the requested mark, other marks, then clicks nearest the requested
moment. Co-timed annotations share a frame. Ink stays within the playable span
and actual frame time; bounded or unplayable evidence omissions appear in
`failures`. Outputs stay in that bundle's
`zoom/<request>/`; no upload or canonical artifact replacement occurs.
Read `meta.warnings`, `failures`, `estimated`, and optional `missing` before
relying on partial or legacy captures. Busy captures can be inspected but cannot
be zoomed. All four commands accept the existing path options and environment
overrides. See the contract for exact payloads and refusal codes.

## When to read references

Read `references/cli-contract.md` if you need the exact command tree, field definitions, or failure behavior.
