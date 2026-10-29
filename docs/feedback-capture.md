# Scrawl (experimental)

Scrawl saves the display under your pointer with microphone narration for local playback. Enable **Settings → General → Experimental → Scrawl**. Grant Screen Recording, Microphone, Accessibility and Input Monitoring in macOS System Settings; a blocked pill names the missing permission and opens its setup action.

Press **Option–Shift–S (⌥⇧S)** and release every key to start. The selected display stays fixed for that capture. Speak while demonstrating the issue, then press the shortcut again or click **Finish** to save. Change the shortcut in **Settings → Shortcuts** using a modifier-plus-letter chord. Clicking **✕** asks **Discard?**; click it again to discard. Closing a window or pressing Escape leaves an established capture running.

Scrawl stops after ten minutes, when the recorded display disconnects or changes geometry, or when the Mac sleeps or locks. Starting a meeting finishes the capture and releases its microphone before meeting audio starts. If device teardown takes longer than eight seconds, the meeting reports that it is still pending; retry after teardown finishes. Finish stops screen collection immediately while already captured narration drains. Dictation, Quill and computer-use commands cannot start while Scrawl owns the microphone; an active meeting or other audio activity also prevents a new capture.

After processing, Scrawl copies the summary to the clipboard and the pill shows **Copied**. If you copied something else since Finish, it shows **Ready · Copy** instead; click **Copy** to use the saved summary. Named partial failures, such as **no transcript** or **frames failed**, remain visible. Click **Open** on the Ready pill, choose **Open Scrawl Captures…** from the menu bar, or use **Open Scrawl captures…** in General settings. The capture window shows the contact sheet, numbered screenshots with narration, and existing playback. **Copy** reads the saved summary, **Show in Finder** reveals the bundle, and **Delete…** removes it and all its files after confirmation. Saved captures remain accessible after disabling Scrawl.

Recording excludes Muesli's application windows, including its indicator, and captures microphone narration without system audio. Passive pointer monitoring logs clicks, drags and scrolls on the selected display; it never logs keys. Files stay on this Mac and appear under **Scrawl captures** in Local storage. Narration is transcribed on device using an installed local model, with selectable timestamped text beneath playback. Audio is transcribed once in disjoint chunks of at most eight seconds, cut at quiet points. Complete measured word times are retained; chunks without complete word times use estimated timing. Parakeet Unified uses estimated timing. Missing models or failed transcription leave the media playable with a named reason.

The local bundle contains `capture.json`, `summary.md`, available `recording.mp4` and `narration.wav`, the pointer journal `events.jsonl`, numbered PNGs under `frames/`, and `contact-sheet.png` when rendering succeeds. Keyframes follow actions and settled scene changes, with up to six through 40 seconds and up to twelve for longer captures. Clicks within 650 ms and four display points merge into one burst. Click frames show blue rings over the source image, with number chips in a reserved top band that leaves the embedded cursor and source content unobscured. The summary links to absolute local paths that a coding agent on this Mac can open. Every narration word belongs to one consecutive frame range; words whose frames failed remain as unillustrated narration in the summary and capture window. Estimated timing and missing-transcript reasons remain visible alongside any surviving frames. A failed stage preserves the available artifacts and records its reason. Older captures retain their narration and media presentation without requiring generated images or a summary.

After an interrupted recording, relaunch Muesli to recover playable media and surviving pointer events. Recovery retains completed video fragments and available narration, replays complete journal records despite a truncated tail, resumes processing through the normal finalizer, and reuses any checkpointed transcript. Event-only captures also survive. Recovery never automatically replaces the clipboard; open the capture and use **Copy**. A corrupt or unsupported-version bundle reports its own failure while healthy captures continue recovery. A partial capture may contain only audio, video or events. The Scrawl window refreshes when processing finishes and shows its recovery state and any failures. A damaged narration file does not prevent surviving video from appearing. If saving fails, Open still selects that capture using its recovery journal. Temporary microphone files use separate app-identity directories and are cleaned on normal stop or the next launch of that identity. Foreground dictation or meetings defer transcription without consuming its active processing timeout.

### Drawing and pins

While recording, hold the configured **Draw modifier** alone (Shift by default)
and move the pointer to draw red, 3-point ink without pressing a mouse button.
General → Experimental offers Shift, Option, Control, and Fn. The choice is
frozen for that recording. Release the start chord once before drawing; another
modifier in the hold suspends drawing. Movement below a 6-point bounding box is
discarded so typing a capital does not leave a mark. Samples are at least 1.5
points apart and capped at 2,400 per stroke.

Modifier-click drops a numbered pin when travel stays below 12 points and the
press lasts at most one second. A click after drawing in that hold remains part
of the drawing. Passive ⌘Z removes the last stroke or pin while still reaching
the front app. Secure Event Input leaves drawing available but disables observed
undo; these intervals are retained in `inputGaps`, including interrupted gaps
closed at recovered capture end. No typed characters are retained.

The live overlay is nonactivating and click-through on each display. Ink holds
for 650 ms after release and fades over another 650 ms; pins show a 350 ms ring.
The existing whole-Muesli video exclusion keeps ink out of `recording.mp4`.
Screenshots redraw the stored strokes and pins and include `✎` descriptions in
the summary. Up to six strokes less than 1.2 seconds apart form a mark; each pin
is its own mark. Marks on unchanged regional thumbnail content can share a frame
at the last mark. Mark frames take priority over ordinary frames and remain even
when there are more than twelve. Only the first twelve images enter the contact
sheet; the summary reports `+N more marked frames in frames/`. Missing or failed
frames never publish mark links; their descriptions and narration remain in the
summary.

Manifest version 1 now also has default-empty `strokes` and `marks`, and optional
keyframe `markId`. Strokes store `{t0,t1,fw,fh,pin?,pts}` with target dimensions
in points and flat integer `[x,y,dtMs,…]` triples (coordinates 0…10000).
`events.jsonl` keeps S3 pointer records unchanged alongside tagged `stroke`,
`undo`, and `input_gap` operations. Recovery replays operations in order before
rebuilding marks, preserving complete records around malformed records or a
truncated tail. These additions require no SQL migration or backfill.

### Inspect Scrawl from a coding agent

The bundled CLI reads saved Scrawl bundles locally:

```bash
muesli-cli captures list --limit 10
muesli-cli captures get latest
muesli-cli captures get latest --manifest
muesli-cli captures frames latest
muesli-cli captures zoom latest --at 0:12
muesli-cli captures zoom latest --mark 1
```

Each command returns the existing JSON envelope with absolute local artifact
paths. Open the sheet and frames alongside the summary before changing code.
`get` includes capture metadata, state, summary, available paths, and structured
failures. `--manifest` adds the validated version-1 manifest with relative paths;
unsupported versions are refused. Missing artifacts produce warnings, and a
missing summary is regenerated from surviving artifacts. `latest` always selects
the newest row, even when it is busy or failed. Inspect busy captures with `get`
or `frames`; wait for processing to finish before zooming.

Zoom requires exactly one selector. `--at M:SS` includes two seconds on each
side; `--mark N` selects stable mark ID `mN` (independent of pin and screenshot
numbers), with one second around its full span. Bounds are clipped to capture
and available video. Zoom reserves the requested mark first, then other marks
and clicks nearest the requested moment, sharing co-timed annotations. Spare
slots sample the span evenly, with at most six frames. Marks use their source
completion times; crossing marks use the latest retained ink sample. Ink is
clipped to the span, playable video, and each actual decoded capture time.
Evidence omitted by the frame limit or unplayable time appears in `failures`.
Narration words
overlapping the span retain original times, order, estimated timing, and any
missing-transcript reason.

Zoom writes frames and one contact sheet only under a new private
`zoom/<request>/` directory inside the selected bundle. Source frames have a
maximum 2560-pixel long edge and sheets a maximum 1600-pixel long edge. Partial
decoding reports its failures; no usable sheet is an error. The original
manifest, summary, frames, and database row are preserved. No files are uploaded.
All four commands accept the existing `--db-path`/`--support-dir` options and
`MUESLI_DB_PATH`/`MUESLI_SUPPORT_DIR` environment overrides. The exact payloads
and error codes are documented in the agent skill's CLI contract.
