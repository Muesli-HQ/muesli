# Muesli CLI Contract

## Commands

- `muesli-cli spec`
- `muesli-cli info`
- `muesli-cli transcribe <file> [--format text|json|markdown] [--model parakeet-v3|parakeet-v2] [--summarize] [--save-meeting] [--title TITLE] [--output PATH]`
- `muesli-cli meetings list [--limit N] [--folder-id ID]`
- `muesli-cli meetings get <id>`
- `muesli-cli meetings update-notes <id> (--stdin | --file <path>)`
- `muesli-cli dictations list [--limit N]`
- `muesli-cli dictations get <id>`
- `muesli-cli captures list [--limit N]`
- `muesli-cli captures get <id|latest> [--manifest]`
- `muesli-cli captures frames <id|latest>`
- `muesli-cli captures zoom <id|latest> (--at M:SS | --mark N)`

## Output shape

Data commands return JSON to stdout. `transcribe` returns plain transcript text by default, `--format markdown` emits markdown text with title, optional summary, and raw transcript sections, and `--format json` uses the same success envelope.

Success envelope:
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

Failure envelope:
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

## Important fields

Meeting list rows include:
- `id`
- `title`
- `startTime`
- `durationSeconds`
- `wordCount`
- `folderID`
- `notesState`

Meeting details also include:
- `rawTranscript`
- `formattedNotes`
- `calendarEventID`
- `micAudioPath`
- `systemAudioPath`

`notesState` values:
- `missing`
- `raw_transcript_fallback`
- `structured_notes`

Dictation details include:
- `rawText`
- `appContext`
- `timestamp`
- `durationSeconds`

Transcribe JSON data includes:
- `transcript`
- `summary`
- `durationSeconds`
- `wordCount`
- `model`
- `warnings`
- `savedMeetingID`
- `title`

Supported transcribe inputs:
- `.mp3`
- `.mp4`
- `.m4a`
- `.wav`

Supported transcribe models:
- `parakeet-v3` (default)
- `parakeet-v2`

Transcribe behavior:
- progress and model logs go to stderr
- default stdout is transcript text only
- `--format json` includes warnings in both `data.warnings` and `meta.warnings`
- `--summarize` preserves the transcript if summary generation fails and returns a warning
- `--summarize` uses configured OpenAI, OpenRouter, Ollama, LM Studio, or Custom LLM settings when available; the app's ChatGPT session backend is not driven from headless CLI mode
- `--save-meeting` stores the meeting as `source = audio_import`
- `--output <path>` writes the selected output format to a file and keeps stdout clean

## Expected agent pattern

- `transcribe <file>` for raw local transcription
- `transcribe <file> --format json` when structured metadata is needed
- `transcribe <file> --save-meeting` when the imported audio should appear in Muesli
- `list` to discover IDs
- `get` to fetch full text
- external summarize/analyze in the coding agent
- `update-notes` to write notes back

## Scrawl payloads

All four `captures` commands use the existing version-1 JSON envelope with
`command: "muesli-cli captures <verb>"`. Each accepts `--db-path` and
`--support-dir`. Resolution is unchanged: explicit database (with explicit
support directory or its parent), explicit support directory, `MUESLI_DB_PATH`
(with `MUESLI_SUPPORT_DIR` or its parent), `MUESLI_SUPPORT_DIR`, then the default
support directory. Paths below are absolute and contained in the resolved
support directory; paths inside an optional manifest remain relative.

| Command | `data` |
| --- | --- |
| `list` | Array of `{id,createdAtMs,durationMs,state,title,bundlePath}`; newest first, ID descending on ties. Positive `--limit` defaults to 10. |
| `get` | `{id,createdAtMs,durationMs,state,title,bundlePath,summary,paths:{manifest?,summary?,frames,contactSheet?,video?,audio?},failures,manifest?}`; `manifest` is included only with `--manifest`. |
| `frames` | `{id,contactSheet?,frames:[{index,t,reason,file,eventIndex?,markId?,said,saidRange:{from,to}}]}` using saved keyframes with absolute `file`. |
| `zoom` | `{id,t0,t1,contactSheet,frames:[{index,t,file}],words:[{t0,t1,text}],said,estimated,missing?,failures}`. |

`latest` resolves once to the first store row, including a busy or failed one.
Missing artifacts are omitted with `meta.warnings`; no missing image is
advertised. A missing saved summary is regenerated from validated available
artifacts with a warning. `get` and `frames` can inspect recording/processing
captures; `zoom` refuses them. Partial captures preserve structured failures.

`--at` accepts nonnegative integer minutes and exactly two seconds digits
(00–59), within the capture duration. It selects ±2 seconds. Positive `--mark N`
selects stable mark ID `mN` and its full span plus one second on each side,
clipped to capture bounds. Sampling is clipped to playable video, with at most
six unique requested times. The explicit mark has priority, followed by marks
then clicks nearest the selected moment, with source-order ties. Co-timed
evidence shares one frame and retains every selected annotation. Spare slots
sample uniformly. Completed marks use their exact end; crossing marks reserve
the latest ink sample retained inside the requested/playable span. Clicks use
their recorded times independently of saved overview keyframes. Evidence
excluded by the cap or unplayable time is listed in `failures` with stage `zoom`.
Ink points retain their original clocks and pin IDs and are clipped again to
each actual decoded time before drawing. `frames[].t`
records actual decoded capture time, including the video offset. Word selection
uses overlap with the half-open narration span, includes zero-duration words
starting inside it, preserves order and original times, and joins them as `said`.
`estimated` and optional `missing:{reason}` preserve transcript status.

Zoom uses the existing 30-second render deadline, keeps source frames within a
2560-pixel long edge and the sheet within 1600 pixels, and writes successful
results atomically under a unique mode-0700 `zoom/<request>/` directory in the
bundle. It preserves in-span ink and click annotations without changing saved
frames, manifest, summary, or capture row. No successful sheet means failure.

A missing database gives `list` an empty array and warning; other leaves return
`database_unavailable` (exit 5). Missing IDs or empty `latest` return `not_found`
(3). Invalid options/selectors, unsafe paths, unsupported manifest versions,
and unusable zoom media return `invalid_input` (4). Detail commands validate the
manifest before output, including `get --manifest`; version 2 is refused with
the decoder's unsupported-version detail. Unknown version-1 fields are tolerated.
Database operation failures retain `database_error` (6) and migration warnings.
