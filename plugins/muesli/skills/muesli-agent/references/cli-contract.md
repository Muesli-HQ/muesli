# muesli CLI contract

This is a guide to the CLI shipped with muesli. Run `muesli-cli spec` to see the command tree and model names supported by the installed version.

## Commands

```text
muesli-cli spec
muesli-cli model-terms medasr [--accept]
muesli-cli skills list
muesli-cli skills get <id> [--markdown] [--support-dir <dir>]
muesli-cli history sample --from <ISO8601> --until <ISO8601> [--sources <comma-separated-sources>] [--query <topic>] [--support-dir <dir>]
muesli-cli history read <dictations|commands|quill|cotypist|chat> <id> [--support-dir <dir>]
muesli-cli time-turner history (--last <6h> | --from <ISO8601> --until <ISO8601> | --cursor <token>) [--app <app>] [--limit <1-1000>] [--support-dir <dir>]
muesli-cli time-turner search [--query <phrase>] [--from <ISO8601>] [--until <ISO8601>] [--app <app>] [--limit <1-1000>] [--cursor <token>] [--support-dir <dir>]
muesli-cli time-turner get <id> [--output <new.png>] [--support-dir <dir>]
muesli-cli captures list [--limit N]
muesli-cli captures get <id|latest> [--manifest]
muesli-cli captures frames <id|latest>
muesli-cli captures zoom <id|latest> (--at M:SS | --mark N)
muesli-cli info [--db-path <path>] [--support-dir <dir>]
muesli-cli transcribe <file> [--format text|json|markdown] [--model <model>] [--dictionary <path>] [--summarize] [--save-meeting] [--title <title>] [--output <path>]
muesli-cli meetings list [--limit <n>] [--folder-id <id>]
muesli-cli meetings get <id>
muesli-cli meetings update-notes <id> (--stdin | --file <path>)
muesli-cli dictations list [--limit <n>]
muesli-cli dictations get <id>
```

Examples:

```bash
muesli-cli transcribe interview.m4a --format json
muesli-cli meetings list --limit 10 | jq 'if .ok then .data |= map({id, title, startTime}) else . end'
muesli-cli meetings get 42
muesli-cli dictations get 7
cat notes.md | muesli-cli meetings update-notes 42 --stdin
```

Data commands use a JSON envelope with `ok`, `command`, `data`, and `meta`. Failures set `ok: false` and include `error.code`, `error.message`, and often `error.fix`. `transcribe` returns transcript text by default; its JSON result can include `transcript`, `summary`, `durationSeconds`, `wordCount`, `model`, `warnings`, `savedMeetingID`, and `title`.

Meeting list rows include `id`, `title`, `startTime`, `durationSeconds`, `wordCount`, `folderID`, and `notesState`. Use the filtered list example above with older installations. A full meeting includes `manualNotes`, `rawTranscript`, and `formattedNotes`. `notesState` is `missing`, `raw_transcript_fallback`, or `structured_notes`. Dictation details include `rawText`, `appContext`, `timestamp`, and `durationSeconds`.

`--summarize` uses the summary backend configured in muesli and may return a warning while preserving the transcript if summarization fails. Local agent analysis of a returned transcript does not require a separate muesli summary backend. `--save-meeting` stores an imported audio file as a meeting. `--output <path>` writes the selected output format to a file.

## Vidshot results

All four `captures` commands accept `--db-path` and `--support-dir`. The JSON envelope contains `data` and `meta.warnings`. CLI artifact paths are absolute; paths inside the optional version-1 manifest are relative to the bundle.

| Command | What to use |
| --- | --- |
| `captures list` | Newest recordings first; each row has an ID, state, duration, title, and bundle path. A missing database returns an empty list with a warning. |
| `captures get` | Summary, available paths, state, and structured failures. Add `--manifest` for the validated manifest. Missing artifacts can yield partial results. |
| `captures frames` | Saved screenshots in `frames[].file`, their times and narration, and a contact sheet when available. |
| `captures zoom` | At most six frames, a contact sheet, and overlapping narration with original word times. Read `estimated`, optional `missing`, and `failures` before relying on the result. |

A timestamp selects two seconds on either side. A positive mark number selects the full span of stable mark `mN` plus one second on each side. Both are clipped to available media. Zoom writes a new private `zoom/<request>/` directory in the bundle; it cannot zoom a recording that is still processing. `not_found` means no matching row; `database_unavailable` means the detail command could not open a missing database. Read the error before retrying.

## History and templates

`time-turner history --last 6h` returns observations oldest first; `time-turner search --query roadmap` returns matches newest first. Follow the returned cursor for more pages. `time-turner get <id>` reads OCR and metadata; add `--output <new.png>` to export an available screenshot to a new file. OCR can outlive the image.

`history sample` takes a bounded interval with explicit UTC offsets. Screen history is included by default; optional sources are `meetings,dictations,commands,quill,cotypist,chat`. Use `history read` for current optional text records, `meetings get` for meetings, and `time-turner get` for screens. Check for changed revisions or truncation. A partial sample cannot prove there was no other activity.

`skills get muesli-history --markdown` prints instructions as Markdown. `model-terms medasr` prints terms as text; adding `--accept` records acceptance on this Mac. Do not accept terms on the user’s behalf.
